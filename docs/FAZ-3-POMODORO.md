# FAZ 3 — Pomodoro Sayacı

> **Ajana not:** Önce `ROADMAP.md`'yi oku. Bu faz Faz 1-2 üzerine eklenir, çoğunlukla **istemci (Flutter) tarafıdır**; sunucuda değişiklik YOK. Kod bloklarını birebir uygula. DOĞRULAMA başarısızsa dur ve raporla. OS: Windows, PowerShell.
>
> **ÖNEMLİ — `flutter_local_notifications` sürüm hassasiyeti:** Bu paketin API'si sürümler arası DEĞİŞİR (`zonedSchedule`, `AndroidScheduleMode`, izin metotları). Aşağıdaki kod güncel (v17+) sürüme göredir. Derlenmezse UYDURMA — DUR, `pubspec.lock`'taki `flutter_local_notifications` ve `timezone` sürümlerini raporla.

## Faz 3'ün amacı
1. Ayarlanabilir çalış/mola süreleriyle (varsayılan 50 dk / 10 dk) pomodoro sayacı.
2. Sayaç **zaman-damgası bazlı**: uygulama arka plana atılıp geri gelince doğru kalan süreyi gösterir.
3. Süre bitince **bildirim + titreşim** (ekran kapalı/arka planda olsa bile zamanlanmış bildirim çalar).
4. Bittiğinde otomatik olarak diğer faza (çalış↔mola) geçer ama otomatik başlatmaz; kullanıcı başlatır.
5. Uygulamaya alt menü eklenir: **Kütüphane** ve **Pomodoro** sekmeleri.

---

## BÖLÜM A — PAKETLER

```powershell
cd <PROJE>\app
flutter pub add flutter_local_notifications timezone
```
DOĞRULAMA: `pubspec.yaml`'da iki paket de görünmeli, `flutter pub get` hatasız bitmeli.

---

## BÖLÜM B — ANDROID İZİNLERİ VE AYARLAR

### B1. `app/android/app/src/main/AndroidManifest.xml`
`<manifest>` etiketi içinde (mevcut INTERNET izninin yanına) şu izinleri EKLE:
```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.VIBRATE"/>
<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
<uses-permission android:name="android.permission.USE_EXACT_ALARM"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
```

### B2. `app/android/app/build.gradle` (veya `build.gradle.kts`)
`flutter_local_notifications` için Java 8 desugaring gerekir. `android { }` bloğunun içine şunları EKLE (zaten varsa atla):

Eğer dosya **Groovy** (`build.gradle`) ise:
```groovy
android {
    compileOptions {
        coreLibraryDesugaringEnabled true
        sourceCompatibility JavaVersion.VERSION_1_8
        targetCompatibility JavaVersion.VERSION_1_8
    }
}
dependencies {
    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.4'
}
```
Eğer dosya **Kotlin DSL** (`build.gradle.kts`) ise:
```kotlin
android {
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
```
> Not: `dependencies { }` bloğu dosyada zaten varsa, yeni satırı onun içine ekle; yoksa `android { }` bloğundan sonra ekle.

---

## BÖLÜM C — FLUTTER KODU

### C1. `app/lib/notifications.dart` oluştur:
```dart
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class Notifications {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _channelId = 'pomodoro';
  static const _channelName = 'Pomodoro';

  static Future<void> init() async {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Europe/Istanbul'));

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: android),
    );

    final androidImpl =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();
  }

  static NotificationDetails _details() => const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          importance: Importance.max,
          priority: Priority.high,
          enableVibration: true,
          playSound: true,
        ),
      );

  /// Belirtilen zamanda bildirim kurar (uygulama kapali/arka planda olsa bile).
  static Future<void> scheduleAt(
      DateTime when, String title, String body) async {
    await _plugin.zonedSchedule(
      1,
      title,
      body,
      tz.TZDateTime.from(when, tz.local),
      _details(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  static Future<void> cancel() => _plugin.cancel(1);
}
```

### C2. `app/lib/config.dart`'a pomodoro süre ayarlarını EKLE
`AppConfig` içine (mevcut alanlar kalsın):
```dart
  static const _kWorkMin = 'work_min';
  static const _kBreakMin = 'break_min';
  static int workMinutes = 50;
  static int breakMinutes = 10;
```
`load()` sonuna EKLE:
```dart
    workMinutes = prefs.getInt(_kWorkMin) ?? 50;
    breakMinutes = prefs.getInt(_kBreakMin) ?? 10;
```
`AppConfig` içine yeni metot EKLE:
```dart
  static Future<void> savePomodoro(int work, int brk) async {
    final prefs = await SharedPreferences.getInstance();
    workMinutes = work;
    breakMinutes = brk;
    await prefs.setInt(_kWorkMin, work);
    await prefs.setInt(_kBreakMin, brk);
  }
```

### C3. `app/lib/screens/pomodoro_screen.dart` oluştur:
```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../notifications.dart';

enum Phase { work, brk }

class PomodoroScreen extends StatefulWidget {
  const PomodoroScreen({super.key});

  @override
  State<PomodoroScreen> createState() => _PomodoroScreenState();
}

class _PomodoroScreenState extends State<PomodoroScreen> {
  Phase _phase = Phase.work;
  bool _running = false;
  Timer? _ticker;
  DateTime? _endTime;
  Duration _remaining = Duration(minutes: AppConfig.workMinutes);

  int get _phaseMinutes =>
      _phase == Phase.work ? AppConfig.workMinutes : AppConfig.breakMinutes;

  String get _phaseLabel => _phase == Phase.work ? 'Çalışma' : 'Mola';

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _start() {
    final end = DateTime.now().add(_remaining);
    _endTime = end;
    _running = true;
    Notifications.scheduleAt(
      end,
      _phase == Phase.work ? 'Çalışma bitti!' : 'Mola bitti!',
      _phase == Phase.work ? 'Mola zamanı 🎉' : 'Çalışmaya dön 💪',
    );
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    setState(() {});
  }

  void _tick() {
    if (_endTime == null) return;
    final left = _endTime!.difference(DateTime.now());
    if (left.inSeconds <= 0) {
      _finish();
    } else {
      setState(() => _remaining = left);
    }
  }

  void _finish() {
    _ticker?.cancel();
    HapticFeedback.heavyImpact();
    _running = false;
    _endTime = null;
    // diger faza gec
    _phase = _phase == Phase.work ? Phase.brk : Phase.work;
    _remaining = Duration(minutes: _phaseMinutes);
    setState(() {});
  }

  void _pause() {
    _ticker?.cancel();
    Notifications.cancel();
    if (_endTime != null) {
      _remaining = _endTime!.difference(DateTime.now());
      if (_remaining.isNegative) _remaining = Duration.zero;
    }
    _running = false;
    _endTime = null;
    setState(() {});
  }

  void _reset() {
    _ticker?.cancel();
    Notifications.cancel();
    _running = false;
    _endTime = null;
    _remaining = Duration(minutes: _phaseMinutes);
    setState(() {});
  }

  void _switchPhase(Phase p) {
    if (_running) return;
    _phase = p;
    _remaining = Duration(minutes: _phaseMinutes);
    setState(() {});
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _openSettings() async {
    final workCtrl =
        TextEditingController(text: AppConfig.workMinutes.toString());
    final breakCtrl =
        TextEditingController(text: AppConfig.breakMinutes.toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Süreler (dakika)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: workCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Çalışma'),
            ),
            TextField(
              controller: breakCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Mola'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('İptal')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Kaydet')),
        ],
      ),
    );
    if (ok == true) {
      final w = int.tryParse(workCtrl.text) ?? AppConfig.workMinutes;
      final b = int.tryParse(breakCtrl.text) ?? AppConfig.breakMinutes;
      await AppConfig.savePomodoro(w.clamp(1, 180), b.clamp(1, 60));
      _reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isWork = _phase == Phase.work;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pomodoro'),
        actions: [
          IconButton(
              onPressed: _running ? null : _openSettings,
              icon: const Icon(Icons.tune)),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SegmentedButton<Phase>(
              segments: const [
                ButtonSegment(value: Phase.work, label: Text('Çalışma')),
                ButtonSegment(value: Phase.brk, label: Text('Mola')),
              ],
              selected: {_phase},
              onSelectionChanged:
                  _running ? null : (s) => _switchPhase(s.first),
            ),
            const SizedBox(height: 40),
            Text(_phaseLabel,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              _fmt(_remaining),
              style: TextStyle(
                fontSize: 80,
                fontWeight: FontWeight.bold,
                color: isWork ? Colors.indigo : Colors.green,
              ),
            ),
            const SizedBox(height: 40),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _running ? _pause : _start,
                  icon: Icon(_running ? Icons.pause : Icons.play_arrow),
                  label: Text(_running ? 'Duraklat' : 'Başlat'),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.replay),
                  label: const Text('Sıfırla'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
```

### C4. `app/lib/screens/home_shell.dart` oluştur (alt menü):
```dart
import 'package:flutter/material.dart';

import 'library_screen.dart';
import 'pomodoro_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  final _pages = const [
    LibraryScreen(),
    PomodoroScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.library_books), label: 'Kütüphane'),
          NavigationDestination(icon: Icon(Icons.timer), label: 'Pomodoro'),
        ],
      ),
    );
  }
}
```

### C5. `app/lib/main.dart` güncelle
1. Importları güncelle: `library_screen.dart` yerine `home_shell.dart` import et, ayrıca `notifications.dart` import et.
2. `main()` fonksiyonunda `AppConfig.load()` satırından SONRA `await Notifications.init();` ekle.
3. `MaterialApp`'in `home:` değerini `const HomeShell()` yap.

Son hâli şöyle olmalı:
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
    return MaterialApp(
      title: 'Belgelik',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}
```

---

## BÖLÜM D — TEST

```powershell
cd <PROJE>\app
flutter run
```
1. Alt menüde **Pomodoro** sekmesine geç.
2. İlk açılışta bildirim izni sorulursa **İzin Ver**.
3. **Çalışma** süresini ⚙️ ile kısa bir değere ayarla (test için 1 dk), Başlat'a bas.
4. Sayaç geri saymalı.
5. **Test 1 (arka plan):** Başlat'a bas, uygulamayı arka plana al / ekranı kapat, süre dolunca **bildirim + titreşim** gelmeli.
6. **Test 2 (donma yok):** Başlat → arka plana al → 10 sn sonra geri dön → sayaç doğru (gerçek saate göre azalmış) değeri göstermeli, donmamış olmalı.
7. **Test 3:** Süre bitince faz otomatik Mola'ya geçmeli.
8. Duraklat / Sıfırla butonları çalışmalı.

> **Exact alarm notu:** Bazı Android 13/14 cihazlarında "Alarmlar ve hatırlatıcılar" izni varsayılan kapalı olabilir; bildirim tam zamanında gelmezse Ayarlar > Uygulamalar > Belgelik > Alarmlar ve hatırlatıcılar iznini aç. Kullanıcıya bunu hatırlat.

---

## DOĞRULAMA / BİTİŞ KONTROL LİSTESİ
- [ ] Alt menü Kütüphane ↔ Pomodoro geçişi çalışıyor
- [ ] Sayaç başlat/duraklat/sıfırla çalışıyor
- [ ] Süre/mola dakikaları ayarlanıp kaydediliyor
- [ ] Arka plandayken/ekran kapalıyken süre bitince bildirim+titreşim geliyor
- [ ] Arka plandan dönünce sayaç donmuyor, doğru süreyi gösteriyor
- [ ] Çalışma bitince otomatik Mola fazına geçiyor
- [ ] Kütüphane ve PDF okuyucu hâlâ çalışıyor (regresyon yok)

Hepsi yeşilse Faz 3 bitti.

```powershell
cd <PROJE>
git add .
git commit -m "Faz 3: pomodoro sayaci (zaman-damgasi bazli + zamanlanmis bildirim)"
```

Sonraki adım: `docs/FAZ-4-DERS-PROGRAMI.md` (Claude tarafından sağlanacak).

---

## Ajan için kurallar
1. `flutter_local_notifications` / `timezone` API'si bu sürümde farklıysa DUR ve sürümleri raporla — özellikle `zonedSchedule`, `AndroidScheduleMode.exactAllowWhileIdle`, `requestNotificationsPermission` çağrıları.
2. Gradle desugaring eklemesi derleme hatası verirse (sürüm uyuşmazlığı) hatayı raporla.
3. Kod bloklarını birebir uygula; her DOĞRULAMA başarısızsa sonraki adıma geçme.
