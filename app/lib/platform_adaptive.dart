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
