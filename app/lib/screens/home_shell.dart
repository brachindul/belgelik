import 'package:flutter/material.dart';

import '../config.dart';
import '../sync_service.dart';
import '../update_service.dart';
import 'app_tabs.dart';
import 'library_screen.dart';
import 'pomodoro_screen.dart';
import 'schedule_screen.dart';
import 'video_library_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// Derin ekranlardan ana sekme degistirme istegi (0: Kutuphane, 1: Program, 2: Pomodoro).
  static final ValueNotifier<int?> tabRequest = ValueNotifier(null);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;

  static Widget _pageFor(AppTabKind kind) {
    switch (kind) {
      case AppTabKind.library:
        return const LibraryScreen();
      case AppTabKind.program:
        return const ScheduleScreen();
      case AppTabKind.pomodoro:
        return const PomodoroScreen();
      case AppTabKind.videos:
        return const VideoLibraryScreen();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HomeShell.tabRequest.addListener(_onTabRequest);
    SyncService.startAutoSync();
    // Acilista sessiz guncelleme denetimi (UI otursun diye kisa gecikmeyle).
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) UpdateService.checkAndPromptOnce(context);
    });
  }

  void _onTabRequest() {
    final t = HomeShell.tabRequest.value;
    if (t == null || t < 0) return;
    HomeShell.tabRequest.value = null;
    // tabRequest yalniz Kutuphane'ye (0) yonlendirir; o her zaman ilk sekmedir.
    if (mounted) setState(() => _index = t);
  }

  @override
  void dispose() {
    HomeShell.tabRequest.removeListener(_onTabRequest);
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
    return ValueListenableBuilder<List<String>>(
      valueListenable: AppConfig.featuresNotifier,
      builder: (context, features, _) {
        final tabs = activeTabs(features);
        // Tek sekme bile yoksa Kutuphane'yi garanti et (asla bos kalmasin).
        final effective = tabs.isEmpty ? [kAllTabs.first] : tabs;
        final idx = _index.clamp(0, effective.length - 1);
        return Scaffold(
          body: IndexedStack(
            index: idx,
            children: [for (final t in effective) _pageFor(t.kind)],
          ),
          bottomNavigationBar: effective.length < 2
              ? null
              : NavigationBar(
                  selectedIndex: idx,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  destinations: [
                    for (final t in effective)
                      NavigationDestination(
                        icon: Icon(t.icon),
                        selectedIcon: Icon(t.selectedIcon),
                        label: t.label,
                      ),
                  ],
                ),
        );
      },
    );
  }
}
