# Windows Masaüstü Okuyucu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mevcut Flutter uygulamasını Windows masaüstünde, fare/klavye ve geniş ekran için optimize edilmiş "yan panel + okuyucu" düzeniyle çalışır hale getirmek. Telefon davranışı korunur.

**Architecture:** Tek kod tabanı, platform'a göre shell değişimi. `HomeShell` platform kontrolüyle `MobileShell` (alt bar) veya `DesktopShell` (sol NavigationRail) seçer. Ekranlar `LayoutBuilder` + breakpoint (≥900px) ile responsive. Platform-bağımsız servis katmanları (Api, SyncService, LocalStore, PomodoroService) dokunulmaz.

**Tech Stack:** Flutter (Dart), `window_manager` (pencere kontrolü), `sqflite_common_ffi` (Windows SQLite backend), `pdfrx` (zaten Windows destekli).

**Spec:** `docs/superpowers/specs/2026-06-24-windows-desktop-okuyucu-design.md`

---

## Önemli Mimari Notlar (uygulayıcı için)

1. **Reader gömme problemi:** Mevcut `ReaderScreen` `Navigator.push` ile tam ekran açılır, kendi `Scaffold`+`AppBar`'ı vardır. Masaüstünde "yan panel + okuyucu" için reader gömülü gösterilir. Bu plan, `ReaderScreen`'i `Navigator.push` yerine `DesktopShell` içinde gömülü kullanacak şekilde uyarlar — `ReaderScreen`'in iç yapısı korunur, sadece **nasıl sunulduğu** değişir.

2. **AppBar çoğulluğu:** Her ekran kendi `Scaffold`+`AppBar` içeriyor. Masaüstünde shell'in kendi NavigationRail'i var, ekranların `AppBar`'ları gereksiz olabilir ama **ilk görevde mobil yerleşimi bozmamak için** AppBar'lar korunur; masaüstü düzeninde sadece görünürlük `LayoutBuilder` ile ayarlanır. En sade ve güvenli yol.

3. **sqflite FFI:** Windows'ta `sqflite` native plugin yok; `sqflite_common_ffi` gerekir. Bu, `main.dart`'ta tek noktada `databaseFactory` atanarak çözülür — `LocalStore` değişmez.

4. **TDD notu:** Bu görevlerin çoğu UI/pencere/sorgulama olduğu için TDD sınırlıdır. Mümkün yerlerde (platform tespiti, breakpoint) birim test yazılır; UI görevleri `flutter analyze` + manuel çalıştırma ile doğrulanır.

5. **Mobil regresyon birinci öncelik:** Her task sonunda `flutter analyze` ve `flutter test` çalışmalı; Android davranışının bozulmadığı doğrulanmalı.

---

## Task 1: Platform Adaptive Yardımcıları

Platform tespiti ve breakpoint için ortak modül. Tüm diğer görevler buna bağlı.

**Files:**
- Create: `app/lib/platform_adaptive.dart`
- Test: `app/test/platform_adaptive_test.dart`

- [ ] **Step 1: Write the failing test**

Create `app/test/platform_adaptive_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:belgelik/platform_adaptive.dart';

void main() {
  group('PlatformAdaptive', () {
    test('desktopBreakpoint is 900', () {
      expect(PlatformAdaptive.desktopBreakpoint, 900);
    });

    test('isWide returns true at and above breakpoint', () {
      expect(PlatformAdaptive.isWide(900), isTrue);
      expect(PlatformAdaptive.isWide(899), isFalse);
      expect(PlatformAdaptive.isWide(1280), isTrue);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/platform_adaptive_test.dart`
Expected: FAIL — `platform_adaptive.dart` yok / import çözülemedi.

- [ ] **Step 3: Write minimal implementation**

Create `app/lib/platform_adaptive.dart`:

```dart
import 'dart:io' show Platform;

/// Platforma ve ekran genisligine gore UI kararlarini toplar.
class PlatformAdaptive {
  static const int desktopBreakpoint = 900;

  /// Desktop (Windows/macOS/Linux) mi?
  /// Bu proje web hedefi olmadigi icin dart:io Platform guvenle kullanilir.
  static bool get isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Verilen genislik masaustu yerlesimi icin yeterli mi?
  static bool isWide(double width) => width >= desktopBreakpoint;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/platform_adaptive_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd app && git add lib/platform_adaptive.dart test/platform_adaptive_test.dart
git commit -m "Platform adaptive yardimcilari (isDesktop, breakpoint)"
```

---

## Task 2: Bağımlılıklar & sqflite FFI Init

`window_manager` ve `sqflite_common_ffi` ekle; Windows'ta SQLite FFI backend'i aktive et.

**Files:**
- Modify: `app/pubspec.yaml`
- Modify: `app/lib/main.dart`

- [ ] **Step 1: Bağımlılıkları pubspec.yaml'a ekle**

`app/pubspec.yaml` içinde `dependencies:` bölümüne ekle (alfabetik sırayla, mevcut girdilerin arasına):

```yaml
dependencies:
  flutter:
    sdk: flutter

  cupertino_icons: ^1.0.8
  http: ^1.6.0
  shared_preferences: ^2.5.5
  path_provider: ^2.1.5
  flutter_local_notifications: ^22.0.0-dev.3
  timezone: ^0.11.0
  pdfrx: ^2.2.24
  file_picker: 10.0.0
  sqflite: ^2.4.3
  sqflite_common_ffi: ^2.3.4+4
  path: ^1.9.1
  package_info_plus: ^8.3.0
  open_filex: ^4.7.0
  google_fonts: ^6.2.1
  window_manager: ^0.4.3
```

- [ ] **Step 2: pub get çalıştır**

Run: `cd app && flutter pub get`
Expected: Bağımlılıklar çözülür, hata yok.

- [ ] **Step 3: main.dart'ta sqflate FFI ve window_manager init**

`app/lib/main.dart`'ı şu şekilde güncelle (import'lar, main gövdesi değişir; `home` şimdilik `HomeShell` kalır — Task 3 sonunda `DesktopWindow` yapılacak):

```dart
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'app_theme.dart';
import 'config.dart';
import 'local_store.dart';
import 'notifications.dart';
import 'pomodoro_service.dart';
import 'platform_adaptive.dart';
import 'sync_service.dart';
import 'screens/home_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Windows/Linux/macOS'ta sqflate FFI backend gerekir (mobilde native plugin var).
  if (PlatformAdaptive.isDesktop) {
    sqflite_ffiInit();
    databaseFactory = databaseFactoryFfi;
    await windowManager.ensureInitialized();
  }

  await AppConfig.load();
  await Notifications.init();
  await SyncService.init();
  PomodoroService.init();
  SyncService.syncNow(); // fire and forget
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
          home: const HomeShell(),
        );
      },
    );
  }
}
```

- [ ] **Step 4: Analyze çalıştır (henüz window init kullanılmıyor ama import kontrolü)**

Run: `cd app && flutter analyze`
Expected: `sqflite_common_ffi` ve `window_manager` import'ları kullanıldığı için hata yok. (Geçici: `windowManager.ensureInitialized()` çağrılıyor.)

- [ ] **Step 5: Mevcut testlerin hala geçtiğini doğrula**

Run: `cd app && flutter test`
Expected: Tüm mevcut testler PASS (main.dart değişikliği testleri kırmamalı).

- [ ] **Step 6: Commit**

```bash
cd app && git add pubspec.yaml pubspec.lock lib/main.dart
git commit -m "window_manager + sqflite_common_ffi bagimliliklari, FFI init"
```

---

## Task 3: DesktopWindow — Pencere Yönetimi

Windows penceresini başlat, boyut/konum hatırla, min boyut ayarla. `window_manager` kullanır.

**Files:**
- Create: `app/lib/screens/desktop_window.dart`
- Modify: `app/lib/main.dart` (`home` artık `DesktopWindow`)

- [ ] **Step 1: desktop_window.dart oluştur**

Create `app/lib/screens/desktop_window.dart`:

```dart
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
```

- [ ] **Step 2: main.dart'ta home'u DesktopWindow yap**

`app/lib/main.dart`'ta iki değişiklik:

a) Import ekle:
```dart
import 'screens/desktop_window.dart';
```

b) `home:` satırını değiştir:
```dart
          home: PlatformAdaptive.isDesktop
              ? const DesktopWindow()
              : const HomeShell(),
```

- [ ] **Step 3: Analyze çalıştır (DesktopShell henüz yok — beklenen hata)**

Run: `cd app && flutter analyze`
Expected: `desktop_shell.dart` import çözülemedi hatası. Bu beklenen; Task 4'te oluşturuluyor. **Task 4 ile birlikte commit edilecek.**

- [ ] **Step 4: (Task 4 bittikten sonra) Commit**

Bu task'ın commit'i Task 4 ile birleşir çünkü `DesktopShell` olmadan derlenmez.

---

## Task 4: DesktopShell — Sol NavigationRail + İçerik

Masaüstü ana shell: sol NavigationRail (gizlenebilir), içerik alanı. Şimdilik içerik sadece 3 sekmeyi gösterir; reader gömme Task 5'te.

**Files:**
- Create: `app/lib/screens/desktop_shell.dart`

- [ ] **Step 1: desktop_shell.dart oluştur**

Create `app/lib/screens/desktop_shell.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sync_service.dart';
import 'library_screen.dart';
import 'pomodoro_screen.dart';
import 'schedule_screen.dart';

/// Masaustu shell: sol NavigationRail (gizlenebilir) + icerik alani.
/// Mobil HomeShell'in (alt bar) masaustu karsiligidir.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  static const _kRailHidden = 'desktop_rail_hidden';

  int _index = 0;
  bool _railHidden = false;

  final _pages = const [LibraryScreen(), ScheduleScreen(), PomodoroScreen()];

  @override
  void initState() {
    super.initState();
    _loadRailPref();
  }

  Future<void> _loadRailPref() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _railHidden = prefs.getBool(_kRailHidden) ?? false);
    }
  }

  Future<void> _toggleRail() async {
    setState(() => _railHidden = !_railHidden);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRailHidden, _railHidden);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          // Sol rail (gizlenince 0 genislik)
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: _railHidden ? 0 : 72,
            child: _railHidden
                ? const SizedBox.shrink()
                : NavigationRail(
                    selectedIndex: _index,
                    onDestinationSelected: (i) => setState(() => _index = i),
                    leading: IconButton(
                      tooltip: _railHidden ? 'Göster' : 'Gizle',
                      icon: Icon(_railHidden
                          ? Icons.chevron_right
                          : Icons.chevron_left),
                      onPressed: _toggleRail,
                    ),
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.library_books_outlined),
                        selectedIcon: Icon(Icons.library_books),
                        label: Text('Kütüphane'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.calendar_today_outlined),
                        selectedIcon: Icon(Icons.calendar_today),
                        label: Text('Program'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.timer_outlined),
                        selectedIcon: Icon(Icons.timer),
                        label: Text('Pomodoro'),
                      ),
                    ],
                  ),
          ),
          // Gizli durumda yeniden acmak icin ince tutamac
          if (_railHidden)
            GestureDetector(
              onTap: _toggleRail,
              child: Container(
                width: 6,
                color: scheme.outlineVariant.withAlpha(80),
              ),
            ),
          // Icerik alani
          Expanded(child: _pages[_index]),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Analyze çalıştır**

Run: `cd app && flutter analyze`
Expected: Temiz. `desktop_window.dart` artık `desktop_shell.dart`'ı buluyor.

- [ ] **Step 3: Testler çalıştır**

Run: `cd app && flutter test`
Expected: Tüm testler PASS.

- [ ] **Step 4: Windows'ta manuel çalıştır ve doğrula**

Run: `cd app && flutter run -d windows`
Expected:
- Pencere 1280×800 açılır
- Sol rail'de 3 sekme (Kütüphane/Program/Pomodoro), tıklayınca içerik değişir
- Gizle düğmesi (chevron) rail'i daraltır; sol kenardaki tutamacakla yeniden açılır
- Pencere boyutu değiştirilebilir, min 900×640

- [ ] **Step 5: Commit (Task 3 + Task 4 birlikte)**

```bash
cd app && git add lib/screens/desktop_window.dart lib/screens/desktop_shell.dart lib/main.dart
git commit -m "DesktopWindow + DesktopShell: pencere yonetimi, sol rail, gizleme"
```

---

## Task 5: MobileShell — Mobil Davranışı Koru

Mevcut `HomeShell`'in alt-bar mantığını `MobileShell`'a taşı; `HomeShell`'i platform seçici yap. Bu task **mobil regresyonu önler** — telefon davranışı birebir korunmalı.

**Files:**
- Create: `app/lib/screens/mobile_shell.dart`
- Modify: `app/lib/screens/home_shell.dart`

- [ ] **Step 1: mobile_shell.dart oluştur (mevcut HomeShell mantığının kopyası)**

Create `app/lib/screens/mobile_shell.dart`:

```dart
import 'package:flutter/material.dart';

import '../sync_service.dart';
import '../update_service.dart';
import 'library_screen.dart';
import 'pomodoro_screen.dart';
import 'schedule_screen.dart';

/// Mobil shell: alt NavigationBar. Mevcut HomeShell davranisinin tasiyicisidir.
class MobileShell extends StatefulWidget {
  const MobileShell({super.key});

  /// Derin ekranlardan ana sekme degistirme istegi (0: Kutuphane, 1: Program, 2: Pomodoro).
  static final ValueNotifier<int?> tabRequest = ValueNotifier(null);

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell>
    with WidgetsBindingObserver {
  int _index = 0;

  final _pages = const [LibraryScreen(), ScheduleScreen(), PomodoroScreen()];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    MobileShell.tabRequest.addListener(_onTabRequest);
    SyncService.startAutoSync();
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) UpdateService.checkAndPromptOnce(context);
    });
  }

  void _onTabRequest() {
    final t = MobileShell.tabRequest.value;
    if (t == null || t < 0 || t >= _pages.length) return;
    MobileShell.tabRequest.value = null;
    if (mounted) setState(() => _index = t);
  }

  @override
  void dispose() {
    MobileShell.tabRequest.removeListener(_onTabRequest);
    WidgetsBinding.instance.removeObserver(this);
    SyncService.stopAutoSync();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) SyncService.syncNow();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.library_books),
            label: 'Kütüphane',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_today),
            label: 'Program',
          ),
          NavigationDestination(icon: Icon(Icons.timer), label: 'Pomodoro'),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: home_shell.dart'ı platform seçici yap**

`app/lib/screens/home_shell.dart`'ı şu şekilde değiştir (mevcut `tabRequest` referansları `MobileShell.tabRequest`'a yönlendirilmeli; önce kod tabanında nerede kullanıldığına bak):

Önce `tabRequest` kullanımını kontrol et:
Run: `cd app && grep -rn "HomeShell.tabRequest" lib/`

`subject_pdfs_screen.dart` veya başka dosyalarda kullanılıyorsa, hepsini `MobileShell.tabRequest` ile değiştir. Tipik kullanım: program/öneri ekranından kütüphaneye dönmek için.

Değiştir (bulunan her dosyada):
```dart
// eski:
import 'home_shell.dart';
HomeShell.tabRequest.value = 0;
// yeni:
import 'mobile_shell.dart';
MobileShell.tabRequest.value = 0;
```

Sonra `app/lib/screens/home_shell.dart`'ı sadeleştir:

```dart
import 'package:flutter/material.dart';

import '../platform_adaptive.dart';
import 'mobile_shell.dart';

/// Platform'a gore shell secer. Mobilde alt-bar, masaustunde sol-rail.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context) {
    if (PlatformAdaptive.isDesktop) {
      // Masaustunde DesktopWindow zaten main.dart'ta home olarak verilir;
      // buraya dusmemeli ama guvenlik icin.
      return const MobileShell();
    }
    return const MobileShell();
  }
}
```

- [ ] **Step 3: Analyze çalıştır**

Run: `cd app && flutter analyze`
Expected: Temiz. `HomeShell.tabRequest` referanslarının hepsi güncellenmiş olmalı.

- [ ] **Step 4: Testler çalıştır**

Run: `cd app && flutter test`
Expected: Tüm testler PASS.

- [ ] **Step 5: Mobil regresyonu manuel doğrula (Android emülatör veya cihaz)**

Run: `cd app && flutter run -d <android-device>`
Expected: Alt NavigationBar görünür, 3 sekme çalışır, `tabRequest` ile sekme değişimi çalışır. Davranış değişikliği yok.

- [ ] **Step 6: Commit**

```bash
cd app && git add lib/screens/mobile_shell.dart lib/screens/home_shell.dart <degisen diger dosyalar>
git commit -m "MobileShell: mobil davranisi koru, HomeShell platform secici"
```

---

## Task 6: Reader'ı Masaüstünde Gömülü Gösterme

"Yan panel + okuyucu" düzeni. Kütüphane sekmesinde bir PDF açıldığında içerik alanı ikiye bölünür: solda kütüphane listesi (dar), sağda `ReaderScreen`. Mobilde davranış değişmez (hala `Navigator.push` tam ekran).

**Files:**
- Modify: `app/lib/screens/desktop_shell.dart`
- Modify: `app/lib/screens/library_screen.dart` (`_openPdf` masaüstünde gömülü açılacak şekilde)

Bu en karmaşık görev. Strateji: `DesktopShell`, aktif PDF'i state olarak tutar; null ise normal sekme içerikleri, dolu ise kütüphane+reader bölünmüş görünür.

- [ ] **Step 1: DesktopShell'e reader gömme state'i ekle**

`app/lib/screens/desktop_shell.dart`'ı güncelle. En üste import ekle:

```dart
import '../models.dart';
import 'reader_screen.dart';
```

`_DesktopShellState` içinde state ekle (mevcut `_index` ve `_railHidden`'a ek olarak):

```dart
  PdfDoc? _activeDoc;
  int? _activeInitialPage;

  void openDoc(PdfDoc doc) {
    setState(() {
      _activeDoc = doc;
      _activeInitialPage = null;
      _index = 0; // kütüphane sekmesinde oldugumuzdan emin ol
    });
  }

  void closeDoc() {
    setState(() => _activeDoc = null);
  }
```

`build` metodunu güncelle — içerik alanı `_activeDoc`'a göre bölünür:

```dart
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget content;
    if (_activeDoc != null && _index == 0) {
      // Kütüphane + reader bolunmus gorunum
      content = Row(
        children: [
          SizedBox(
            width: 280,
            child: LibraryScreen(
              onOpenDoc: openDoc,
              onCloseReader: closeDoc,
            ),
          ),
          Container(width: 1, color: scheme.outlineVariant),
          Expanded(
            child: ReaderScreen(
              doc: _activeDoc!,
              initialPage: _activeInitialPage,
            ),
          ),
        ],
      );
    } else {
      content = _pages[_index];
    }
    return Scaffold(
      body: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: _railHidden ? 0 : 72,
            child: _railHidden
                ? const SizedBox.shrink()
                : NavigationRail(
                    selectedIndex: _index,
                    onDestinationSelected: (i) => setState(() {
                      _index = i;
                      // Sekme degisince acik reader'i kapat
                      _activeDoc = null;
                    }),
                    leading: IconButton(
                      tooltip: _railHidden ? 'Göster' : 'Gizle',
                      icon: Icon(_railHidden
                          ? Icons.chevron_right
                          : Icons.chevron_left),
                      onPressed: _toggleRail,
                    ),
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.library_books_outlined),
                        selectedIcon: Icon(Icons.library_books),
                        label: Text('Kütüphane'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.calendar_today_outlined),
                        selectedIcon: Icon(Icons.calendar_today),
                        label: Text('Program'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.timer_outlined),
                        selectedIcon: Icon(Icons.timer),
                        label: Text('Pomodoro'),
                      ),
                    ],
                  ),
          ),
          if (_railHidden)
            GestureDetector(
              onTap: _toggleRail,
              child: Container(
                width: 6,
                color: scheme.outlineVariant.withAlpha(80),
              ),
            ),
          Expanded(child: content),
        ],
      ),
    );
  }
```

- [ ] **Step 2: LibraryScreen'e opsiyonel callback'ler ekle**

`app/lib/screens/library_screen.dart`'ta iki değişiklik:

a) `LibraryScreen` widget'ına opsiyonel parametreler ekle:

```dart
class LibraryScreen extends StatefulWidget {
  final void Function(PdfDoc doc)? onOpenDoc;
  final VoidCallback? onCloseReader;

  const LibraryScreen({super.key, this.onOpenDoc, this.onCloseReader});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}
```

b) `_openPdf` metodunu güncelle — `onOpenDoc` set ise `Navigator.push` yerine onu çağır:

```dart
  Future<void> _openPdf(PdfDoc doc) async {
    await LocalStore.markRecent(doc.id);
    try {
      await Api.markRecent(doc.id);
      await LocalStore.clearRecentDirty(doc.id);
    } catch (_) {}
    if (!mounted) return;
    if (widget.onOpenDoc != null) {
      widget.onOpenDoc!(doc);
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ReaderScreen(doc: doc)),
      );
      if (mounted) _refresh();
    }
  }
```

- [ ] **Step 3: Analyze çalıştır**

Run: `cd app && flutter analyze`
Expected: Temiz.

- [ ] **Step 4: Windows'ta manuel çalıştır ve doğrula**

Run: `cd app && flutter run -d windows`
Expected:
- Kütüphane sekmesinde PDF'e tıkla → içerik ikiye bölünür: solda kütüphane (280px), sağda reader
- Reader içinde sayfa değiştir, işaretleme yap — çalışmalı
- Kütüphanede başka PDF'e tıkla → reader değişir
- Sekme değiştir (Program/Pomodoro) → reader kapanır

- [ ] **Step 5: Mobil regresyonu doğrula**

Run: `cd app && flutter run -d <android>`
Expected: PDF'e tıklanınca hala tam ekran `Navigator.push` ile açılır (`onOpenDoc` null).

- [ ] **Step 6: Commit**

```bash
cd app && git add lib/screens/desktop_shell.dart lib/screens/library_screen.dart
git commit -m "Reader masaustunde yan panel + okuyucu olarak gomulu"
```

---

## Task 7: Reader Klavye Kısayolları

Masaüstünde sayfa geçişi (← →), arama (Ctrl+F), kapatma (Esc).

**Files:**
- Modify: `app/lib/screens/reader_screen.dart`

- [ ] **Step 1: Reader'a KeyboardListener (FocusNode + onKeyEvent) ekle**

`app/lib/screens/reader_screen.dart`'ta `_ReaderScreenState`'e ekle:

a) En üste import:
```dart
import 'package:flutter/services.dart' show LogicalKeyboardKey, HardwareKeyboard;
import '../platform_adaptive.dart';
```

b) State'e FocusNode ekle (mevcut field'lardan sonra):
```dart
  final FocusNode _focusNode = FocusNode();
```

c) `initState`'e ekle:
```dart
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
```

d) `dispose`'a ekle:
```dart
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _focusNode.dispose();
```

e) Klavye handler metodunu ekle:
```dart
  bool _onKeyEvent(KeyEvent event) {
    if (!PlatformAdaptive.isDesktop) return false;
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;

    // Ctrl+F: arama
    if (ctrl && key == LogicalKeyboardKey.keyF) {
      if (!_searching) _openSearch();
      return true;
    }
    // Esc: aramayi kapat
    if (key == LogicalKeyboardKey.escape) {
      if (_searching) {
        _closeSearch();
        return true;
      }
      return false;
    }
    // Sol ok: onceki sayfa
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_controller.isReady && _currentPage > 1) {
        _controller.goToPage(pageNumber: _currentPage - 1);
        return true;
      }
    }
    // Sag ok: sonraki sayfa
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_controller.isReady && _pageCount != null && _currentPage < _pageCount!) {
        _controller.goToPage(pageNumber: _currentPage + 1);
        return true;
      }
    }
    return false;
  }
```

f) `build` metodunun `Scaffold`'unu `Focus` ile sar (en dış katman):
```dart
  @override
  Widget build(BuildContext context) {
    final effectiveView = _effectiveViewMode(context);
    final textSearcher = _textSearcher;
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      child: Scaffold(
        // ... mevcut Scaffold icerigi aynen ...
      ),
    );
  }
```

- [ ] **Step 2: Analyze çalıştır**

Run: `cd app && flutter analyze`
Expected: Temiz.

- [ ] **Step 3: Windows'ta manuel doğrula**

Run: `cd app && flutter run -d windows`
Expected:
- Reader açıkken `→` sonraki sayfa, `←` önceki sayfa
- `Ctrl+F` arama kutusu açılır
- `Esc` aramayı kapatır

- [ ] **Step 4: Commit**

```bash
cd app && git add lib/screens/reader_screen.dart
git commit -m "Reader klavye kisayollari (oklar, Ctrl+F, Esc)"
```

---

## Task 8: Pomodoro Space Kısayolu

Pomodoro ekranında Space ile başlat/duraklat (sadece masaüstü).

**Files:**
- Modify: `app/lib/screens/pomodoro_screen.dart`

- [ ] **Step 1: PomodoroScreen'e klavye handler ekle**

`app/lib/screens/pomodoro_screen.dart`'ı oku (tam içeriği gör). Sonra:

`PomodoroScreen` widget'ını `StatefulWidget`'a çevirmek yerine, en sade yol: `KeyboardListener`/`Focus` ile sarmak. Mevcut `StatelessWidget` yapısı korunabilir:

a) Import ekle:
```dart
import 'package:flutter/services.dart';
import '../platform_adaptive.dart';
```

b) `build` metodunun en dışını `Focus` ile sar:
```dart
  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (!PlatformAdaptive.isDesktop) return KeyEventResult.ignored;
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.space) {
          if (PomodoroService.state.value.running) {
            PomodoroService.pause();
          } else {
            PomodoroService.start();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: _buildScaffold(context),
    );
  }
```

Mevcut `build` metodunun gövdesini `_buildScaffold(BuildContext context)`'a taşı.

- [ ] **Step 2: Analyze çalıştır**

Run: `cd app && flutter analyze`
Expected: Temiz.

- [ ] **Step 3: Windows'ta manuel doğrula**

Run: `cd app && flutter run -d windows`
Expected: Pomodoro sekmesinde Space tuşu sayaç başlatır/duraklatır.

- [ ] **Step 4: Commit**

```bash
cd app && git add lib/screens/pomodoro_screen.dart
git commit -m "Pomodoro Space kisa yolu (baslat/duraklat)"
```

---

## Task 9: Kütüphanede Sağ Tık Bağlam Menüsü (Masaüstü)

Kütüphanede PDF'e sağ tık → taşı/kopyala/sil/favori. Mobilde görünmez. Mevcut `PopupMenuButton`'ı kullanan kod zaten var; sağ tık bu menüyü açar.

**Files:**
- Modify: `app/lib/screens/library_screen.dart`

- [ ] **Step 1: _pdfTile'a onSecondaryTap ekle**

`app/lib/screens/library_screen.dart`'ta `_pdfTile` metodundaki `Material` widget'ını `GestureDetector` ile sar (sağ tık yakala). Mevcut `trailing: PopupMenuButton` korunur.

Import ekle (en üstte yoksa):
```dart
import '../platform_adaptive.dart';
```

`_pdfTile` metodunda, `Material` widget'ını `GestureDetector` ile sar:

```dart
  Widget _pdfTile(PdfDoc doc) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selectedDocIds.contains(doc.id);
    final progress = _progressLine(doc);
    const gold = Color(0xFFC5A880);
    return GestureDetector(
      onSecondaryTap: () {
        // Sadece masaustunde saga tik menusu
        if (!PlatformAdaptive.isDesktop) return;
        _showPdfContextMenu(context, doc);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Material(
          // ... mevcut Material icerigi aynen ...
        ),
      ),
    );
  }
```

`_showPdfContextMenu` metodunu ekle:

```dart
  void _showPdfContextMenu(BuildContext context, PdfDoc doc) {
    final RenderBox box = context.findRenderObject() as RenderBox;
    final Offset position = box.localToGlobal(Offset.zero);
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + box.size.width,
        position.dy + box.size.height,
      ),
      items: const [
        PopupMenuItem(value: 'move', child: Text('Taşı')),
        PopupMenuItem(value: 'copy', child: Text('Kopyala')),
        PopupMenuItem(value: 'delete', child: Text('Sil')),
        PopupMenuItem(
          value: 'favorite',
          child: Text('Favoriye ekle/çıkar'),
        ),
      ],
    ).then((action) {
      if (action == 'move') _movePdf(doc);
      if (action == 'copy') _copyPdf(doc);
      if (action == 'delete') _deletePdf(doc);
      if (action == 'favorite') {
        LocalStore.setFavorite(doc.id, !doc.favorite, dirty: true).then((_) {
          _refresh();
        });
      }
    });
  }
```

- [ ] **Step 2: Analyze çalıştır**

Run: `cd app && flutter analyze`
Expected: Temiz.

- [ ] **Step 3: Windows'ta manuel doğrula**

Run: `cd app && flutter run -d windows`
Expected: Kütüphanede PDF'e sağ tık → bağlam menüsü açılır; taşı/kopyala/sil/favori çalışır.

- [ ] **Step 4: Commit**

```bash
cd app && git add lib/screens/library_screen.dart
git commit -m "Kutuphanede saga tik baglam menusu (masaustu)"
```

---

## Task 10: Windows Build + Son Doğrulama

Windows release build al, tüm akışı uçtan uca doğrula, dokümantasyon/README güncelle.

**Files:**
- Modify: `app/README.md` (opsiyonel, Windows build talimatları)

- [ ] **Step 1: flutter analyze (temiz olmalı)**

Run: `cd app && flutter analyze`
Expected: Uyarı/hata yok.

- [ ] **Step 2: flutter test (tüm testler geçmeli)**

Run: `cd app && flutter test`
Expected: Tüm testler PASS.

- [ ] **Step 3: Windows release build al**

Run: `cd app && flutter build windows --release`
Expected: Build başarılı; `build/windows/x64/runner/Release/` altında `.exe` oluşur.

- [ ] **Step 4: Build çıktısını çalıştır ve uçtan uca doğrula**

Release exe'yi çalıştır. Doğrula:
- Pencere açılır, boyut/konum hatırlanır
- Kütüphane: sunucuya bağlanır, PDF listesi gelir
- PDF açma: gömülü reader, sayfa geçişi, işaretleme
- Klavye kısayolları (← → Ctrl+F Esc)
- Sağ tık menüsü
- Program ve Pomodoro sekmeleri çalışır
- Sync: telefonda kaldığı sayfadan devam (aynı sunucu)
- Rail gizle/göster

- [ ] **Step 5: Mobil regresyon son kontrol (opsiyonel ama önerilir)**

Run: `cd app && flutter run -d <android>`
Expected: Tüm mobil davranış aynı; alt NavigationBar, tam ekran reader, `tabRequest`.

- [ ] **Step 6: README'ye Windows build talimatı ekle (opsiyonel)**

`app/README.md`'ye ekle:

```markdown
## Windows Build

```bash
cd app
flutter build windows --release
# Cikti: build/windows/x64/runner/Release/belgelik.exe
```

Gereksinimler: Visual Studio (C++ masaüstü iş yükü), Flutter 3.x.
```

- [ ] **Step 7: Commit**

```bash
cd app && git add README.md
git commit -m "Windows build talimatlari (README)"
```

---

## Bitiş Kontrolü

Uygulama tamamlandığında şu karşılamalı:
- [ ] Windows'ta `flutter run -d windows` ve `flutter build windows --release` çalışır
- [ ] Yan panel + okuyucu düzeni (PDF açıkken ikiye bölünme)
- [ ] NavigationRail gizlenebilir (durum hatırlanır)
- [ ] Pencere boyut/konum hatırlanır, min 900×640
- [ ] Klavye kısayolları (← → Ctrl+F Esc Space)
- [ ] Sağ tık bağlam menüsü
- [ ] Mobil (Android) davranışı %100 korunmuş
- [ ] `flutter analyze` temiz, `flutter test` geçer
- [ ] Sync telefon ile masaüstü arasında çalışır (last-write-wins)
