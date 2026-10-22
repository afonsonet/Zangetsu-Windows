import '../lnreader/lnreader_runtime.dart';
import '../lnreader/novel_cloudflare.dart';
import '../logging/app_logger.dart';
import '../provider/cf_clearance_store.dart';
import 'cf_helper.dart';

/// Windows twin of the Android `zangetsu/novel_http` native lane: sends an
/// LNReader plugin's fetch through [CfHelper] (Chrome TLS fingerprint) and adds
/// any stored Cloudflare clearance for the host.
///
/// Returns null when the helper is unavailable or errors, so the caller falls
/// through to Dio exactly as before. Every request is logged (host, status,
/// whether it was a challenge) to zangetsu.log — never headers or bodies.
class WindowsHttpLane {
  WindowsHttpLane._();

  static final CfClearanceStore _store = CfClearanceStore();

  static Future<LnReaderHttpResponse?> fetch({
    required String url,
    required String method,
    required Map<String, String> headers,
    String? body,
  }) async {
    if (!CfHelper.supported) return null;
    final host = Uri.tryParse(url)?.host ?? '';
    final sw = Stopwatch()..start();
    try {
      final h = Map<String, String>.from(headers);
      // A solved clearance is only valid with the UA that solved it.
      final clearance = _store.restore()[host];
      if (clearance != null) {
        final existing = h.entries
            .where((e) => e.key.toLowerCase() == 'cookie')
            .map((e) => e.value)
            .join('; ');
        h.removeWhere((k, _) => k.toLowerCase() == 'cookie');
        h['Cookie'] =
            existing.isEmpty ? clearance.cookie : '$existing; ${clearance.cookie}';
        if (clearance.ua != null) {
          h.removeWhere((k, _) => k.toLowerCase() == 'user-agent');
          h['User-Agent'] = clearance.ua!;
        }
      }
      final res = await CfHelper.instance
          .request(url: url, method: method, headers: h, body: body);
      if (res == null) return null;
      AppLogger.instance.log(
        '[net] $method $host -> ${res.status} (${sw.elapsedMilliseconds} ms)'
        '${clearance != null ? ' clearance' : ''}'
        '${res.cloudflare ? ' CLOUDFLARE-CHALLENGE' : ''}',
      );
      if (res.cloudflare) {
        if (clearance != null) _store.forget(host); // stale — re-solve
        NovelCloudflare.needsSolve(res.url);
      }
      return LnReaderHttpResponse(
        status: res.status,
        body: res.body,
        url: res.url,
        headers: res.headers,
      );
    } catch (e) {
      AppLogger.instance
          .log('[net] $method $host helper failed: $e — falling back to Dio');
      return null;
    }
  }
}
