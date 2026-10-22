import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';

/// Result of one request made through the helper.
class CfHelperResponse {
  CfHelperResponse({
    required this.status,
    required this.headers,
    required this.body,
    required this.url,
    required this.cloudflare,
  });
  final int status;
  final Map<String, String> headers;
  final String body;
  final String url;

  /// True only for an interactive Cloudflare challenge a person could pass.
  final bool cloudflare;
}

/// Starts and talks to `cf-helper/cfhelper.exe` (see tools/cfhelper): a loopback
/// HTTP helper that makes requests with a real Chrome TLS fingerprint, which is
/// what gets past Cloudflare's bot-fight on Windows (Dart's own TLS stack is
/// fingerprinted and rejected, Android uses the OS stack instead).
///
/// Windows only, lazy (first use), and every failure is non-fatal: callers fall
/// back to their normal Dio request when this returns null / throws.
class CfHelper {
  CfHelper._();
  static final CfHelper instance = CfHelper._();

  Process? _proc;
  int? _port;
  String? _token;
  Future<bool>? _starting;
  bool _unavailable = false;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);

  static bool get supported => !kIsWeb && Platform.isWindows;

  static String get _exePath {
    final dir = File(Platform.resolvedExecutable).parent.path;
    return '$dir${Platform.pathSeparator}cf-helper${Platform.pathSeparator}cfhelper.exe';
  }

  void _log(String m) => AppLogger.instance.log('[cfhelper] $m');

  Future<bool> _ensureStarted() {
    if (!supported || _unavailable) return Future.value(false);
    if (_proc != null && _port != null) return Future.value(true);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<bool> _start() async {
    final exe = File(_exePath);
    if (!await exe.exists()) {
      _log('not found at ${exe.path} — using the normal HTTP client');
      _unavailable = true;
      return false;
    }
    final rnd = Random.secure();
    final token = base64Url.encode(List<int>.generate(24, (_) => rnd.nextInt(256)));
    try {
      final proc = await Process.start(
        exe.path,
        const [],
        environment: {'ZANGETSU_TOKEN': token},
      );
      final ready = Completer<int>();
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final m = RegExp(r'^READY (\d+)$').firstMatch(line.trim());
        if (m != null && !ready.isCompleted) {
          ready.complete(int.parse(m.group(1)!));
        }
      });
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) => _log('stderr: $l'));
      unawaited(proc.exitCode.then((code) {
        _log('helper exited ($code)');
        if (identical(_proc, proc)) {
          _proc = null;
          _port = null;
        }
      }));
      final port = await ready.future.timeout(const Duration(seconds: 8));
      _proc = proc;
      _port = port;
      _token = token;
      _log('started on 127.0.0.1:$port');
      return true;
    } catch (e) {
      _log('could not start: $e');
      _unavailable = true;
      return false;
    }
  }

  /// Performs the request through the helper. Returns null if the helper is not
  /// available (caller should use its normal client); throws on a network error
  /// reported by the helper so the caller can decide to fall back too.
  Future<CfHelperResponse?> request({
    required String url,
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!await _ensureStarted()) return null;
    final req = await _http.postUrl(Uri.parse('http://127.0.0.1:$_port/request'));
    req.headers.set('X-Zangetsu-Token', _token!);
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode({
      'url': url,
      'method': method,
      'headers': headers,
      if (body != null) 'body': body,
      'timeoutMs': timeout.inMilliseconds,
    })));
    final res = await req.close().timeout(timeout + const Duration(seconds: 5));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw HttpException('helper HTTP ${res.statusCode}');
    }
    final j = jsonDecode(text) as Map<String, dynamic>;
    final err = j['error'] as String?;
    if (err != null && err.isNotEmpty) throw HttpException(err);
    var bodyText = j['body'] as String? ?? '';
    if (j['base64'] == true) {
      bodyText = utf8.decode(base64.decode(bodyText), allowMalformed: true);
    }
    return CfHelperResponse(
      status: (j['status'] as num?)?.toInt() ?? 0,
      headers: (j['headers'] as Map?)
              ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
          const {},
      body: bodyText,
      url: j['url'] as String? ?? url,
      cloudflare: j['cloudflare'] == true,
    );
  }

  void dispose() {
    _proc?.kill();
    _proc = null;
    _port = null;
  }
}
