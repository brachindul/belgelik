import 'package:flutter/material.dart';

/// Uygulama sekmeleri ve profil ozelligi (feature) eslemesi.
/// Hem mobil (HomeShell) hem masaustu (DesktopShell) buradan beslenir.
enum AppTabKind { library, program, pomodoro, videos }

class AppTabMeta {
  final AppTabKind kind;
  final String feature;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  const AppTabMeta(
    this.kind,
    this.feature,
    this.label,
    this.icon,
    this.selectedIcon,
  );
}

const List<AppTabMeta> kAllTabs = [
  AppTabMeta(
    AppTabKind.library,
    'library',
    'Kütüphane',
    Icons.library_books_outlined,
    Icons.library_books,
  ),
  AppTabMeta(
    AppTabKind.program,
    'program',
    'Program',
    Icons.calendar_today_outlined,
    Icons.calendar_today,
  ),
  AppTabMeta(
    AppTabKind.pomodoro,
    'pomodoro',
    'Pomodoro',
    Icons.timer_outlined,
    Icons.timer,
  ),
  AppTabMeta(
    AppTabKind.videos,
    'videos',
    'Videolar',
    Icons.play_circle_outline,
    Icons.play_circle_fill,
  ),
];

/// Profilin feature listesine gore acik sekmeler (kAllTabs sirasini korur).
List<AppTabMeta> activeTabs(List<String> features) => [
      for (final t in kAllTabs)
        if (features.contains(t.feature)) t,
    ];
