import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../logging/app_logger.dart';
import '../platform/app_paths.dart';
import '../provider/cf_clearance_store.dart';
import '../ui/global_messenger.dart';

/// Windows Cloudflare solver: opens the site in a WebView2 window, waits until
/// the page is no longer a challenge (or the user presses Continue), then stores
/// the browser's cookies + its exact User-Agent in [CfClearanceStore].
/// `WindowsHttpLane` replays both through the Chrome-TLS helper afterwards.
///
/// Success is decided by the PAGE (title/text no longer say "Just a moment…"),
/// not by the presence of a `cf_clearance` cookie: some sites pass without one,
/// and a stale cookie can sit there while the site is still challenging.
///
/// Returns true when the page cleared, false if the user cancelled or it timed
/// out.
class DesktopCfSolver {
  DesktopCfSolver._();

  static bool _busy = false;
  static WebViewEnvironment? _env;

  /// One WebView2 profile for all verifications, kept in the app's own data
  /// folder (the default is next to the .exe, which may not be writable).
  static Future<WebViewEnvironment?> _environment() async {
    if (_env != null) return _env;
    try {
      final dir = await writableAppSubdir('webview2');
      _env = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(userDataFolder: dir.path),
      );
    } catch (e) {
      AppLogger.instance.log('[cf-solver] WebView2 environment failed: $e');
    }
    return _env;
  }

  static Future<bool> solve(String url) async {
    final uri = Uri.tryParse(url);
    final ctx = rootNavigatorKey.currentContext;
    if (uri == null || uri.host.isEmpty || ctx == null || _busy) return false;
    _busy = true;
    AppLogger.instance.log('[cf-solver] opening ${uri.host}');
    try {
      final env = await _environment();
      if (!ctx.mounted) return false;
      final ok = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => _SolverDialog(url: uri.toString(), environment: env),
      );
      AppLogger.instance.log(
        '[cf-solver] ${uri.host} -> ${ok == true ? 'cleared' : 'not cleared'}',
      );
      return ok == true;
    } catch (e) {
      AppLogger.instance.log('[cf-solver] failed: $e');
      return false;
    } finally {
      _busy = false;
    }
  }
}

/// True when the loaded document is a real page rather than a challenge.
bool _pageIsReal(Object? v) {
  if (v is! Map) return false;
  if (v['ready'] != true || v['body'] != true) return false;
  final title = '${v['title'] ?? ''}'.toLowerCase();
  final text = '${v['text'] ?? ''}'.toLowerCase();
  if (title.isEmpty) return false;
  const blockers = [
    'just a moment',
    'attention required',
    'checking your browser',
    'verify you are human',
    'access denied',
    'website verification',
  ];
  if (blockers.any(title.contains)) return false;
  if (text.contains('checking if the site connection is secure') ||
      text.contains('verify you are human')) {
    return false;
  }
  return true;
}

class _SolverDialog extends StatefulWidget {
  const _SolverDialog({required this.url, required this.environment});
  final String url;
  final WebViewEnvironment? environment;

  @override
  State<_SolverDialog> createState() => _SolverDialogState();
}

class _SolverDialogState extends State<_SolverDialog> {
  InAppWebViewController? _web;
  Timer? _poll;
  int _ticks = 0;
  bool _done = false;
  bool _checking = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _check({bool manual = false}) async {
    if (_done || _checking || _web == null || !mounted) return;
    if (!manual && ++_ticks > 90) return _finish(false); // ~3 minutes
    _checking = true;
    try {
      final state = await _web!
          .evaluateJavascript(
            source: '''
(function(){return {ready: document.readyState === 'complete',
  body: !!document.body && document.body.innerText.trim().length > 80,
  title: document.title,
  text: (document.body && document.body.innerText || '').slice(0, 1000)};})()
''',
          )
          .timeout(const Duration(seconds: 5));
      if (!_pageIsReal(state)) {
        if (manual && mounted) {
          setState(() => _note = 'Still verifying — wait for the site to load.');
        }
        return;
      }
      final current = (await _web!.getUrl())?.toString() ?? widget.url;
      final host = Uri.parse(widget.url).host;
      final manager = CookieManager.instance(
        webViewEnvironment: widget.environment,
      );
      final cookies = <String, String>{};
      for (final u in {current, widget.url}) {
        try {
          for (final c in await manager.getCookies(url: WebUri(u))) {
            cookies[c.name] = '${c.value}';
          }
        } catch (e) {
          AppLogger.instance.log('[cf-solver] getCookies failed: $e');
        }
      }
      final ua =
          (await _web!.evaluateJavascript(source: 'navigator.userAgent'))
              ?.toString();
      final header = cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
      AppLogger.instance.log(
        '[cf-solver] verified $host, ${cookies.length} cookie(s)'
        '${cookies.containsKey('cf_clearance') ? ' incl. cf_clearance' : ''}',
      );
      if (header.isNotEmpty) CfClearanceStore().remember(host, header, ua);
      _finish(true);
    } catch (e) {
      AppLogger.instance.log('[cf-solver] check error: $e');
      if (manual && mounted) setState(() => _note = 'Could not read the page: $e');
    } finally {
      _checking = false;
    }
  }

  void _finish(bool ok) {
    if (_done) return;
    _done = true;
    if (mounted) Navigator.of(context).pop(ok);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: size.width * 0.85,
        height: size.height * 0.85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _note ??
                          'Verifying you are human… this closes by itself when done.',
                    ),
                  ),
                  TextButton(
                    onPressed: () => _check(manual: true),
                    child: const Text('Continue'),
                  ),
                  TextButton(
                    onPressed: () => _finish(false),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: InAppWebView(
                webViewEnvironment: widget.environment,
                initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
                onWebViewCreated: (c) => _web = c,
                onLoadStop: (_, _) {
                  if (_note != null && mounted) setState(() => _note = null);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
