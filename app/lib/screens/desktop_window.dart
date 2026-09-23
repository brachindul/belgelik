import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_shell.dart';

/// Masaustu pencere yonetimi: boyut/konum hatirlama, minimum boyut.
/// HomeShell'in masaustu karsiligidir; DesktopShell'i sarmalar.
class DesktopWindow extends StatefulWidget {
  const DesktopWindow({super.key});

  @override
  State<DesktopWindow> createState() => _DesktopWindowState();
}

class _DesktopWindowState extends State<DesktopWindow> with WindowListener {
  static const _kWinW = 'win_width';
  static const _kWinH = 'win_height';
  static const _kWinX = 'win_x';
  static const _kWinY = 'win_y';
  static const _kWinMax = 'win_maximized';

  static const _defaultW = 1280.0;
  static const _defaultH = 800.0;
  static const _minW = 900.0;
  static const _minH = 640.0;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _restoreAndShow();
  }

  Future<void> _restoreAndShow() async {
    final prefs = await SharedPreferences.getInstance();
    final w = prefs.getDouble(_kWinW) ?? _defaultW;
    final h = prefs.getDouble(_kWinH) ?? _defaultH;
    final maximized = prefs.getBool(_kWinMax) ?? false;

    await windowManager.setMinimumSize(const Size(_minW, _minH));
    await windowManager.setSize(Size(w, h));

    final x = prefs.getDouble(_kWinX);
    final y = prefs.getDouble(_kWinY);
    if (x != null && y != null) {
      await windowManager.setPosition(Offset(x, y));
    } else {
      await windowManager.center();
    }

    if (maximized) {
      await windowManager.maximize();
    }
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowClose() async {
    final size = await windowManager.getSize();
    final pos = await windowManager.getPosition();
    final maximized = await windowManager.isMaximized();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kWinW, size.width);
    await prefs.setDouble(_kWinH, size.height);
    // Maksimize iken konum/boyut saklarsak restore yanlis olur;
    // maksimize degilse guncel konumu sakla.
    if (!maximized) {
      await prefs.setDouble(_kWinX, pos.dx);
      await prefs.setDouble(_kWinY, pos.dy);
    }
    await prefs.setBool(_kWinMax, maximized);
    await windowManager.destroy();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const DesktopShell();
  }
}
