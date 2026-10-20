import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// Native window control for the Windows build: the real window title and a
/// true fullscreen (no taskbar), which Flutter itself can't do on desktop.
///
/// Every method is a no-op off Windows, so callers never need their own
/// platform check and Android / TV / iOS behave exactly as before.
class DesktopWindow {
  DesktopWindow._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  static bool _ready = false;

  /// True while the window is in true fullscreen. Listenable so a button can
  /// swap its icon, and kept in step by [setFullscreen].
  static final ValueNotifier<bool> fullscreen = ValueNotifier<bool>(false);

  /// Call once before runApp. Never throws: a failure here must not stop the
  /// app from booting, it only means fullscreen stays unavailable.
  static Future<void> init() async {
    if (!supported) return;
    try {
      await windowManager.ensureInitialized();
      await windowManager.setTitle('Zangetsu');
      _ready = true;
    } catch (e) {
      debugPrint('[window] init failed: $e');
    }
  }

  static Future<void> setFullscreen(bool value) async {
    if (!supported || !_ready) return;
    if (fullscreen.value == value) return;
    try {
      await windowManager.setFullScreen(value);
      fullscreen.value = value;
    } catch (e) {
      debugPrint('[window] setFullscreen($value) failed: $e');
    }
  }

  static Future<void> toggleFullscreen() => setFullscreen(!fullscreen.value);
}
