part of 'reader_screen.dart';

extension _ReaderToolbar on _ReaderScreenState {
  Widget _toolButton(DrawMode mode, IconData icon, String tip) {
    final selected = _mode == mode;
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          if (_mode == mode &&
              (mode == DrawMode.pen || mode == DrawMode.highlight)) {
            _showToolOptions(
              mode == DrawMode.highlight ? DrawMode.highlight : DrawMode.pen,
            );
            return;
          }
          _refresh(() => _mode = mode);
        },
        child: Container(
          width: 44,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 22,
            color: selected
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _toolSeparator() {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }

  Widget _stylusButton(StylusMode mode, IconData icon, String tip) {
    final selected = _stylusMode == mode;
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          if (selected && mode != StylusMode.eraser) {
            _showToolOptions(
              mode == StylusMode.highlight ? DrawMode.highlight : DrawMode.pen,
            );
            return;
          }
          _refresh(() => _stylusMode = mode);
        },
        child: Container(
          width: 44,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? scheme.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 22,
            color: selected
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Future<void> _showShapeOptions() async {
    final picked = await showModalBottomSheet<DrawMode>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filledTonal(
                tooltip: 'Dikdörtgen',
                onPressed: () => Navigator.pop(ctx, DrawMode.rect),
                icon: const Icon(Icons.crop_square),
              ),
              const SizedBox(width: 16),
              IconButton.filledTonal(
                tooltip: 'Ok',
                onPressed: () => Navigator.pop(ctx, DrawMode.arrow),
                icon: const Icon(Icons.north_east),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      _refresh(() => _mode = picked);
    }
  }

  Widget _shapeButton() {
    final selected = _mode == DrawMode.rect || _mode == DrawMode.arrow;
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Şekiller',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _showShapeOptions,
        child: Container(
          width: 44,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            _mode == DrawMode.arrow ? Icons.north_east : Icons.category,
            size: 22,
            color: selected
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// Gunluk okuma hedefi rozeti: kalan sayfa sayisi, hedef tamamsa onay
  /// isareti. Dokununca detay metnini gosterir. Sayfa degisiminde toolbar
  /// zaten yeniden kuruldugu icin deger guncel kalir.
  Widget _readingGoalChip() {
    final scheme = Theme.of(context).colorScheme;
    final remaining = _remainingGoalPages();
    final done = _goal != null && remaining <= 0;
    return Tooltip(
      message: _goalText(),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(_goalText()),
                duration: const Duration(seconds: 2),
              ),
            );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                done ? Icons.check_circle : Icons.flag,
                size: 15,
                color: done ? Colors.green : scheme.primary,
              ),
              if (!done) ...[
                const SizedBox(width: 3),
                Text(
                  '$remaining',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Pomodoro rozeti: hedef rozetinin sagindadir. Dokununca sayaci
  /// baslatir/duraklatir, basili tutunca tam denetim sayfasini acar.
  /// Calismiyorken faz suresini, calisirken kalan sureyi gosterir.
  Widget _pomodoroChip() {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<PomodoroState>(
      valueListenable: PomodoroService.state,
      builder: (context, p, _) {
        final accent = p.isWork ? scheme.primary : Colors.teal;
        return Tooltip(
          message: p.running
              ? '${p.isWork ? 'Çalışma' : 'Mola'} · duraklat'
              : '${p.isWork ? 'Çalışma' : 'Mola'} · başlat',
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () =>
                p.running ? PomodoroService.pause() : PomodoroService.start(),
            onLongPress: _openPomodoroSheet,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    p.running
                        ? Icons.pause
                        : (p.isWork ? Icons.timer : Icons.coffee),
                    size: 15,
                    color: accent,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    _fmtPomodoro(p.remaining),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: accent,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Yuzen dock: icerige gore daralir, yatay ortalanir, tabandan hafif
  /// ayrik durur; PDF dock'un sag/sol bosluklarindan gorunur.
  Widget _readerToolBar() {
    final scheme = Theme.of(context).colorScheme;
    // S Pen arac grubu: yatay modda VEYA bu oturumda stylus gorulduyse.
    // (Eskiden yalniz yatayda gorunuyordu; tablette dikey tutunca S Pen
    // araclarina erisim kayboluyordu.)
    final showStylusTools =
        MediaQuery.of(context).orientation == Orientation.landscape ||
        StylusPresence.everSeen;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 10),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width - 16,
          ),
          child: Material(
            color: scheme.surfaceContainerLowest.withAlpha(245),
            elevation: 6,
            shadowColor: Colors.black.withAlpha(90),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: scheme.outlineVariant.withAlpha(150)),
            ),
            // Asagi kaydirinca tek tusa kuculur; yukari kaydirma veya
            // tusa dokunma geri acar.
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.center,
              child: _dockCollapsed
                  ? InkWell(
                      key: const ValueKey('dock-mini'),
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => _refresh(() => _dockCollapsed = false),
                      child: SizedBox(
                        width: 46,
                        height: 46,
                        child: Icon(
                          Icons.keyboard_arrow_up,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : _dockContent(scheme, showStylusTools),
            ),
          ),
        ),
      ),
    );
  }

  Widget _dockContent(ColorScheme scheme, bool showStylusTools) {
    return Container(
      key: const ValueKey('dock-full'),
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Sol arac grubu: dar ekranda yatay kaydirilabilir
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _toolButton(DrawMode.pan, Icons.pan_tool, 'Kaydır'),
                  _toolButton(DrawMode.pen, Icons.edit, 'Kalem'),
                  _toolButton(DrawMode.highlight, Icons.highlight, 'Fosforlu'),
                  _toolButton(
                    DrawMode.eraser,
                    Icons.cleaning_services,
                    'Silgi',
                  ),
                  _toolSeparator(),
                  if (showStylusTools) ...[
                    _stylusButton(StylusMode.pen, Icons.gesture, 'S Pen kalem'),
                    _stylusButton(
                      StylusMode.highlight,
                      Icons.border_color,
                      'S Pen fosforlu',
                    ),
                    _stylusButton(
                      StylusMode.eraser,
                      Icons.cleaning_services,
                      'S Pen silgi',
                    ),
                  ],
                  if (showStylusTools) _toolSeparator(),
                  IconButton(
                    tooltip: 'Geri al',
                    iconSize: 22,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 32,
                    ),
                    onPressed: _history.isEmpty ? null : _undo,
                    icon: const Icon(Icons.undo),
                  ),
                  _toolButton(DrawMode.text, Icons.text_fields, 'Metin'),
                  _shapeButton(),
                ],
              ),
            ),
          ),
          // Gunluk okuma hedefi rozeti
          _readingGoalChip(),
          // Pomodoro sayaci (hedef rozetinin sagi)
          _pomodoroChip(),
          // Sag sabit grup: sayfa gostergesi + kucuk resimler
          InkWell(
            onTap: _goToPageDialog,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                _pageCount == null
                    ? '$_currentPage'
                    : '$_currentPage / $_pageCount',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Küçük resimler',
            iconSize: 22,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 32),
            onPressed: _openThumbnails,
            icon: const Icon(Icons.grid_view),
          ),
        ],
      ),
    );
  }

  Widget _readerMenu() {
    return IconButton(
      tooltip: 'Daha fazla',
      icon: const Icon(Icons.more_vert),
      onPressed: _showReaderMenuSheet,
    );
  }

  Widget _sheetSectionLabel(BuildContext ctx, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: Theme.of(ctx).textTheme.labelLarge?.copyWith(
          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Future<void> _showReaderMenuSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final scheme = Theme.of(ctx).colorScheme;
          final bookmarked = _bookmarks.any((b) => b.page == _currentPage);
          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Gunluk hedef ozeti
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer.withAlpha(120),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.flag, size: 18, color: scheme.primary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _goalText(),
                              style: Theme.of(ctx).textTheme.titleSmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    _sheetSectionLabel(ctx, 'Görünüm'),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<ViewMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: ViewMode.auto,
                            icon: Icon(Icons.fit_screen),
                            tooltip: 'Otomatik',
                          ),
                          ButtonSegment(
                            value: ViewMode.single,
                            icon: Icon(Icons.crop_portrait),
                            tooltip: 'Tek sayfa',
                          ),
                          ButtonSegment(
                            value: ViewMode.twoVertical,
                            icon: Icon(Icons.view_agenda),
                            tooltip: 'Çift sayfa',
                          ),
                        ],
                        selected: {_viewMode},
                        onSelectionChanged: (s) {
                          _setViewMode(s.first);
                          setSheet(() {});
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                    _sheetSectionLabel(ctx, 'Gece filtresi'),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: 'off',
                            icon: Icon(Icons.brightness_5),
                            tooltip: 'Kapalı',
                          ),
                          ButtonSegment(
                            value: 'dim',
                            icon: Icon(Icons.brightness_4),
                            tooltip: 'Karart',
                          ),
                          ButtonSegment(
                            value: 'sepia',
                            icon: Icon(Icons.filter_vintage),
                            tooltip: 'Sepya',
                          ),
                          ButtonSegment(
                            value: 'invert',
                            icon: Icon(Icons.invert_colors),
                            tooltip: 'Negatif',
                          ),
                        ],
                        selected: {_nightMode},
                        onSelectionChanged: (s) {
                          final m = s.first;
                          _refresh(() => _nightMode = m);
                          AppConfig.setNightMode(m);
                          setSheet(() {});
                        },
                      ),
                    ),
                    // Karart yogunlugu: yalnizca karart modunda, canli onizlemeli
                    if (_nightMode == 'dim')
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Icon(
                              Icons.dark_mode,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                            Expanded(
                              child: Slider(
                                value: _dimLevel,
                                min: 0.1,
                                max: 0.7,
                                onChanged: (v) {
                                  _refresh(() => _dimLevel = v);
                                  setSheet(() {});
                                },
                                onChangeEnd: (v) => AppConfig.setDimLevel(v),
                              ),
                            ),
                            SizedBox(
                              width: 38,
                              child: Text(
                                '%${(_dimLevel * 100).round()}',
                                textAlign: TextAlign.end,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const Divider(height: 28),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      leading: Icon(
                        bookmarked ? Icons.bookmark_remove : Icons.bookmark_add,
                        color: scheme.primary,
                      ),
                      title: Text(
                        bookmarked
                            ? 'Bu sayfanın yer imini kaldır'
                            : 'Bu sayfayı yer imle',
                      ),
                      subtitle: Text('Sayfa $_currentPage'),
                      onTap: () async {
                        await _toggleBookmark();
                        setSheet(() {});
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      leading: Icon(Icons.bookmarks, color: scheme.primary),
                      title: const Text('Yer imleri'),
                      onTap: () {
                        Navigator.pop(ctx);
                        _openBookmarks();
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      leading: Icon(Icons.toc, color: scheme.primary),
                      title: const Text('İçindekiler'),
                      onTap: () {
                        Navigator.pop(ctx);
                        _openOutline();
                      },
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
