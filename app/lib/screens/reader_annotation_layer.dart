part of 'reader_screen.dart';

/// Metin isaretlemesinin sayfa uzerindeki kapladigi alan.
/// Painter'daki cizimle ayni TextPainter parametrelerini kullanir;
/// hem cizim hem dokunma testi bu tek kaynaktan beslenir.
Rect textStrokeRect(Stroke s, Size size) {
  final family = switch (s.fontFamily) {
    'serif' => 'serif',
    'mono' => 'monospace',
    _ => null,
  };
  final tp = TextPainter(
    text: TextSpan(
      text: s.text?.trim() ?? '',
      style: TextStyle(
        fontSize: s.fontSize ?? 18,
        fontFamily: family,
        height: 1.15,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 8,
  )..layout(maxWidth: size.width * 0.55);
  final topLeft = Offset(
    s.points.first.dx * size.width,
    s.points.first.dy * size.height,
  );
  final rect = topLeft & tp.size;
  tp.dispose();
  return rect;
}

class _PageAnnotationLayer extends StatefulWidget {
  final List<Stroke> strokes;
  final DrawMode mode;
  final StylusMode stylusMode;
  final int penColor;
  final int highlightColor;
  final double penWidth;
  final double highlightWidth;
  final void Function(bool active) onStylusActive;
  // Stylus temas etmese de gorulunce (hover/hareket) cagrilir: ReaderScreen
  // pdfrx pan'ini onceden kapatir ve bosta-kalma sayacini tazeler.
  final VoidCallback onStylusSeen;
  final VoidCallback onStylusButtonTap;
  final void Function(
    List<Offset> normalizedPoints,
    List<double>? pressures,
    String kind,
  ) onCommit;
  final void Function(Offset normalizedPoint) onText;
  final void Function(Stroke stroke) onTextEdit;
  final void Function(Stroke stroke) onTextMoved;
  final void Function(Offset normalizedPoint) onErase;

  const _PageAnnotationLayer({
    super.key,
    required this.strokes,
    required this.mode,
    required this.stylusMode,
    required this.penColor,
    required this.highlightColor,
    required this.penWidth,
    required this.highlightWidth,
    required this.onStylusActive,
    required this.onStylusSeen,
    required this.onStylusButtonTap,
    required this.onCommit,
    required this.onText,
    required this.onTextEdit,
    required this.onTextMoved,
    required this.onErase,
  });

  @override
  State<_PageAnnotationLayer> createState() => _PageAnnotationLayerState();
}

class _PageAnnotationLayerState extends State<_PageAnnotationLayer> {
  final LiveInkStroke _live = LiveInkStroke();
  Size _size = Size.zero;
  bool _stylusButtonHoverDown = false;
  bool _buttonEpisodeHadContact = false;
  int _lastStylusUpMs = 0;
  Offset? _lastAddedLocal; // nokta seyreltme referansi (px)
  // Metin araci: secim + tasima durumu
  Stroke? _selectedText;
  Offset? _grabOffset; // parmak ile metin ankrajı arasi fark (normalize)
  bool _movedDuringDrag = false;
  int _paintTick = 0; // tasima sirasinda repaint tetikleyici

  Offset _norm(Offset local) => Offset(
    (local.dx / _size.width).clamp(0.0, 1.0),
    (local.dy / _size.height).clamp(0.0, 1.0),
  );

  bool _stylusErases(PointerEvent e) =>
      e.kind == PointerDeviceKind.invertedStylus ||
      hasStylusButton(e) ||
      widget.stylusMode == StylusMode.eraser;

  String _stylusKind() =>
      widget.stylusMode == StylusMode.highlight ? 'highlight' : 'pen';

  /// Stylus gorulduginde cagrilir: avuc reddi zamani guncellenir ve ReaderScreen
  /// pdfrx'in stylus'la sayfa kaydirmasini ONCEDEN kapatir (hover aninda;
  /// boylece darbe basladiginda parent rebuild'i ilk noktalari takoslamaz).
  /// Pan'i geri acma karari ReaderScreen'dedir (bu katman her commit'te
  /// yeniden kurulur, kalici zamanlayici tutamaz).
  void _markStylusSeen() {
    StylusPresence.markSeen();
    widget.onStylusSeen();
  }

  void _startDraw(Offset local, String kind, double? pressure) {
    final isHl = kind == 'highlight';
    _lastAddedLocal = local;
    _live.start(
      _norm(local),
      pressure,
      kind,
      isHl ? widget.highlightColor : widget.penColor,
      isHl ? widget.highlightWidth : widget.penWidth,
    );
  }

  void _updateDraw(Offset local, double? pressure) {
    if (!_live.active) return;
    if (_live.kind == 'pen') {
      final last = _lastAddedLocal;
      if (last != null && (local - last).distance < kMinInkPointDistPx) return;
      _lastAddedLocal = local;
    }
    _live.add(_norm(local), pressure);
  }

  void _endDraw() {
    final pts = _live.points;
    if (pts != null && pts.isNotEmpty) {
      // onCommit senkron olarak parent setState calistirir (kalici liste ayni
      // frame'de gorunur), canli darbe hemen ardindan temizlenir -> titreme yok.
      widget.onCommit(
        List<Offset>.from(pts),
        _live.commitPressures(),
        _live.kind,
      );
    }
    _lastAddedLocal = null;
    _live.clear();
  }

  void _cancelDraw() {
    _lastAddedLocal = null;
    _live.clear();
  }

  Stroke? _hitText(Offset local) {
    // Ustte cizilen (listede sonraki) once yakalansin
    for (final s in widget.strokes.reversed) {
      if (s.kind != 'text' || s.deletedAtMs != null) continue;
      if (s.text == null || s.text!.trim().isEmpty || s.points.isEmpty) {
        continue;
      }
      if (textStrokeRect(s, _size).inflate(8).contains(local)) return s;
    }
    return null;
  }

  void _onTextTap(Offset local) {
    final hit = _hitText(local);
    if (hit == null) {
      if (_selectedText != null) {
        setState(() => _selectedText = null); // bos yere dokun: secimi birak
      } else {
        widget.onText(_norm(local)); // yeni metin ekle
      }
    } else if (identical(hit, _selectedText)) {
      widget.onTextEdit(hit); // secili metne ikinci dokunus: duzenle
    } else {
      setState(() => _selectedText = hit); // sec
    }
  }

  void _onTextPanStart(Offset local) {
    final sel = _selectedText;
    if (sel == null || sel.points.isEmpty) return;
    if (!textStrokeRect(sel, _size).inflate(12).contains(local)) return;
    _grabOffset = _norm(local) - sel.points.first;
    _movedDuringDrag = false;
  }

  void _onTextPanUpdate(Offset local) {
    final sel = _selectedText;
    final grab = _grabOffset;
    if (sel == null || grab == null) return;
    final p = _norm(local) - grab;
    sel.points[0] = Offset(p.dx.clamp(0.0, 0.97), p.dy.clamp(0.0, 0.97));
    _movedDuringDrag = true;
    setState(() => _paintTick++);
  }

  void _onTextPanEnd() {
    final sel = _selectedText;
    if (sel != null && _grabOffset != null && _movedDuringDrag) {
      widget.onTextMoved(sel);
    }
    _grabOffset = null;
  }

  @override
  void dispose() {
    _live.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = Size(constraints.maxWidth, constraints.maxHeight);
        // Kalici darbeler ile canli darbe ayri katmanlarda: cizim sirasinda
        // yalnizca canli katman boyanir, sayfadaki mevcut isaretlemeler
        // yeniden boyanmaz (RepaintBoundary).
        final painter = Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                size: _size,
                isComplex: true,
                painter: _StrokePainter(
                  committed: widget.strokes,
                  selected: widget.mode == DrawMode.text ? _selectedText : null,
                  selectionColor:
                      Theme.of(context).colorScheme.primary.toARGB32(),
                  tick: _paintTick,
                ),
              ),
            ),
            RepaintBoundary(
              child: CustomPaint(size: _size, painter: _LiveInkPainter(_live)),
            ),
          ],
        );

        // PARMAK davranisi: alt bardaki moda gore. Avuc reddi: S Pen yakinken
        // parmak jestleri cizim/silme/metin islemi yapmaz.
        Widget fingerChild;
        switch (widget.mode) {
          case DrawMode.pan:
            fingerChild = IgnorePointer(child: painter);
          case DrawMode.eraser:
            fingerChild = GestureDetector(
              behavior: HitTestBehavior.opaque,
              supportedDevices: const {PointerDeviceKind.touch},
              onPanStart: (d) {
                if (StylusPresence.recentlySeen) return;
                widget.onErase(_norm(d.localPosition));
              },
              onPanUpdate: (d) {
                if (StylusPresence.recentlySeen) return;
                widget.onErase(_norm(d.localPosition));
              },
              child: painter,
            );
          case DrawMode.text:
            fingerChild = GestureDetector(
              behavior: HitTestBehavior.opaque,
              supportedDevices: const {PointerDeviceKind.touch},
              onTapUp: (d) {
                if (StylusPresence.recentlySeen) return;
                _onTextTap(d.localPosition);
              },
              onPanStart: (d) {
                if (StylusPresence.recentlySeen) return;
                _onTextPanStart(d.localPosition);
              },
              onPanUpdate: (d) {
                if (StylusPresence.recentlySeen) return;
                _onTextPanUpdate(d.localPosition);
              },
              onPanEnd: (_) => _onTextPanEnd(),
              child: painter,
            );
          case DrawMode.pen:
          case DrawMode.highlight:
          case DrawMode.rect:
          case DrawMode.arrow:
            final kind = switch (widget.mode) {
              DrawMode.highlight => 'highlight',
              DrawMode.rect => 'rect',
              DrawMode.arrow => 'arrow',
              _ => 'pen',
            };
            fingerChild = GestureDetector(
              behavior: HitTestBehavior.opaque,
              supportedDevices: const {PointerDeviceKind.touch},
              onPanStart: (d) {
                if (StylusPresence.recentlySeen) return;
                _startDraw(d.localPosition, kind, null);
              },
              onPanUpdate: (d) {
                if (!_live.active) return;
                _updateDraw(d.localPosition, null);
              },
              onPanEnd: (_) => _endDraw(),
              onPanCancel: _cancelDraw,
              child: painter,
            );
        }

        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerHover: (e) {
            if (!isStylusEvent(e)) return;
            _markStylusSeen();
            final pressed = hasStylusButton(e);
            if (!_stylusButtonHoverDown && pressed) {
              _stylusButtonHoverDown = true;
              _buttonEpisodeHadContact = false;
              return;
            }
            if (_stylusButtonHoverDown && !pressed) {
              final now = DateTime.now().millisecondsSinceEpoch;
              if (now - _lastStylusUpMs < 300) return;
              _stylusButtonHoverDown = false;
              if (!_buttonEpisodeHadContact) {
                widget.onStylusButtonTap();
              }
            }
          },
          onPointerDown: (e) {
            if (!isStylusEvent(e)) return;
            _markStylusSeen();
            widget.onStylusActive(true);
            if (hasStylusButton(e)) {
              _buttonEpisodeHadContact = true;
              _stylusButtonHoverDown = true;
            }
            if (_stylusErases(e)) {
              if (_live.active) _cancelDraw();
              widget.onErase(_norm(e.localPosition));
            } else {
              _startDraw(e.localPosition, _stylusKind(), normalizedPressure(e));
            }
          },
          onPointerMove: (e) {
            if (!isStylusEvent(e)) return;
            _markStylusSeen();
            if (_stylusErases(e)) {
              if (_live.active) _cancelDraw();
              widget.onErase(_norm(e.localPosition));
            } else {
              _updateDraw(e.localPosition, normalizedPressure(e));
            }
          },
          onPointerUp: (e) {
            if (!isStylusEvent(e)) return;
            _lastStylusUpMs = DateTime.now().millisecondsSinceEpoch;
            // Once temas bayragini birak, sonra commit et (commit parent'i
            // rebuild eder ve bu state yeni key ile atilir).
            widget.onStylusActive(false);
            _markStylusSeen();
            if (!_stylusErases(e)) _endDraw();
          },
          onPointerCancel: (e) {
            if (!isStylusEvent(e)) return;
            _lastStylusUpMs = DateTime.now().millisecondsSinceEpoch;
            widget.onStylusActive(false);
            _markStylusSeen();
            _cancelDraw();
          },
          child: fingerChild,
        );
      },
    );
  }
}

/// Yalnizca canli (cizilmekte olan) darbeyi boyar; LiveInkStroke her yeni
/// noktada notifyListeners ile bu painter'i tetikler, widget rebuild olmaz.
class _LiveInkPainter extends CustomPainter {
  final LiveInkStroke live;

  _LiveInkPainter(this.live) : super(repaint: live);

  @override
  void paint(Canvas canvas, Size size) {
    final pts = live.points;
    if (pts == null || pts.isEmpty) return;
    final ptsPx = [
      for (final p in pts) Offset(p.dx * size.width, p.dy * size.height),
    ];
    if (live.kind == 'pen') {
      final path = penOutlinePath(
        ptsPx,
        live.livePressures(),
        live.widthFrac * size.width,
        complete: false,
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.fill
          ..isAntiAlias = true
          ..color = Color(live.color),
      );
      return;
    }
    // highlight/rect/arrow onizlemesi: kalici cizimle ayni gorunum.
    drawSimpleStroke(
      canvas,
      ptsPx,
      live.kind,
      Color(live.color),
      live.widthFrac * size.width,
    );
  }

  @override
  bool shouldRepaint(_LiveInkPainter old) => old.live != live;
}

class _StrokePainter extends CustomPainter {
  final List<Stroke> committed;
  final Stroke? selected;
  final int selectionColor;
  final int tick;

  _StrokePainter({
    required this.committed,
    this.selected,
    this.selectionColor = 0xFF1E88E5,
    this.tick = 0,
  });

  void _drawStroke(Canvas canvas, Size size, Stroke stroke) {
    final pts = stroke.points;
    if (pts.isEmpty) return;
    if (stroke.kind == 'text') {
      final text = stroke.text?.trim();
      if (text == null || text.isEmpty) return;
      final fontSize = stroke.fontSize ?? 18;
      final family = switch (stroke.fontFamily) {
        'serif' => 'serif',
        'mono' => 'monospace',
        _ => null,
      };
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: Color(stroke.color),
            fontSize: fontSize,
            fontFamily: family,
            height: 1.15,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 8,
      )..layout(maxWidth: size.width * 0.55);
      painter.paint(
        canvas,
        Offset(pts.first.dx * size.width, pts.first.dy * size.height),
      );
      return;
    }
    if (stroke.kind == 'pen') {
      canvas.drawPath(
        cachedPenPath(
          stroke,
          size,
          normPoints: stroke.points,
          pressures: stroke.pressures,
          widthFrac: stroke.width,
        ),
        Paint()
          ..style = PaintingStyle.fill
          ..isAntiAlias = true
          ..color = Color(stroke.color),
      );
      return;
    }
    drawSimpleStroke(
      canvas,
      [for (final p in pts) Offset(p.dx * size.width, p.dy * size.height)],
      stroke.kind,
      Color(stroke.color),
      stroke.width * size.width,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in committed) {
      _drawStroke(canvas, size, s);
    }
    final sel = selected;
    if (sel != null && sel.kind == 'text' && sel.points.isNotEmpty) {
      final rect = textStrokeRect(sel, size).inflate(6);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.fill
          ..color = Color(selectionColor).withAlpha(20),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = Color(selectionColor),
      );
    }
  }

  @override
  bool shouldRepaint(_StrokePainter old) =>
      old.committed != committed ||
      old.selected != selected ||
      old.tick != tick;
}

class _ReaderData {
  final File file;
  final int? savedPage;
  _ReaderData({required this.file, this.savedPage});
}
