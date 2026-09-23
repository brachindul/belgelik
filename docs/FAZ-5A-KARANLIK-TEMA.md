# FAZ 5A — Karanlık Tema

> **Ajana not:** Önce `ROADMAP.md`'yi oku. Bu faz Faz 1-4 üzerine eklenir, tamamen istemci (Flutter) tarafıdır; sunucuda değişiklik YOK. Kod bloklarını birebir uygula. DOĞRULAMA başarısızsa dur ve raporla.

## Amaç
Uygulamaya tema seçimi: **Sistem / Açık / Koyu**. Seçim kalıcı (SharedPreferences) ve anında uygulanır.

---

## B1. `app/lib/config.dart` — tema durumu EKLE
`import` satırlarının altına ekle:
```dart
import 'package:flutter/material.dart';
```
`AppConfig` sınıfının içine (mevcut alanlar kalsın) EKLE:
```dart
  static const _kThemeMode = 'theme_mode';
  static final ValueNotifier<ThemeMode> themeNotifier =
      ValueNotifier(ThemeMode.system);
```
`load()` metodunun SONUNA EKLE:
```dart
    final tm = prefs.getString(_kThemeMode) ?? 'system';
    themeNotifier.value = _parseTheme(tm);
```
`AppConfig` sınıfına yeni metotlar EKLE:
```dart
  static ThemeMode _parseTheme(String s) {
    switch (s) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static String _themeToString(ThemeMode m) {
    switch (m) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  static Future<void> setTheme(ThemeMode mode) async {
    themeNotifier.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, _themeToString(mode));
  }
```

## B2. `app/lib/main.dart` — temayı bağla
`BelgelikApp`'in `build` metodunu, temayı dinleyecek şekilde değiştir:
```dart
import 'package:flutter/material.dart';

import 'config.dart';
import 'notifications.dart';
import 'screens/home_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.load();
  await Notifications.init();
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
          title: 'Belgelik',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          themeMode: mode,
          home: const HomeShell(),
        );
      },
    );
  }
}
```

## B3. `app/lib/screens/settings_screen.dart` — tema seçici EKLE
Mevcut `Column`'un `children` listesine (Kaydet butonundan ÖNCE) ekle:
```dart
            const SizedBox(height: 24),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Tema'),
            ),
            const SizedBox(height: 8),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('Sistem')),
                ButtonSegment(value: ThemeMode.light, label: Text('Açık')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Koyu')),
              ],
              selected: {AppConfig.themeNotifier.value},
              onSelectionChanged: (s) {
                AppConfig.setTheme(s.first);
                setState(() {});
              },
            ),
```
`settings_screen.dart` dosyasının başında `import '../config.dart';` zaten var; yoksa ekle.

---

## TEST
```powershell
cd <PROJE>\app
flutter run
```
1. Kütüphane > Ayarlar (dişli) > Tema bölümünden **Koyu** seç → uygulama anında koyu olmalı.
2. **Açık** seç → açık olmalı.
3. **Sistem** seç → telefonun sistem temasına uymalı.
4. Uygulamayı kapatıp aç → son seçim hatırlanmalı.

## DOĞRULAMA / BİTİŞ
- [ ] Üç tema modu da çalışıyor ve anında uygulanıyor
- [ ] Seçim uygulama yeniden açılınca korunuyor
- [ ] Tüm ekranlar (Kütüphane, Program, Pomodoro) koyu temada okunaklı

```powershell
cd <PROJE>
git add .
git commit -m "Faz 5A: karanlik tema (sistem/acik/koyu)"
```
