import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../ink.dart';
import '../models.dart';
import '../pen_palette.dart';

/// Not editoru (tek tuval modeli).
///
/// Tek bir buyuk not yuzeyinde hem klavyeyle zengin metin (kalın/italik/altı
/// çizili, hizalama, renk, boyut) yazilir hem de uzerine el yazisi/cizim
/// yapilir. Cizim, tum sayfayi kaplayan tek bir ink katmanindadir
/// (NoteDoc.strokes).
///
/// Cizim davranisi PDF okuyucuyla AYNIDIR (ink.dart ortak motoru):
/// - S Pen HER ZAMAN cizer (mod degistirmeye gerek yok); yaklasinca metin
///   alani kaleme gecer, kalem cekilince yazi kaldigi yerden devam eder.
/// - S Pen dugmesi/ters ucu siler; basinc duyarli murekkep, avuc reddi var.
/// - Parmakla cizmek icin alt dock'tan "Çiz" moduna gecilir.
///
/// Not sunucuda .belge JSON dosyasi; her degisiklik ~2 sn debounce ile komple
/// PUT edilir (LWW). Cikista kaydedilmemis degisiklik arkada gonderilir.
///
/// [onClose] verilirse masaüstü gömme modudur (Navigator.pop yerine paneli
/// kapatır).
class NoteEditorScreen extends StatefulWidget {
  final NoteListItem item;
  final VoidCallback? onClose;

  const NoteEditorScreen({super.key, required this.item, this.onClose});

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  NoteDoc? _doc;
  bool _loading = true;
  String? _error;
  bool _dirty = false;
  bool _saving = false;
  Timer? _saveTimer;

  // Tek metin blogu + denetleyicileri. Not metni bu blogun tek span'inde tutulur.
  NoteBlock? _textBlock;
  TextEditingController? _bodyCtrl;
  final FocusNode _bodyFocus = FocusNode();
  TextEditingController? _titleCtrl;

  // --- Kalem / cizim durumu ---
  bool _drawMode = false; // parmakla cizim modu (S Pen moddan bagimsiz cizer)
  int _penColor = 0xFF111827;
  double _penWidth = 0.005; // icerik genisliginin orani
  bool _eraser = false; // parmak silgisi (cizgi siler)
  final LiveInkStroke _live = LiveInkStroke();
  Offset? _lastAddedLocal; // nokta seyreltme referansi (px)
  double _pageW = 1; // ink katmaninin guncel genisligi (normalize bolen)
  double _pageH = 1; // ink katmaninin guncel yuksekligi (clamp icin)
  int _inkRev = 0; // kalici katman repaint tetikleyicisi

  // S Pen yakinlik durumu: kalem ekrana yaklasinca metin alani devre disi
  // kalir (kalem dokununca imlec ziplamasin), kalem cekilince geri acilir.
  bool _stylusNear = false;
  int _lastStylusSeenMs = 0;
  bool _penContact = false;
  Timer? _stylusReleaseTimer;

  @override
  void initState() {
    super.initState();
    _loadDoc();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _stylusReleaseTimer?.cancel();
    _titleCtrl?.dispose();
    _bodyCtrl?.dispose();
    _bodyFocus.dispose();
    _live.dispose();
    final doc = _doc;
    if (doc != null && _dirty) _fireSave(doc);
    super.dispose();
  }

  void _fireSave(NoteDoc doc) {
    AppServices.instance.api.saveNote(doc).then((_) {}, onError: (Object _) {});
  }

  /// Belgeyi tek metin blogu + cizim katmanina indirger. Birden cok eski metin
  /// blogu varsa metinleri bos satirla birlestirir (tek tuval modeli).
  void _normalizeDoc(NoteDoc doc) {
    final textBlocks = doc.blocks.where((b) => b.type == 'text').toList();
    if (textBlocks.isEmpty) {
      _textBlock = NoteBlock.text();
      doc.blocks
        ..clear()
        ..add(_textBlock!);
    } else if (textBlocks.length == 1) {
      _textBlock = textBlocks.first;
      doc.blocks
        ..clear()
        ..add(_textBlock!);
    } else {
      final merged = textBlocks
          .map((b) => b.text)
          .where((t) => t.isNotEmpty)
          .join('\n\n');
      _textBlock = NoteBlock.text(span: textBlocks.first.spans.first)
        ..align = textBlocks.first.align
        ..text = merged;
      doc.blocks
        ..clear()
        ..add(_textBlock!);
    }
  }

  Future<void> _loadDoc() async {
    try {
      final doc = await AppServices.instance.api.getNote(widget.item.id);
      if (!mounted) return;
      _normalizeDoc(doc);
      _titleCtrl = TextEditingController(text: doc.title);
      _bodyCtrl = TextEditingController(text: _textBlock!.text);
      setState(() {
        _doc = doc;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _reload() async {
    try {
      final doc = await AppServices.instance.api.getNote(widget.item.id);
      if (!mounted) return;
      _normalizeDoc(doc);
      _titleCtrl?.value = TextEditingValue(text: doc.title);
      _bodyCtrl?.value = TextEditingValue(text: _textBlock!.text);
      setState(() {
        _doc = doc;
        _dirty = false;
        _saving = false;
        _inkRev++;
      });
    } catch (e) {
      if (!mounted) return;
      _showSnack('Yenileme hatası: $e');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _markDirty() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _doSave);
  }

  Future<void> _doSave() async {
    final doc = _doc;
    if (doc == null || !_dirty) return;
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final res = await AppServices.instance.api.saveNote(doc);
      if (!mounted) return;
      if (res.conflict) {
        _showSnack('Not başka cihazda güncellendi; sunucu sürümü yenileniyor');
        await _reload();
      } else {
        if (res.updatedAtMs != null) doc.updatedAtMs = res.updatedAtMs!;
        setState(() {
          _dirty = false;
          _saving = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _showSnack('Kaydetme hatası: $e');
    }
  }

  // --- Metin bicim islemleri (tum nota uygulanir) ---
  void _applyToSpan(void Function(TextSpanModel s) fn) {
    final b = _textBlock;
    if (b == null || b.spans.isEmpty) return;
    setState(() => fn(b.spans.first));
    _markDirty();
    if (!_drawMode) _bodyFocus.requestFocus();
  }

  void _setAlign(NoteAlign a) {
    final b = _textBlock;
    if (b == null) return;
    setState(() => b.align = a);
    _markDirty();
    if (!_drawMode) _bodyFocus.requestFocus();
  }

  // --- S Pen yakinlik yonetimi (ReaderScreen ile ayni desen) ---
  void _noteStylusSeen() {
    StylusPresence.markSeen();
    _lastStylusSeenMs = DateTime.now().millisecondsSinceEpoch;
    if (!_stylusNear) setState(() => _stylusNear = true);
    _armStylusRelease();
  }

  void _armStylusRelease() {
    _stylusReleaseTimer ??= Timer(const Duration(milliseconds: 750), () {
      _stylusReleaseTimer = null;
      if (!mounted) return;
      final idleMs = DateTime.now().millisecondsSinceEpoch - _lastStylusSeenMs;
      if (!_penContact && idleMs >= 700) {
        if (_stylusNear) setState(() => _stylusNear = false);
      } else if (_stylusNear) {
        _armStylusRelease();
      }
    });
  }

  // --- Cizim ---
  // Noktayi GENISLIGE normalize eder ve KUTU ICINE kistirir: cizgi not
  // kutusunun disina tasmaz. (y de width ile bolunur; veri bicimi boyle.)
  Offset _normP(Offset local) => Offset(
    (local.dx / _pageW).clamp(0.0, 1.0),
    (local.dy / _pageW).clamp(0.0, _pageH / _pageW),
  );

  void _startStroke(Offset local, double? pressure) {
    _lastAddedLocal = local;
    _live.start(_normP(local), pressure, 'pen', _penColor, _penWidth);
  }

  void _extendStroke(Offset local, double? pressure) {
    if (!_live.active) return;
    final last = _lastAddedLocal;
    if (last != null && (local - last).distance < kMinInkPointDistPx) return;
    _lastAddedLocal = local;
    _live.add(_normP(local), pressure);
  }

  void _endStroke() {
    final pts = _live.points;
    final doc = _doc;
    if (doc != null && pts != null && pts.isNotEmpty) {
      final stroke = InkStroke(
        color: _live.color,
        width: _live.widthFrac,
        points: List.of(pts),
        pressures: _live.commitPressures(),
      );
      // Ayni frame'de kalici katmana gecir (titreme olmasin), sonra kaydet.
      setState(() {
        doc.strokes.add(stroke);
        _inkRev++;
      });
      _markDirty();
    }
    _lastAddedLocal = null;
    _live.clear();
  }

  void _cancelStroke() {
    _lastAddedLocal = null;
    _live.clear();
  }

  void _eraseAt(Offset local) {
    final doc = _doc;
    if (doc == null || doc.strokes.isEmpty) return;
    final p = _normP(local);
    final thr = _penWidth * 2.5 < 0.02 ? 0.02 : _penWidth * 2.5;
    final before = doc.strokes.length;
    doc.strokes.removeWhere(
      (s) => s.points.any((q) => (q - p).distance <= thr),
    );
    if (doc.strokes.length != before) {
      setState(() => _inkRev++);
      _markDirty();
    }
  }

  void _undoStroke() {
    final doc = _doc;
    if (doc == null || doc.strokes.isEmpty) return;
    setState(() {
      doc.strokes.removeLast();
      _inkRev++;
    });
    _markDirty();
  }

  Future<void> _clearStrokes() async {
    final doc = _doc;
    if (doc == null || doc.strokes.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Çizimi temizle'),
        content: const Text('Bu nottaki tüm çizimler silinecek. Emin misiniz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Temizle'),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        doc.strokes.clear();
        _inkRev++;
      });
      _markDirty();
    }
  }

  void _toggleDrawMode() {
    setState(() {
      _drawMode = !_drawMode;
      if (_drawMode) {
        _bodyFocus.unfocus();
      } else {
        _eraser = false;
      }
    });
  }

  Future<void> _deleteNote() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Notu sil'),
        content: Text('"${widget.item.displayName}" silinecek. Geri alınamaz.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AppServices.instance.api.deleteNote(widget.item.id);
      if (!mounted) return;
      _close();
    } catch (e) {
      _showSnack('Silme hatası: $e');
    }
  }

  void _close() {
    if (_dirty && _doc != null) {
      _fireSave(_doc!);
      _dirty = false;
    }
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        leading: IconButton(
          tooltip: widget.onClose != null ? 'Kapat' : 'Geri',
          onPressed: _close,
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(
          widget.item.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          _saveStatusChip(scheme),
          PopupMenuButton<String>(
            tooltip: 'Diğer',
            onSelected: (v) {
              if (v == 'delete') _deleteNote();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'delete', child: Text('Notu sil')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Not yüklenemedi: $_error'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _reload,
                    child: const Text('Yeniden dene'),
                  ),
                ],
              ),
            )
          : _buildEditor(context, scheme),
    );
  }

  /// Kayit durumu: kaydediliyor (spinner) / kaydedilmedi (bulut) / sessiz.
  Widget _saveStatusChip(ColorScheme scheme) {
    if (_saving) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_dirty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Center(
          child: Tooltip(
            message: 'Kaydedilmedi',
            child: Icon(
              Icons.cloud_upload_outlined,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildEditor(BuildContext context, ColorScheme scheme) {
    final doc = _doc!;
    return Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: TextField(
                controller: _titleCtrl,
                enabled: !_drawMode && !_stylusNear,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  hintText: 'Başlık',
                  hintStyle: TextStyle(color: scheme.outline),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                onChanged: (v) {
                  doc.title = v;
                  _markDirty();
                },
              ),
            ),
            // Metin bicim cubugu yalnizca yazi modunda; cizim araclari alttaki
            // yuzen dock'ta (PDF okuyucuyla ayni dil).
            if (!_drawMode) _buildTextFormatBar(context, scheme),
            const Divider(height: 1),
            Expanded(child: _buildCanvas(doc, scheme)),
          ],
        ),
        // Yuzen arac dock'u: tabanda ortalanmis, okuyucudakiyle ayni gorunum.
        Align(alignment: Alignment.bottomCenter, child: _buildDock(scheme)),
      ],
    );
  }

  Widget _buildCanvas(NoteDoc doc, ColorScheme scheme) {
    final span = _textBlock!.spans.first;
    // ClipRect: ink katmani not kutusu disina tasmasin. LayoutBuilder ile
    // guncel kutu boyutunu kaydet (clamp/normalize).
    return ClipRect(
      child: LayoutBuilder(
        builder: (ctx, c) {
          _pageW = c.maxWidth > 0 ? c.maxWidth : 1;
          _pageH = c.maxHeight > 0 ? c.maxHeight : 1;
          return Stack(
            children: [
              // Taban: tüm alanı dolduran metin editörü. S Pen yakinken devre
              // disi: kalem dokununca imlec/klavye tetiklenmez, kalem yazar.
              Positioned.fill(
                child: Padding(
                  // Altta dock'a yer birak.
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 68),
                  child: TextField(
                    controller: _bodyCtrl,
                    focusNode: _bodyFocus,
                    enabled: !_drawMode && !_stylusNear,
                    style: _spanStyle(span),
                    textAlign: _alignToTextAlign(_textBlock!.align),
                    textAlignVertical: TextAlignVertical.top,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(
                      hintText: 'Not yaz… (S Pen ile doğrudan çizebilirsin)',
                      hintStyle: TextStyle(color: scheme.outline),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (v) {
                      _textBlock!.text = v;
                      _markDirty();
                    },
                  ),
                ),
              ),
              // Üst: tüm sayfayı kaplayan ink katmanı.
              Positioned.fill(child: _buildInkLayer(doc)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildInkLayer(NoteDoc doc) {
    // Kalici darbeler ile canli darbe ayri katmanlarda (okuyucuyla ayni):
    // cizim sirasinda yalnizca canli katman boyanir.
    final painter = Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            isComplex: true,
            painter: _NoteInkPainter(strokes: doc.strokes, rev: _inkRev),
          ),
        ),
        RepaintBoundary(
          child: CustomPaint(painter: _NoteLiveInkPainter(_live)),
        ),
      ],
    );

    // Parmak davranisi: yalnizca Çiz modunda cizer/siler (avuc reddi ile);
    // mod kapaliyken dokunuslar metne gecer.
    Widget fingerChild;
    if (!_drawMode) {
      fingerChild = IgnorePointer(child: painter);
    } else {
      fingerChild = GestureDetector(
        behavior: HitTestBehavior.opaque,
        supportedDevices: const {PointerDeviceKind.touch},
        onPanStart: (d) {
          if (StylusPresence.recentlySeen) return;
          if (_eraser) {
            _eraseAt(d.localPosition);
          } else {
            _startStroke(d.localPosition, null);
          }
        },
        onPanUpdate: (d) {
          if (_eraser) {
            if (StylusPresence.recentlySeen) return;
            _eraseAt(d.localPosition);
          } else {
            _extendStroke(d.localPosition, null);
          }
        },
        onPanEnd: (_) {
          if (!_eraser) _endStroke();
        },
        onPanCancel: _cancelStroke,
        child: painter,
      );
    }

    // S Pen: moddan bagimsiz her zaman cizer (translucent Listener; dokunusu
    // tuketmez, metin alani _stylusNear ile zaten devre disi kalir).
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerHover: (e) {
        if (isStylusEvent(e)) _noteStylusSeen();
      },
      onPointerDown: (e) {
        if (!isStylusEvent(e)) return;
        _penContact = true;
        _noteStylusSeen();
        if (_stylusErases(e)) {
          if (_live.active) _cancelStroke();
          _eraseAt(e.localPosition);
        } else {
          _startStroke(e.localPosition, normalizedPressure(e));
        }
      },
      onPointerMove: (e) {
        if (!isStylusEvent(e)) return;
        _noteStylusSeen();
        if (_stylusErases(e)) {
          if (_live.active) _cancelStroke();
          _eraseAt(e.localPosition);
        } else {
          _extendStroke(e.localPosition, normalizedPressure(e));
        }
      },
      onPointerUp: (e) {
        if (!isStylusEvent(e)) return;
        _penContact = false;
        _noteStylusSeen();
        if (!_stylusErases(e)) _endStroke();
      },
      onPointerCancel: (e) {
        if (!isStylusEvent(e)) return;
        _penContact = false;
        _noteStylusSeen();
        _cancelStroke();
      },
      child: fingerChild,
    );
  }

  bool _stylusErases(PointerEvent e) =>
      e.kind == PointerDeviceKind.invertedStylus ||
      hasStylusButton(e) ||
      (_drawMode && _eraser);

  // --- Metin bicim cubugu (yalniz yazi modunda gorunur) ---
  Widget _buildTextFormatBar(BuildContext context, ColorScheme scheme) {
    final span = _textBlock?.spans.first;
    final b = _textBlock;
    final enabled = span != null && !_stylusNear;

    Widget toggleBtn({
      required bool active,
      required IconData icon,
      required String tip,
      required VoidCallback? onPressed,
    }) {
      return IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 20),
        style: active
            ? IconButton.styleFrom(
                backgroundColor: scheme.primaryContainer,
                foregroundColor: scheme.onPrimaryContainer,
              )
            : null,
        onPressed: onPressed,
      );
    }

    return SizedBox(
      height: 42,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            toggleBtn(
              icon: Icons.format_bold,
              tip: 'Kalın',
              active: span?.bold ?? false,
              onPressed:
                  enabled ? () => _applyToSpan((s) => s.bold = !s.bold) : null,
            ),
            toggleBtn(
              icon: Icons.format_italic,
              tip: 'İtalik',
              active: span?.italic ?? false,
              onPressed: enabled
                  ? () => _applyToSpan((s) => s.italic = !s.italic)
                  : null,
            ),
            toggleBtn(
              icon: Icons.format_underlined,
              tip: 'Altı çizili',
              active: span?.underline ?? false,
              onPressed: enabled
                  ? () => _applyToSpan((s) => s.underline = !s.underline)
                  : null,
            ),
            const SizedBox(width: 4),
            _barSeparator(scheme),
            const SizedBox(width: 4),
            toggleBtn(
              icon: Icons.format_align_left,
              tip: 'Sola',
              active: b?.align == NoteAlign.left,
              onPressed: enabled ? () => _setAlign(NoteAlign.left) : null,
            ),
            toggleBtn(
              icon: Icons.format_align_center,
              tip: 'Ortaya',
              active: b?.align == NoteAlign.center,
              onPressed: enabled ? () => _setAlign(NoteAlign.center) : null,
            ),
            toggleBtn(
              icon: Icons.format_align_right,
              tip: 'Sağa',
              active: b?.align == NoteAlign.right,
              onPressed: enabled ? () => _setAlign(NoteAlign.right) : null,
            ),
            const SizedBox(width: 4),
            _barSeparator(scheme),
            IconButton(
              tooltip: 'Metin rengi',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.format_color_text,
                size: 20,
                color: span != null ? Color(span.color) : null,
              ),
              onPressed: enabled ? () => _pickTextColor(span.color) : null,
            ),
            IconButton(
              tooltip: 'Küçült',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.text_decrease, size: 20),
              onPressed: enabled
                  ? () => _applyToSpan(
                      (s) => s.size = (s.size - 2).clamp(12.0, 48.0),
                    )
                  : null,
            ),
            SizedBox(
              width: 26,
              child: Center(
                child: Text(
                  span != null ? span.size.round().toString() : '-',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Büyüt',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.text_increase, size: 20),
              onPressed: enabled
                  ? () => _applyToSpan(
                      (s) => s.size = (s.size + 2).clamp(12.0, 48.0),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _barSeparator(ColorScheme scheme) => Container(
    width: 1,
    height: 22,
    margin: const EdgeInsets.symmetric(horizontal: 2),
    color: scheme.outlineVariant,
  );

  // --- Yuzen cizim dock'u (okuyucunun dock'uyla ayni gorsel dil) ---
  Widget _buildDock(ColorScheme scheme) {
    Widget dockBtn({
      required bool active,
      required IconData icon,
      required String tip,
      required VoidCallback? onTap,
      Color? activeColor,
    }) {
      return Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            width: 44,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active
                  ? (activeColor ?? scheme.primaryContainer)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              size: 22,
              color: active
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: scheme.surfaceContainerLowest.withAlpha(245),
        elevation: 6,
        shadowColor: Colors.black.withAlpha(90),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: scheme.outlineVariant.withAlpha(150)),
        ),
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              dockBtn(
                icon: Icons.draw,
                tip: _drawMode ? 'Yazıya dön' : 'Parmakla çiz',
                active: _drawMode,
                onTap: _toggleDrawMode,
              ),
              if (_drawMode) ...[
                _barSeparator(scheme),
                dockBtn(
                  icon: Icons.edit,
                  tip: 'Kalem',
                  active: !_eraser,
                  onTap: () {
                    if (!_eraser) {
                      _showPenOptions(); // aktifken tekrar dokun: secenekler
                    } else {
                      setState(() => _eraser = false);
                    }
                  },
                ),
                dockBtn(
                  icon: Icons.cleaning_services,
                  tip: 'Silgi',
                  active: _eraser,
                  onTap: () => setState(() => _eraser = true),
                ),
              ],
              _barSeparator(scheme),
              // Kalem rengi/kalinligi: her zaman erisilir (S Pen moddan
              // bagimsiz cizdigi icin).
              Tooltip(
                message: 'Kalem rengi ve kalınlığı',
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _showPenOptions,
                  child: Container(
                    width: 44,
                    height: 32,
                    alignment: Alignment.center,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: Color(_penColor),
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.outline),
                      ),
                    ),
                  ),
                ),
              ),
              dockBtn(
                icon: Icons.undo,
                tip: 'Çizimi geri al',
                active: false,
                onTap: (_doc?.strokes.isEmpty ?? true) ? null : _undoStroke,
              ),
              dockBtn(
                icon: Icons.layers_clear,
                tip: 'Çizimi temizle',
                active: false,
                onTap: (_doc?.strokes.isEmpty ?? true) ? null : _clearStrokes,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Kalem secenekleri: renk paleti + kalinlik, aninda uygulanir
  /// (okuyucudaki kalem secenekleri sayfasiyla ayni etkilesim).
  Future<void> _showPenOptions() async {
    const minWidth = 0.002;
    const maxWidth = 0.012;
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
                      const Icon(Icons.edit),
                      const SizedBox(width: 8),
                      Text('Kalem', style: Theme.of(ctx).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: kPenPalette.map((color) {
                      final active = color == _penColor;
                      return InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => setSheetState(() {
                          setState(() {
                            _penColor = color;
                            _eraser = false;
                          });
                        }),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: Color(color),
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
                          value: _penWidth.clamp(minWidth, maxWidth),
                          min: minWidth,
                          max: maxWidth,
                          divisions: 20,
                          onChanged: (value) => setSheetState(() {
                            setState(() => _penWidth = value);
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
                          height: (_penWidth * 900).clamp(2.0, 26.0),
                          decoration: BoxDecoration(
                            color: Color(_penColor),
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

  Future<void> _pickTextColor(int currentColor) async {
    final picked = await _showColorDialog(currentColor);
    if (picked != null) _applyToSpan((s) => s.color = picked);
  }

  Future<int?> _showColorDialog(int current) async {
    int picked = current;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('Renk seç'),
          content: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: kPenPalette.map((c) {
              final active = c == picked;
              return InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => setSt(() => picked = c),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: active
                          ? Theme.of(ctx).colorScheme.primary
                          : Theme.of(ctx).colorScheme.outline,
                      width: active ? 3 : 1,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('İptal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Tamam'),
            ),
          ],
        ),
      ),
    );
    return ok == true ? picked : null;
  }
}

// --- Yardimcilar ---

TextStyle _spanStyle(TextSpanModel s) => TextStyle(
  fontSize: s.size,
  fontWeight: s.bold ? FontWeight.bold : FontWeight.normal,
  fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
  decoration: s.underline ? TextDecoration.underline : TextDecoration.none,
  color: Color(s.color),
);

TextAlign _alignToTextAlign(NoteAlign a) {
  switch (a) {
    case NoteAlign.center:
      return TextAlign.center;
    case NoteAlign.right:
      return TextAlign.right;
    case NoteAlign.left:
      return TextAlign.left;
  }
}

/// Kalici not cizimlerini boyar. Noktalar HER IKI EKSENDE icerik GENISLIGINE
/// olceklenir (y de width ile); murekkep perfect_freehand ile basinc duyarli
/// dolgulu dis cizgidir (PDF okuyucu ile ayni gorunum).
class _NoteInkPainter extends CustomPainter {
  final List<InkStroke> strokes;
  final int rev;

  _NoteInkPainter({required this.strokes, required this.rev});

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      if (s.points.isEmpty) continue;
      canvas.drawPath(
        cachedPenPath(
          s,
          size,
          normPoints: s.points,
          pressures: s.pressures,
          widthFrac: s.width,
          yScale: size.width,
        ),
        Paint()
          ..style = PaintingStyle.fill
          ..isAntiAlias = true
          ..color = Color(s.color),
      );
    }
  }

  @override
  bool shouldRepaint(_NoteInkPainter old) =>
      old.strokes != strokes || old.rev != rev;
}

/// Yalnizca canli (cizilmekte olan) darbeyi boyar; LiveInkStroke her yeni
/// noktada notifyListeners ile tetikler, widget rebuild olmaz.
class _NoteLiveInkPainter extends CustomPainter {
  final LiveInkStroke live;

  _NoteLiveInkPainter(this.live) : super(repaint: live);

  @override
  void paint(Canvas canvas, Size size) {
    final pts = live.points;
    if (pts == null || pts.isEmpty) return;
    final ptsPx = [
      for (final p in pts) Offset(p.dx * size.width, p.dy * size.width),
    ];
    canvas.drawPath(
      penOutlinePath(
        ptsPx,
        live.livePressures(),
        live.widthFrac * size.width,
        complete: false,
      ),
      Paint()
        ..style = PaintingStyle.fill
        ..isAntiAlias = true
        ..color = Color(live.color),
    );
  }

  @override
  bool shouldRepaint(_NoteLiveInkPainter old) => old.live != live;
}
