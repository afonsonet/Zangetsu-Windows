import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../logging/app_logger.dart';
import '../provider/cf_clearance_store.dart';
import '../ui/global_messenger.dart';

/// Windows Cloudflare solver: opens the site in a WebView2 window, waits for the
/// user (or Cloudflare's automatic check) to pass, then stores the resulting
/// `cf_clearance` cookie + the WebView's exact User-Agent in [CfClearanceStore].
/// `WindowsHttpLane` replays both through the Chrome-TLS helper afterwards.
///
/// Returns true when a clearance was captured, false if the user closed the
/// window first or it timed out.
class DesktopCfSolver {
  DesktopCfSolver._();

  static bool _busy = false;

  static Future<bool> solve(String url) async {
    final uri = Uri.tryParse(url);
    final ctx = rootNavigatorKey.currentContext;
    if (uri == null || uri.host.isEmpty || ctx == null || _busy) return false;
    _busy = true;
    AppLogger.instance.log('[cf-solver] opening ${uri.host}');
    try {
      final ok = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => _SolverDialog(url: uri.toString()),
      );
      AppLogger.instance
          .log('[cf-solver] ${uri.host} -> ${ok == true ? 'cleared' : 'not cleared'}');
      return ok == true;
    } catch (e) {
      AppLogger.instance.log('[cf-solver] failed: $e');
      return false;
    } finally {
      _busy = false;
    }
  }
}

class _SolverDialog extends StatefulWidget {
  const _SolverDialog({required this.url});
  final String url;

  @override
  State<_SolverDialog> createState() => _SolverDialogState();
}

class _SolverDialogState extends State<_SolverDialog> {
  InAppWebViewController? _web;
  Timer? _poll;
  int _ticks = 0;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_done || _web == null || !mounted) return;
    if (++_ticks > 180) return _finish(false); // 3 minutes
    try {
      final uri = Uri.parse(widget.url);
      final cookies =
          await CookieManager.instance().getCookies(url: WebUri(widget.url));
      final cf = cookies.where((c) => c.name == 'cf_clearance').toList();
      if (cf.isEmpty) return;
      final ua = await _web!.evaluateJavascript(source: 'navigator.userAgent');
      final header = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      CfClearanceStore().remember(uri.host, header, ua?.toString());
      _finish(true);
    } catch (e) {
      AppLogger.instance.log('[cf-solver] poll error: $e');
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
        width: size.width * 0.8,
        height: size.height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Verifying you are human… this closes by itself when done.',
                    ),
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
                initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                onWebViewCreated: (c) => _web = c,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
