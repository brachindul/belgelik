import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models.dart';
import 'app_tabs.dart';
import 'home_shell.dart';
import 'library_screen.dart';
import 'note_editor_screen.dart';
import 'pomodoro_screen.dart';
import 'reader_screen.dart';
import 'schedule_screen.dart';
import 'video_library_screen.dart';

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

  // Reader gomme state'i (Task 6). Null ise normal sekme; dolu ise
  // kütüphane + reader bölünmüş görünür.
  PdfDoc? _activeDoc;
  // Not editoru gomme state'i (Faz E). PDF akışindan ayrı; dolu ise
  // kütüphane + not editoru bölünmüş görünür.
  NoteListItem? _activeNote;

  Widget _pageFor(AppTabKind kind) {
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
    _loadRailPref();
    // subject_pdfs gibi derin ekranlardan sekme degistirme istegi (mobil ile
    // paylasilan global notifier).
    HomeShell.tabRequest.addListener(_onTabRequest);
  }

  void _onTabRequest() {
    final t = HomeShell.tabRequest.value;
    if (t == null || t < 0) return;
    HomeShell.tabRequest.value = null;
    if (mounted) {
      setState(() {
        _index = t; // yalniz Kutuphane (0); o her zaman ilk sekme
        _activeDoc = null;
        _activeNote = null;
      });
    }
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
  void dispose() {
    HomeShell.tabRequest.removeListener(_onTabRequest);
    super.dispose();
  }

  void openDoc(PdfDoc doc) {
    setState(() {
      _activeDoc = doc;
      _activeNote = null;
      _index = 0; // kütüphane sekmesinde oldugumuzdan emin ol
    });
  }

  void openNote(NoteListItem note) {
    setState(() {
      _activeNote = note;
      _activeDoc = null;
      _index = 0;
    });
  }

  void closeDoc() {
    setState(() {
      _activeDoc = null;
      _activeNote = null;
    });
  }

  Widget _buildContent(AppTabMeta tab) {
    final scheme = Theme.of(context).colorScheme;
    if (tab.kind == AppTabKind.library && _activeDoc != null) {
      // Kütüphane + reader bölünmüş görünüm.
      return Row(
        children: [
          SizedBox(
            width: 280,
            child: LibraryScreen(
              onOpenDoc: openDoc,
              onOpenNote: openNote,
            ),
          ),
          Container(width: 1, color: scheme.outlineVariant),
          Expanded(
            child: ReaderScreen(doc: _activeDoc!),
          ),
        ],
      );
    }
    if (tab.kind == AppTabKind.library && _activeNote != null) {
      // Kütüphane + not editoru bölünmüş görünüm (Faz E).
      return Row(
        children: [
          SizedBox(
            width: 280,
            child: LibraryScreen(
              onOpenDoc: openDoc,
              onOpenNote: openNote,
            ),
          ),
          Container(width: 1, color: scheme.outlineVariant),
          Expanded(
            child: NoteEditorScreen(
              item: _activeNote!,
              onClose: closeDoc,
            ),
          ),
        ],
      );
    }
    return _pageFor(tab.kind);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: AppConfig.featuresNotifier,
      builder: (context, features, _) {
        final tabs = activeTabs(features);
        final effective = tabs.isEmpty ? [kAllTabs.first] : tabs;
        final idx = _index.clamp(0, effective.length - 1);
        return _buildScaffold(effective, idx);
      },
    );
  }

  Widget _buildScaffold(List<AppTabMeta> tabs, int idx) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: _railHidden ? 0 : 96,
            child: _railHidden
                ? const SizedBox.shrink()
                : NavigationRail(
                    selectedIndex: idx,
                    // Etiketleri hep goster ve hedefleri dikeyde ortala;
                    // boylece ikonlar yukari yiilmaz, alt bosluk dengelenir.
                    labelType: NavigationRailLabelType.all,
                    groupAlignment: 0.0,
                    minWidth: 96,
                    onDestinationSelected: (i) => setState(() {
                      _index = i;
                      // Sekme degisince acik reader/not editorunu kapat.
                      _activeDoc = null;
                      _activeNote = null;
                    }),
                    leading: IconButton(
                      tooltip: _railHidden ? 'Göster' : 'Gizle',
                      icon: Icon(_railHidden
                          ? Icons.chevron_right
                          : Icons.chevron_left),
                      onPressed: _toggleRail,
                    ),
                    destinations: [
                      for (final t in tabs)
                        NavigationRailDestination(
                          icon: Icon(t.icon),
                          selectedIcon: Icon(t.selectedIcon),
                          label: Text(t.label),
                        ),
                    ],
                  ),
          ),
          if (_railHidden)
            // Rail gizliyken geri acma tutamagi. 6px'lik cizgi fare/trackpad ile
            // isabet ettirilemiyordu; gorunur ikonlu ve genis bir serit.
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: _toggleRail,
                child: Tooltip(
                  message: 'Menüyü göster',
                  child: Container(
                    width: 24,
                    color: scheme.surfaceContainerHighest,
                    alignment: Alignment.topCenter,
                    padding: const EdgeInsets.only(top: 12),
                    child: Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          Expanded(child: _buildContent(tabs[idx])),
        ],
      ),
    );
  }
}
