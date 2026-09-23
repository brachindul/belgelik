import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../app_services.dart';
import '../config.dart';
import '../ink.dart';
import '../local_store.dart';
import '../models.dart';
import '../notifications.dart';
import '../pen_palette.dart';
import '../platform_adaptive.dart';
import '../pomodoro_service.dart';
import '../sync_service.dart';

part 'reader_page_layout.dart';
part 'reader_toolbar.dart';
part 'reader_annotation_layer.dart';

enum DrawMode { pan, pen, highlight, eraser, rect, arrow, text }

enum StylusMode { pen, highlight, eraser }

enum ViewMode { auto, single, twoVertical }

class ReaderScreen extends StatefulWidget {
  final PdfDoc doc;
  final int? initialPage;
  // Bolunmus gorunumde (video + PDF) saglanir: appbar'da geri yerine kapat
  // butonu gosterir ve rotayi pop etmek yerine paneli kapatir.
  final VoidCallback? onClose;
  // Genis ekranda saglanir: appbar'da "yanda video ac" butonu gosterir
  // (ReaderHostScreen bolunmus gorunumu yonetir).
  final VoidCallback? onOpenVideo;
  const ReaderScreen({
    super.key,
    required this.doc,
    this.initialPage,
    this.onClose,
    this.onOpenVideo,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final PdfViewerController _controller = PdfViewerController();
  PdfTextSearcher? _textSearcher;
  final TextEditingController _searchCtrl = TextEditingController();
  late Future<_ReaderData> _loadFuture;

  int _currentPage = 1;
  Timer? _debounce;
  DrawMode _mode = DrawMode.pan;
  ViewMode _viewMode = ViewMode.auto;
  bool _searching = false;
  final Map<int, List<Stroke>> _byPage = {};
  final List<Stroke> _history = [];
  bool _annotationsLoaded = false;
  ReadingGoal? _goal;
  int? _pageCount;

  int _penColor = kPenPalette.first;
  int _highlightColor = kHighlightPalette.first;
  int _textColor = 0xFF111827;
  double _penWidth = kDefaultPenWidth;
  double _highlightWidth = kDefaultHighlightWidth;
  double _textFontSize = 18;
  String _textFontFamily = 'default';
  int _strokeSeq = 0;
  // Yerinde duzenlenen isaretlemelerde (liste uzunlugu degismeden) katmanin
  // yeniden kurulmasi icin anahtara giren revizyon sayaci.
  int _annoRev = 0;
  int _bmSeq = 0;
  List<Bookmark> _bookmarks = [];
  StylusMode _stylusMode = StylusMode.pen;
  bool _stylusDown = false;
  String _nightMode = AppConfig.nightMode;
  double _dimLevel = AppConfig.dimLevel;
  // Serit takip asistani: zoom esigini gecince kaydirma eksene kilitlenir.
  double? _fitZoom;
  bool _panAxisLocked = false;
  // Yuzen dock: asagi kaydirinca kuculur, yukari kaydirinca/dokununca acilir.
  bool _dockCollapsed = false;
  double _lastScrollY = 0;
  double _lastScrollZoom = 0;
  PomodoroPhase? _lastPomodoroPhase;

  static const _identityMatrix = <double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
  static const _invertMatrix = <double>[
    -1,
    0,
    0,
    0,
    255,
    0,
    -1,
    0,
    0,
    255,
    0,
    0,
    -1,
    0,
    255,
    0,
    0,
    0,
    1,
    0,
  ];
  static const _sepiaMatrix = <double>[
    0.393,
    0.769,
    0.189,
    0,
    0,
    0.349,
    0.686,
    0.168,
    0,
    0,
    0.272,
    0.534,
    0.131,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];

  @override
  void initState() {
    super.initState();
    _viewMode = parseViewMode(AppConfig.viewMode);
    _controller.addListener(_onZoomChanged);
    _loadFuture = _load();
    _lastPomodoroPhase = PomodoroService.state.value.phase;
    PomodoroService.state.addListener(_onPomodoroChanged);
    // Masaüstünde klavye kısayolları (oklar, Ctrl+F, Esc).
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  bool _onKeyEvent(KeyEvent event) {
    if (!PlatformAdaptive.isDesktop) return false;
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;

    // Ctrl+F: PDF içinde ara
    if (ctrl && key == LogicalKeyboardKey.keyF) {
      if (!_searching) _openSearch();
      return true;
    }
    // Esc: aramayı kapat
    if (key == LogicalKeyboardKey.escape) {
      if (_searching) {
        _closeSearch();
        return true;
      }
      return false;
    }
    // Sol ok: önceki sayfa
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_controller.isReady && _currentPage > 1) {
        _controller.goToPage(pageNumber: _currentPage - 1);
        return true;
      }
    }
    // Sağ ok: sonraki sayfa
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_controller.isReady &&
          _pageCount != null &&
          _currentPage < _pageCount!) {
        _controller.goToPage(pageNumber: _currentPage + 1);
        return true;
      }
    }
    return false;
  }

  void _onPomodoroChanged() {
    final current = PomodoroService.state.value;
    final previous = _lastPomodoroPhase;
    if (previous != null && previous != current.phase && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            current.phase == PomodoroPhase.brk
                ? 'Mola zamanı'
                : 'Çalışmaya başla',
          ),
          action: SnackBarAction(
            label: '5 dk uzat',
            onPressed: () => PomodoroService.extend(const Duration(minutes: 5)),
          ),
        ),
      );
    }
    _lastPomodoroPhase = current.phase;
  }

  // Stylus/pan yonetimi: S Pen gorulur gorulmez (hover dahil) pdfrx pan'i
  // kapatilir ki darbe basladiginda rebuild jank'i olmasin; kalem temasta
  // degilken ~700 ms gorunmezse pan geri acilir. Boylece darbeler arasinda
  // pan'in acilip kapanip sayfayi oynatmasi da onlenir. Zamanlayici burada
  // (katman yerine) durur cunku katman her commit'te yeniden kurulur.
  bool _penContact = false;
  int _lastStylusSeenMs = 0;
  Timer? _stylusReleaseTimer;

  void _noteStylusSeen() {
    _lastStylusSeenMs = DateTime.now().millisecondsSinceEpoch;
    if (!_stylusDown) setState(() => _stylusDown = true);
    _armStylusRelease();
  }

  void _armStylusRelease() {
    _stylusReleaseTimer ??= Timer(const Duration(milliseconds: 750), () {
      _stylusReleaseTimer = null;
      if (!mounted) return;
      final idleMs =
          DateTime.now().millisecondsSinceEpoch - _lastStylusSeenMs;
      if (!_penContact && idleMs >= 700) {
        if (_stylusDown) setState(() => _stylusDown = false);
      } else if (_stylusDown) {
        _armStylusRelease();
      }
    });
  }

  void _setStylusDown(bool down) {
    _penContact = down;
    _noteStylusSeen();
  }

  void _toggleStylusPenHighlight() {
    setState(() {
      _stylusMode = _stylusMode == StylusMode.highlight
          ? StylusMode.pen
          : StylusMode.highlight;
    });
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  ViewMode _effectiveViewMode(BuildContext context) {
    if (_viewMode != ViewMode.auto) return _viewMode;
    final mq = MediaQuery.of(context);
    final wide =
        mq.orientation == Orientation.landscape || mq.size.shortestSide >= 600;
    return wide ? ViewMode.twoVertical : ViewMode.single;
  }

  void _setViewMode(ViewMode m) {
    setState(() => _viewMode = m);
    AppConfig.setViewMode(m.name);
    // Gorunum degisince fit zoom da degisir; referansi yeniden yakala.
    _fitZoom = null;
    _controller.invalidate();
  }

  void _onZoomChanged() {
    if (!_controller.isReady) return;
    final z = _controller.currentZoom;
    // Fit zoom'u "gorulen en dusuk zoom" olarak takip et: viewer acilista
    // birim matrisle (zoom=1.0) baslayip sonra fit'e indigi icin tek seferlik
    // yakalama yanlis referans verebiliyor.
    if (z > 0 && (_fitZoom == null || z < _fitZoom!)) _fitZoom = z;
    // Esik ayarlardan gelir (AppConfig.panLockPercent). 0 = her zaman kilitli;
    // aksi halde fit zoom'un %N ustunde devreye girer.
    final percent = AppConfig.panLockPercent;
    final locked =
        percent == 0 ||
        (_fitZoom != null && z > _fitZoom! * (1 + percent / 100));
    if (locked != _panAxisLocked) {
      setState(() => _panAxisLocked = locked);
    }
    _updateDockForScroll(z);
  }

  /// Dikey kaydirma yonune gore dock'u kucult/buyut. Zoom degisirken
  /// (pinch) ceviri de degistigi icin o kareler atlanir.
  void _updateDockForScroll(double zoom) {
    final y = _controller.value.getTranslation().y;
    final zoomChanged = (zoom - _lastScrollZoom).abs() > 0.001;
    final dy = y - _lastScrollY;
    _lastScrollY = y;
    _lastScrollZoom = zoom;
    if (zoomChanged || dy.abs() < 2) return;
    // Icerik yukari kayiyorsa (y azaliyor) kullanici asagi kaydiriyordur.
    final scrollingDown = dy < 0;
    if (scrollingDown != _dockCollapsed) {
      setState(() => _dockCollapsed = scrollingDown);
    }
  }

  Future<_ReaderData> _load() async {
    File file;
    if (widget.doc.localFilePath != null &&
        File(widget.doc.localFilePath!).existsSync()) {
      file = File(widget.doc.localFilePath!);
    } else {
      file = await AppServices.instance.api.downloadPdf(widget.doc);
    }
    ReadingPosition? serverPos;
    List<Stroke> strokes = [];
    try {
      serverPos = await AppServices.instance.api.getPosition(widget.doc.id);
    } catch (_) {}
    try {
      strokes = await AppServices.instance.api.getAnnotations(widget.doc.id);
    } catch (_) {}
    final localPos = await LocalStore.getPosition(widget.doc.id);
    // Use whichever is newer
    ReadingPosition? finalPos;
    if (serverPos != null && localPos != null) {
      finalPos = (localPos.updatedAt > serverPos.updatedAt)
          ? localPos
          : serverPos;
    } else {
      finalPos = localPos ?? serverPos;
    }
    final today = DateTime.now();
    final goal = await _loadOrCreateReadingGoal(today, finalPos?.page ?? 1);
    final localStrokes = await LocalStore.getLocalAnnotations(widget.doc.id);
    // Merge: server strokes first, then local strokes not already in server
    final serverUuids = strokes.map((s) => s.strokeUuid).toSet();
    for (final ls in localStrokes) {
      if (ls.strokeUuid != null && !serverUuids.contains(ls.strokeUuid)) {
        strokes.add(ls);
      }
    }
    _byPage.clear();
    for (final s in strokes) {
      (_byPage[s.page] ??= []).add(s);
    }
    _annotationsLoaded = true;
    _goal = goal;
    final bms = await LocalStore.getLocalBookmarks(widget.doc.id);
    _bookmarks = bms;
    return _ReaderData(file: file, savedPage: finalPos?.page);
  }

  Future<ReadingGoal?> _loadOrCreateReadingGoal(
    DateTime date,
    int startPage,
  ) async {
    try {
      var goal = await AppServices.instance.api.getReadingGoal(widget.doc.id, date);
      goal ??= await AppServices.instance.api.putReadingGoal(
        widget.doc.id,
        date,
        startPage,
        AppConfig.readingTargetPages,
      );
      await LocalStore.upsertReadingGoal(goal, dirty: false);
      return goal;
    } catch (_) {
      var localGoal = await LocalStore.getReadingGoal(widget.doc.id, date);
      localGoal ??= await LocalStore.putReadingGoal(
        widget.doc.id,
        date,
        startPage,
        AppConfig.readingTargetPages,
        dirty: true,
      );
      return localGoal;
    }
  }

  // Arac cubugu extension'i (reader_toolbar.dart) setState'e dogrudan
  // erisemedigi icin koru: protected olmayan kopru.
  void _refresh(VoidCallback fn) => setState(fn);

  void _onPageChanged(int? page) {
    if (page == null) return;
    setState(() => _currentPage = page);
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), _savePosition);
  }

  void _savePosition() {
    LocalStore.putPosition(widget.doc.id, _currentPage, dirty: true);
    AppServices.instance.api.putPosition(widget.doc.id, _currentPage)
        .then((_) => LocalStore.clearPositionDirty(widget.doc.id))
        .catchError((_) {});
    _scheduleReadingGoalNotifications();
  }

  int _remainingGoalPages() {
    final goal = _goal;
    if (goal == null) return AppConfig.readingTargetPages;
    final rawTargetPage = goal.startPage + goal.targetPages;
    final targetPage = _pageCount == null
        ? rawTargetPage
        : min(rawTargetPage, _pageCount! + 1);
    final effectivePage = max(_currentPage, goal.startPage);
    return min(goal.targetPages, max(0, targetPage - effectivePage));
  }

  String _goalText() {
    final goal = _goal;
    if (goal == null) {
      return 'Bugün hedef: ${AppConfig.readingTargetPages} sayfa';
    }
    final remaining = _remainingGoalPages();
    if (remaining <= 0) return 'Bugünün okuma hedefi tamam';
    return 'Bugün $remaining sayfa kaldı';
  }

  void _scheduleReadingGoalNotifications() {
    final goal = _goal;
    if (goal == null) return;
    Notifications.scheduleReadingGoalReminders(
      docName: widget.doc.name,
      remainingPages: _remainingGoalPages(),
    ).catchError((_) {});
  }

  Future<void> _commitStroke(
    int page,
    List<Offset> pts,
    List<double>? pressures,
    String kind,
  ) async {
    if (pts.isEmpty) return;
    final isHl = kind == 'highlight';
    final stroke = Stroke(
      page: page,
      kind: kind,
      color: isHl ? _highlightColor : _penColor,
      width: isHl ? _highlightWidth : _penWidth,
      points: pts,
      pressures: pressures,
    );
    stroke.strokeUuid =
        '${DateTime.now().microsecondsSinceEpoch}-${stroke.page}-${_strokeSeq++}';
    // Once ekrana isle (canli darbe temizlenirken ayni frame'de kalici liste
    // gorunsun; DB yazimini beklemek darbenin bir aniga kaybolmasina yol
    // aciyordu), kalicilastirma sonra.
    setState(() => (_byPage[page] ??= []).add(stroke));
    _history.add(stroke);
    await LocalStore.upsertStroke(stroke, widget.doc.id, dirty: true);
    // Then try server
    try {
      final id = await AppServices.instance.api.addStroke(widget.doc.id, stroke);
      stroke.id = id;
      await LocalStore.upsertStroke(stroke, widget.doc.id, dirty: false);
    } catch (_) {}
  }

  Future<void> _commitText(int page, Offset point, String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    final stroke = Stroke(
      page: page,
      kind: 'text',
      color: _textColor,
      width: 0,
      points: [point],
      text: clean,
      fontSize: _textFontSize,
      fontFamily: _textFontFamily,
    );
    stroke.strokeUuid =
        '${DateTime.now().microsecondsSinceEpoch}-${stroke.page}-${_strokeSeq++}';
    setState(() => (_byPage[page] ??= []).add(stroke));
    _history.add(stroke);
    await LocalStore.upsertStroke(stroke, widget.doc.id, dirty: true);
    try {
      final id = await AppServices.instance.api.addStroke(widget.doc.id, stroke);
      stroke.id = id;
      await LocalStore.upsertStroke(stroke, widget.doc.id, dirty: false);
    } catch (_) {}
  }

  void _undo() {
    if (_history.isEmpty) return;
    final s = _history.removeLast();
    setState(() => _byPage[s.page]?.remove(s));
    if (s.strokeUuid != null) {
      // Tombstone DB'ye yazilmadan syncNow dirty kayitlari okuyabilir;
      // yazim bittikten sonra tetikle.
      LocalStore.markStrokeDeleted(
        s.strokeUuid!,
      ).then((_) => SyncService.syncNow());
    } else if (s.id != null) {
      AppServices.instance.api.deleteStroke(s.id!).catchError((_) {});
    }
  }

  Future<void> _toggleBookmark() async {
    final existing = _bookmarks.where((b) => b.page == _currentPage).toList();
    if (existing.isNotEmpty) {
      final b = existing.first;
      setState(() => _bookmarks.remove(b));
      if (b.bookmarkUuid != null) {
        await LocalStore.markBookmarkDeleted(b.bookmarkUuid!);
      }
      SyncService.syncNow();
      return;
    }
    final b = Bookmark(
      bookmarkUuid: 'bm-${DateTime.now().microsecondsSinceEpoch}-${_bmSeq++}',
      docId: widget.doc.id,
      page: _currentPage,
      label: 'Sayfa $_currentPage',
    );
    setState(() => _bookmarks.add(b));
    await LocalStore.upsertBookmark(b, dirty: true);
    SyncService.syncNow();
  }

  Future<void> _openBookmarks() async {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final list = [..._bookmarks]..sort((a, b) => a.page.compareTo(b.page));
        if (list.isEmpty) {
          return const SizedBox(
            height: 120,
            child: Center(child: Text('Yer imi yok')),
          );
        }
        return ListView(
          shrinkWrap: true,
          children: list
              .map(
                (b) => ListTile(
                  leading: const Icon(Icons.bookmark),
                  title: Text(b.label),
                  subtitle: Text('Sayfa ${b.page}'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _controller.goToPage(pageNumber: b.page);
                  },
                ),
              )
              .toList(),
        );
      },
    );
  }

  Future<void> _openOutline() async {
    final doc = _controller.document;
    final outline = await doc.loadOutline();
    if (!mounted) return;
    if (outline.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('İçindekiler yok')));
      return;
    }
    final items = <(int, dynamic)>[];
    void walk(List nodes, int depth) {
      for (final n in nodes) {
        items.add((depth, n));
        if (n.children.isNotEmpty) walk(n.children, depth + 1);
      }
    }

    walk(outline, 0);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListView(
        children: items.map((e) {
          final depth = e.$1;
          final node = e.$2;
          final page = node.dest?.pageNumber;
          return ListTile(
            contentPadding: EdgeInsets.only(left: 16.0 + depth * 16, right: 16),
            title: Text(
              node.title ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: page == null
                ? null
                : () {
                    Navigator.pop(ctx);
                    _controller.goToPage(pageNumber: page);
                  },
          );
        }).toList(),
      ),
    );
  }

  Future<void> _goToPageDialog() async {
    final ctrl = TextEditingController(text: '$_currentPage');
    final n = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sayfaya git'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: _pageCount == null ? 'Sayfa' : 'Sayfa (1-$_pageCount)',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text)),
            child: const Text('Git'),
          ),
        ],
      ),
    );
    if (n == null) return;
    final total = _pageCount ?? n;
    final target = n.clamp(1, total);
    _controller.goToPage(pageNumber: target);
  }

  void _openThumbnails() {
    final doc = _controller.document;
    final count = _pageCount ?? 0;
    if (count == 0) return;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.85,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.72,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: count,
            itemBuilder: (context, i) {
              final pageNo = i + 1;
              return InkWell(
                onTap: () {
                  Navigator.pop(ctx);
                  _controller.goToPage(pageNumber: pageNo);
                },
                child: Column(
                  children: [
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: pageNo == _currentPage
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).dividerColor,
                          ),
                        ),
                        child: PdfPageView(document: doc, pageNumber: pageNo),
                      ),
                    ),
                    Text('$pageNo', style: const TextStyle(fontSize: 11)),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _openSearch() {
    setState(() {
      _mode = DrawMode.pan;
      _searching = true;
    });
  }

  void _closeSearch() {
    _textSearcher?.resetTextSearch();
    _searchCtrl.clear();
    setState(() => _searching = false);
  }

  String _fmtPomodoro(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _openPomodoroSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ValueListenableBuilder<PomodoroState>(
        valueListenable: PomodoroService.state,
        builder: (ctx, state, _) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(state.isWork ? Icons.timer : Icons.coffee),
                title: Text(state.isWork ? 'Çalışma' : 'Mola'),
                subtitle: Text(_fmtPomodoro(state.remaining)),
              ),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: state.running
                          ? PomodoroService.pause
                          : PomodoroService.start,
                      icon: Icon(
                        state.running ? Icons.pause : Icons.play_arrow,
                      ),
                      label: Text(state.running ? 'Duraklat' : 'Devam'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          PomodoroService.extend(const Duration(minutes: 5)),
                      icon: const Icon(Icons.add),
                      label: const Text('5 dk uzat'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _searchText(String value) {
    final query = value.trim();
    if (query.isEmpty) {
      _textSearcher?.resetTextSearch();
      return;
    }
    _textSearcher?.startTextSearch(query);
  }

  String _searchStatusText() {
    if (_searchCtrl.text.trim().isEmpty) return '';
    final searcher = _textSearcher;
    if (searcher == null) return 'Hazırlanıyor';
    if (searcher.isSearching) {
      final page = searcher.searchingPageNumber;
      final total = searcher.totalPageCount;
      if (page != null && total != null) return 'Aranıyor $page/$total';
      return 'Aranıyor';
    }
    final index = searcher.currentIndex;
    final count = searcher.matches.length;
    if (count == 0) return 'Sonuç yok';
    return '${(index ?? 0) + 1}/$count';
  }

  void _eraseAt(int page, Offset norm) {
    final list = _byPage[page];
    if (list == null) return;
    for (final s in List.of(list)) {
      for (final p in s.points) {
        if ((p - norm).distance < 0.02) {
          setState(() {
            list.remove(s);
            _history.remove(s);
          });
          // Silme sync push tombstone'u ile gider; dogrudan id ile silme
          // kullanilmaz (sunucu REPLACE sonrasi id degisebilir, guvenilmez).
          if (s.strokeUuid != null) {
            LocalStore.markStrokeDeleted(
              s.strokeUuid!,
            ).then((_) => SyncService.syncNow());
          } else if (s.id != null) {
            AppServices.instance.api.deleteStroke(s.id!).catchError((_) {});
          }
          return;
        }
      }
    }
  }

  Future<void> _showToolOptions(DrawMode mode) async {
    final isHighlight = mode == DrawMode.highlight;
    final palette = isHighlight ? kHighlightPalette : kPenPalette;
    final minWidth = isHighlight ? 0.010 : 0.0015;
    final maxWidth = isHighlight ? 0.050 : 0.010;
    int selectedColor = isHighlight ? _highlightColor : _penColor;
    double selectedWidth = isHighlight ? _highlightWidth : _penWidth;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final scheme = Theme.of(ctx).colorScheme;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(isHighlight ? Icons.highlight : Icons.edit),
                      const SizedBox(width: 8),
                      Text(
                        isHighlight ? 'Fosforlu' : 'Kalem',
                        style: Theme.of(ctx).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: palette.map((color) {
                      final active = color == selectedColor;
                      return InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => setSheetState(() {
                          selectedColor = color;
                          setState(() {
                            if (isHighlight) {
                              _highlightColor = color;
                            } else {
                              _penColor = color;
                            }
                          });
                        }),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            // Fosforlu renkler yari saydam: gercek gorunumuyle
                            // goster (opak zorlamak rengi yanlis tanitiyordu).
                            color: isHighlight
                                ? Color(color)
                                : Color(color | 0xFF000000),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: active ? scheme.primary : scheme.outline,
                              width: active ? 3 : 1,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Icon(
                        Icons.line_weight,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Slider(
                          value: selectedWidth.clamp(minWidth, maxWidth),
                          min: minWidth,
                          max: maxWidth,
                          divisions: isHighlight ? 20 : 17,
                          onChanged: (value) => setSheetState(() {
                            selectedWidth = value;
                            setState(() {
                              if (isHighlight) {
                                _highlightWidth = value;
                              } else {
                                _penWidth = value;
                              }
                            });
                          }),
                        ),
                      ),
                      Container(
                        width: 44,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Container(
                          width: 26,
                          height: max(2, selectedWidth * 900),
                          decoration: BoxDecoration(
                            color: Color(selectedColor),
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static const _kDeleteTextResult = '__SIL__';

  Future<void> _showTextDialog(
    int page,
    Offset point, {
    Stroke? existing,
  }) async {
    final ctrl = TextEditingController(text: existing?.text ?? '');
    var color = existing?.color ?? _textColor;
    var size = existing?.fontSize ?? _textFontSize;
    var family = existing?.fontFamily ?? _textFontFamily;
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final scheme = Theme.of(ctx).colorScheme;
          return AlertDialog(
            title: Text(existing == null ? 'Metin ekle' : 'Metni düzenle'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Not yaz...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: kPenPalette.map((c) {
                      final active = c == color;
                      return InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => setDialogState(() => color = c),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: Color(c),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: active ? scheme.primary : scheme.outline,
                              width: active ? 3 : 1,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'default',
                        icon: Icon(Icons.text_fields),
                      ),
                      ButtonSegment(value: 'serif', icon: Icon(Icons.title)),
                      ButtonSegment(value: 'mono', icon: Icon(Icons.code)),
                    ],
                    selected: {family},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) =>
                        setDialogState(() => family = v.first),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.format_size, size: 20),
                      Expanded(
                        child: Slider(
                          value: size,
                          min: 10,
                          max: 40,
                          divisions: 30,
                          onChanged: (v) => setDialogState(() => size = v),
                        ),
                      ),
                      SizedBox(
                        width: 34,
                        child: Text(
                          size.round().toString(),
                          textAlign: TextAlign.end,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              if (existing != null)
                TextButton(
                  onPressed: () => Navigator.pop(ctx, _kDeleteTextResult),
                  child: Text('Sil', style: TextStyle(color: scheme.error)),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('İptal'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text),
                child: Text(existing == null ? 'Ekle' : 'Kaydet'),
              ),
            ],
          );
        },
      ),
    );
    ctrl.dispose();
    if (text == null) return;
    if (existing != null && text == _kDeleteTextResult) {
      await _deleteTextStroke(existing);
      return;
    }
    if (text.trim().isEmpty) return;
    setState(() {
      _textColor = color;
      _textFontSize = size;
      _textFontFamily = family;
    });
    if (existing == null) {
      await _commitText(page, point, text);
    } else {
      await _applyTextEdit(existing, text.trim(), color, size, family);
    }
  }

  /// Mevcut metin isaretlemesini yeni icerik/bicimle degistirir.
  /// Ayni stroke_uuid korunur; sunucu tarafi sync push'taki
  /// INSERT OR REPLACE + LWW ile gunceller.
  Future<void> _applyTextEdit(
    Stroke s,
    String text,
    int color,
    double size,
    String family,
  ) async {
    final updated = Stroke(
      id: s.id,
      page: s.page,
      kind: 'text',
      color: color,
      width: 0,
      points: [...s.points],
      text: text,
      fontSize: size,
      fontFamily: family,
      strokeUuid: s.strokeUuid,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final list = _byPage[s.page];
    final idx = list?.indexOf(s) ?? -1;
    setState(() {
      if (idx >= 0) {
        list![idx] = updated;
      } else {
        (_byPage[s.page] ??= []).add(updated);
      }
      _annoRev++;
    });
    await LocalStore.upsertStroke(updated, widget.doc.id, dirty: true);
    SyncService.syncNow();
  }

  Future<void> _moveTextStroke(Stroke s) async {
    s.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
    s.updatedByDevice = null;
    await LocalStore.upsertStroke(s, widget.doc.id, dirty: true);
    SyncService.syncNow();
  }

  Future<void> _deleteTextStroke(Stroke s) async {
    setState(() {
      _byPage[s.page]?.remove(s);
      _history.remove(s);
      _annoRev++;
    });
    if (s.strokeUuid != null) {
      await LocalStore.markStrokeDeleted(s.strokeUuid!);
    } else if (s.id != null) {
      AppServices.instance.api.deleteStroke(s.id!).catchError((_) {});
    }
    SyncService.syncNow();
  }

  @override
  void dispose() {
    _stylusReleaseTimer?.cancel();
    _debounce?.cancel();
    _savePosition();
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _controller.removeListener(_onZoomChanged);
    _textSearcher?.removeListener(_onSearchChanged);
    PomodoroService.state.removeListener(_onPomodoroChanged);
    _textSearcher?.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveView = _effectiveViewMode(context);
    final textSearcher = _textSearcher;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        titleSpacing: 8,
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'PDF içinde ara...',
                  border: InputBorder.none,
                ),
                onChanged: _searchText,
              )
            : Text(widget.doc.name, overflow: TextOverflow.ellipsis),
        leading: _searching
            ? IconButton(
                tooltip: 'Aramayı kapat',
                onPressed: _closeSearch,
                icon: const Icon(Icons.close),
              )
            : (widget.onClose != null
                ? IconButton(
                    tooltip: 'PDF panelini kapat',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  )
                : null),
        actions: _searching
            ? [
                if (_searchStatusText().isNotEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(_searchStatusText()),
                    ),
                  ),
                IconButton(
                  tooltip: 'Önceki sonuç',
                  onPressed: textSearcher?.hasMatches == true
                      ? () => textSearcher?.goToPrevMatch()
                      : null,
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton(
                  tooltip: 'Sonraki sonuç',
                  onPressed: textSearcher?.hasMatches == true
                      ? () => textSearcher?.goToNextMatch()
                      : null,
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
              ]
            : [
                ValueListenableBuilder<PomodoroState>(
                  valueListenable: PomodoroService.state,
                  builder: (context, p, _) {
                    if (!p.running) return const SizedBox.shrink();
                    return TextButton.icon(
                      onPressed: _openPomodoroSheet,
                      icon: const Icon(Icons.timer, size: 18),
                      label: Text(_fmtPomodoro(p.remaining)),
                    );
                  },
                ),
                if (widget.onOpenVideo != null)
                  IconButton(
                    tooltip: 'Yanda video aç',
                    iconSize: 22,
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onOpenVideo,
                    icon: const Icon(Icons.ondemand_video),
                  ),
                IconButton(
                  tooltip: 'PDF içinde ara',
                  iconSize: 22,
                  visualDensity: VisualDensity.compact,
                  onPressed: _openSearch,
                  icon: const Icon(Icons.search),
                ),
                _readerMenu(),
              ],
      ),
      body: FutureBuilder<_ReaderData>(
        future: _loadFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Hata: ${snapshot.error}'));
          }
          final data = snapshot.data!;
          Widget viewer = PdfViewer.file(
            data.file.path,
            controller: _controller,
            params: PdfViewerParams(
              matchTextColor: Colors.yellow.withAlpha(110),
              activeMatchTextColor: Colors.orange.withAlpha(150),
              // Metin secmeyi kapat: cizim uygulamasinda gereksiz ve parmak/stylus
              // kaydirma jestleriyle catisiyor. Arama (highlight) bundan bagimsiz calisir.
              textSelectionParams: const PdfTextSelectionParams(enabled: false),
              // S Pen ekrandayken pdfrx'in stylus'la sayfa kaydirmasini engelle.
              panEnabled: !_stylusDown,
              // Serit takip asistani: zoom yapiliyken kaydirma, jestin baskin
              // eksenine kilitlenir (dikey cekiste x sapmaz). Zoom yokken serbest.
              panAxis: _panAxisLocked ? PanAxis.aligned : PanAxis.free,
              layoutPages: (pages, p) =>
                  buildPageLayout(pages, p.margin, effectiveView),
              // Ekrana sigan sayfa parmakla saga sola oynamasin.
              normalizeMatrix: normalizeReaderMatrix,
              onViewerReady: (document, controller) {
                _pageCount = document.pages.length;
                _onZoomChanged();
                if (_textSearcher == null) {
                  _textSearcher = PdfTextSearcher(_controller)
                    ..addListener(_onSearchChanged);
                  final query = _searchCtrl.text.trim();
                  if (query.isNotEmpty) {
                    _textSearcher!.startTextSearch(
                      query,
                      searchImmediately: true,
                    );
                  }
                }
                final target = widget.initialPage ?? data.savedPage;
                if (target != null && target > 1) {
                  controller.goToPage(pageNumber: target);
                }
                _scheduleReadingGoalNotifications();
              },
              onPageChanged: _onPageChanged,
              pagePaintCallbacks: textSearcher == null
                  ? null
                  : [textSearcher.pageTextMatchPaintCallback],
              pageOverlaysBuilder: (context, pageRect, page) {
                if (!_annotationsLoaded) return const [];
                return [
                  Positioned.fill(
                    child: _PageAnnotationLayer(
                      key: ValueKey(
                        'anno-${page.pageNumber}-${_mode.index}-${_stylusMode.index}-'
                        '${_byPage[page.pageNumber]?.length ?? 0}-$_annoRev',
                      ),
                      strokes: _byPage[page.pageNumber] ?? const [],
                      mode: _mode,
                      stylusMode: _stylusMode,
                      penColor: _penColor,
                      highlightColor: _highlightColor,
                      penWidth: _penWidth,
                      highlightWidth: _highlightWidth,
                      onStylusActive: _setStylusDown,
                      onStylusSeen: _noteStylusSeen,
                      onStylusButtonTap: _toggleStylusPenHighlight,
                      onCommit: (pts, pressures, kind) =>
                          _commitStroke(page.pageNumber, pts, pressures, kind),
                      onText: (point) =>
                          _showTextDialog(page.pageNumber, point),
                      onTextEdit: (s) => _showTextDialog(
                        page.pageNumber,
                        s.points.first,
                        existing: s,
                      ),
                      onTextMoved: _moveTextStroke,
                      onErase: (n) => _eraseAt(page.pageNumber, n),
                    ),
                  ),
                ];
              },
            ),
          );
          // Filtre degisiminde widget agacinin SEKLI sabit kalmali:
          // ColorFiltered ve karartma katmani her zaman agacta durur
          // (kapaliyken etkisiz matris / seffaf katman). Kosullu sarmalama,
          // PdfViewer'in yeniden kurulup ilk sayfaya donmesine yol aciyordu.
          final filterMatrix = switch (_nightMode) {
            'invert' => _invertMatrix,
            'sepia' => _sepiaMatrix,
            _ => _identityMatrix,
          };
          return Stack(
            children: [
              Positioned.fill(
                child: ColorFiltered(
                  colorFilter: ColorFilter.matrix(filterMatrix),
                  child: viewer,
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    color: Colors.black.withValues(
                      alpha: _nightMode == 'dim' ? _dimLevel : 0.0,
                    ),
                  ),
                ),
              ),
              // Yuzen arac dock'u: PDF uzerinde, ortalanmis, tabandan ayrik.
              if (!_searching)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: _readerToolBar(),
                ),
            ],
          );
        },
      ),
    );
  }
}
