import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'app_services.dart';
import 'app_theme.dart';
import 'config.dart';
import 'notifications.dart';
import 'platform_adaptive.dart';
import 'pomodoro_service.dart';
import 'sync_service.dart';
import 'screens/desktop_window.dart';
import 'screens/home_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Kompozisyon koku: gercek HTTP istemcisi. Testler AppServices.instance'i
  // sahte ApiClient ile degistirir.
  AppServices.instance = AppServices(api: ApiClient());

  // Windows/Linux/macOS'ta sqflate FFI backend gerekir (mobilde native plugin var).
  if (PlatformAdaptive.isDesktop) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await windowManager.ensureInitialized();
    // Masaustu video oynatma backend'i (libmpv). Android'de video_player kullanilir.
    MediaKit.ensureInitialized();
  }

  await AppConfig.load();
  await Notifications.init();
  await SyncService.init();
  PomodoroService.init();
  // Try initial sync
  SyncService.syncNow(); // fire and forget
  // Profil ozelliklerini (sekme gorunurlugu) sunucudan sessizce tazele.
  if (AppConfig.token.isNotEmpty) {
    AppServices.instance.api.fetchProfile()
        .then(
          (p) => AppConfig.setFeatures(
            (p['features'] as List?)?.cast<String>() ?? AppConfig.allFeatures,
          ),
        )
        .catchError((_) {});
  }
  runApp(const BelgelikApp());
}

class BelgelikApp extends StatelessWidget {
  const BelgelikApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppConfig.themeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Belgelik',
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: mode,
          // DeX / serbest pencere modunda Android, durum cubugu olmadigi
          // halde ust inset bildirebiliyor; AppBar'in ustunde olu bosluk
          // kaliyor. Yalnizca yukseklige bak: DeX'te buyutulmus (ama tam
          // ekran olmayan) pencere genislikte ekrani kaplar, yukseklikte
          // kaplamaz. Tam ekranda yukseklik esit oldugundan kural tetiklenmez;
          // bolunmus ekranda durum cubugu zaten pencerenin icindeyse Android
          // dogru inset bildirir (yatay bolunmede yukseklik kuculur ama ust
          // yarida degilse inset zaten 0'dir).
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            final view = View.of(context);
            final display = view.display;
            final displayLogical = display.size / display.devicePixelRatio;
            final windowed = mq.size.height < displayLogical.height - 40;
            if (!windowed || child == null) return child ?? const SizedBox();
            return MediaQuery(
              data: mq.copyWith(
                padding: mq.padding.copyWith(top: 0),
                viewPadding: mq.viewPadding.copyWith(top: 0),
              ),
              child: child,
            );
          },
          home: PlatformAdaptive.isDesktop
              ? const DesktopWindow()
              : const HomeShell(),
        );
      },
    );
  }
}
