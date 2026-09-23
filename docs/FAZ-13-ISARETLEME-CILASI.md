# FAZ 13 — İşaretleme Cilası (kalınlık, renk, şekiller, ters-uç silgi)

> **Ajana not:** Önce `ROADMAP-V2.md` FAZ 13'ü oku. Tamamen istemci tarafı (reader). Sunucu/şema değişmez — `Stroke.kind` yeni değerler alır (`rect`, `arrow`); sunucu zaten string saklar. Bilinmeyen `kind` painter'ı çökertmemeli (görmezden gel). DOĞRULAMA başarısızsa dur.

## Amaç
1. **Kalem kalınlığı** (ince/orta/kalın).
2. **Daha çok renk** (genişletilmiş palet).
3. **Şekiller:** dikdörtgen (`rect`) ve ok (`arrow`) — iki nokta (başlangıç + bitiş).
4. **Ters uç silgi:** S Pen ters ucu (`invertedStylus`) silgi gibi davranır.

---

## ADIM 1 — Sabitler ve enum (`reader_screen.dart`)
`DrawMode` enum'a şekilleri EKLE:
```dart
enum DrawMode { pan, pen, highlight, eraser, rect, arrow }
```
Genişletilmiş paletler (mevcut listeleri değiştir):
```dart
const List<int> kPenPalette = [
  0xFFE53935, 0xFFD81B60, 0xFF8E24AA, 0xFF5E35B1,
  0xFF1E88E5, 0xFF00897B, 0xFF43A047, 0xFFF4511E,
  0xFFFB8C00, 0xFF6D4C41, 0xFF000000, 0xFF546E7A,
];
const List<int> kHighlightPalette = [
  0x55FFEB3B, 0x5566BB6A, 0x5542A5F5, 0x55EC407A,
  0x55FF7043, 0x55AB47BC,
];
```
Kalınlık seçenekleri (oran tabanlı, kalem için):
```dart
const Map<String, double> kPenWidths = {
  'İnce': 0.0025,
  'Orta': 0.004,
  'Kalın': 0.007,
};
```

## ADIM 2 — State (`_ReaderScreenState`)
EKLE:
```dart
  double _penWidth = kPenWidths['Orta']!;
```
(`kPenWidth` sabiti yerine bu state kullanılacak; `kHighlightWidth` aynı kalır.)

## ADIM 3 — `_commitStroke`'u kind tabanlı yap
İmzayı değiştir: `bool isHighlight` yerine `String kind` al.
```dart
  Future<void> _commitStroke(int page, List<Offset> pts, String kind) async {
    if (pts.isEmpty) return;
    final isHl = kind == 'highlight';
    final stroke = Stroke(
      page: page,
      kind: kind,
      color: isHl ? _highlightColor : _penColor,
      width: isHl ? kHighlightWidth : _penWidth,
      points: pts,
    );
    stroke.strokeUuid =
        '${DateTime.now().microsecondsSinceEpoch}-${stroke.page}-${_strokeSeq++}';
    await LocalStore.upsertStroke(stroke, widget.doc.id, dirty: true);
    setState(() => (_byPage[page] ??= []).add(stroke));
    _history.add(stroke);
    try {
      final id = await Api.addStroke(widget.doc.id, stroke);
      stroke.id = id;
      await LocalStore.upsertStroke(stroke, widget.doc.id, dirty: false);
    } catch (_) {}
  }
```

## ADIM 4 — Layer'da kind üretimi + ters-uç silgi
`_PageAnnotationLayer.onCommit` tipini değiştir:
```dart
  final void Function(List<Offset> normalizedPoints, String kind) onCommit;
```
State'te `_liveHighlight` yerine `_liveKind` (String) tut. Çizim mantığı:
- Stylus normal uç → kind = `widget.penIsHighlight ? 'highlight' : 'pen'`.
- Stylus **ters uç (invertedStylus)** → **silgi** (çizim değil): `widget.onErase(...)`.
- Parmak → moda göre kind: pen→'pen', highlight→'highlight', rect→'rect', arrow→'arrow', eraser→erase.

`_updateDraw` kuralı:
- `pen` → serbest (nokta ekle).
- `highlight`, `rect`, `arrow` → **iki nokta** (başlangıç + güncel): `_live = [_live!.first, n]`.

Güncel `_PageAnnotationLayerState` çizim çekirdeği (uyarlanmış):
```dart
  List<Offset>? _live;
  String _liveKind = 'pen';
  Size _size = Size.zero;

  Offset _norm(Offset local) => Offset(
        (local.dx / _size.width).clamp(0.0, 1.0),
        (local.dy / _size.height).clamp(0.0, 1.0),
      );

  void _startDraw(Offset local, String kind) {
    _liveKind = kind;
    setState(() => _live = [_norm(local)]);
  }

  void _updateDraw(Offset local) {
    if (_live == null) return;
    final n = _norm(local);
    if (_liveKind == 'pen') {
      setState(() => _live = [...?_live, n]);
    } else {
      setState(() => _live = [_live!.first, n]); // highlight/rect/arrow: 2 nokta
    }
  }

  void _endDraw() {
    if (_live != null) widget.onCommit(_live!, _liveKind);
    setState(() => _live = null);
  }

  bool _isStylus(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus;
```
Listener (stylus) — ters uç silgi:
```dart
          onPointerDown: (e) {
            if (!_isStylus(e)) return;
            widget.onStylusActive(true);
            if (e.kind == PointerDeviceKind.invertedStylus) {
              widget.onErase(_norm(e.localPosition));
            } else {
              _startDraw(e.localPosition, widget.penIsHighlight ? 'highlight' : 'pen');
            }
          },
          onPointerMove: (e) {
            if (!_isStylus(e)) return;
            if (e.kind == PointerDeviceKind.invertedStylus) {
              widget.onErase(_norm(e.localPosition));
            } else {
              _updateDraw(e.localPosition);
            }
          },
          onPointerUp: (e) {
            if (!_isStylus(e)) return;
            if (e.kind != PointerDeviceKind.invertedStylus) _endDraw();
            widget.onStylusActive(false);
          },
```
Parmak (fingerChild) switch'i kind'e göre:
```dart
        Widget fingerChild;
        switch (widget.mode) {
          case DrawMode.pan:
            fingerChild = painter;
          case DrawMode.eraser:
            fingerChild = GestureDetector(
              behavior: HitTestBehavior.opaque,
              supportedDevices: const {PointerDeviceKind.touch},
              onPanStart: (d) => widget.onErase(_norm(d.localPosition)),
              onPanUpdate: (d) => widget.onErase(_norm(d.localPosition)),
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
              onPanStart: (d) => _startDraw(d.localPosition, kind),
              onPanUpdate: (d) => _updateDraw(d.localPosition),
              onPanEnd: (_) => _endDraw(),
              child: painter,
            );
        }
```
Layer'a `onCommit (pts, kind)` geçişini reader'da güncelle:
```dart
                      onCommit: (pts, kind) =>
                          _commitStroke(page.pageNumber, pts, kind),
```
Ayrıca live painter rengini kind'e göre seç: `_liveKind=='highlight' ? widget.highlightColor : widget.penColor` ve genişlik `_liveKind=='highlight' ? kHighlightWidth : <penWidth gelmeli>`. **penWidth'i layer'a parametre geçir:** `_PageAnnotationLayer`'a `final double penWidth;` ekle ve reader'dan `penWidth: _penWidth` geç; live width için onu kullan.

## ADIM 5 — Painter: rect ve arrow çiz
`_StrokePainter._drawNorm`'a kind ekle. Painter'a strokes'un kind'ine göre çizim:
```dart
  void _drawStroke(Canvas canvas, Size size, List<Offset> pts, int color,
      double widthFrac, String kind) {
    if (pts.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Color(color)
      ..strokeWidth = widthFrac * size.width;
    Offset toL(Offset n) => Offset(n.dx * size.width, n.dy * size.height);

    switch (kind) {
      case 'rect':
        if (pts.length < 2) return;
        canvas.drawRect(Rect.fromPoints(toL(pts.first), toL(pts.last)), paint);
      case 'arrow':
        if (pts.length < 2) return;
        final a = toL(pts.first), b = toL(pts.last);
        canvas.drawLine(a, b, paint);
        // ok ucu
        final angle = (b - a).direction;
        const head = 14.0;
        for (final s in [2.6, -2.6]) {
          final p = b -
              Offset(head * 1, 0).translate(0, 0); // placeholder
          final hx = b.dx - head * (1) * 0; // hesap asagida
        }
        final dir = (b - a).direction;
        const ah = 16.0;
        final p1 = Offset(b.dx - ah * 1, b.dy);
        // basit ok ucu: iki kisa cizgi
        canvas.drawLine(
            b, b - Offset(ah, 0).translate(0, 0) , paint); // bkz NOT
      default:
        // pen / highlight / bilinmeyen -> polyline
        if (pts.length == 1) {
          canvas.drawPoints(PointMode.points, [toL(pts.first)], paint);
          return;
        }
        final path = Path()..moveTo(toL(pts.first).dx, toL(pts.first).dy);
        for (var i = 1; i < pts.length; i++) {
          path.lineTo(toL(pts[i]).dx, toL(pts[i]).dy);
        }
        canvas.drawPath(path, paint);
    }
  }
```
> **NOT (ok ucu):** Yukarıdaki `arrow` ok-ucu kodu taslaktır; doğru ok ucu için şu mantığı kullan: yön açısı `theta = (b-a).direction`, ok kolu uzunluğu `ah=16`, iki kol: `b - ah*Offset(cos(theta±0.5), sin(theta±0.5))`. `dart:math` (cos/sin) zaten import. Net uygulama:
```dart
      case 'arrow':
        if (pts.length < 2) return;
        final a = toL(pts.first), b = toL(pts.last);
        canvas.drawLine(a, b, paint);
        final theta = (b - a).direction;
        const ah = 16.0;
        final w1 = b - Offset(ah * cos(theta - 0.5), ah * sin(theta - 0.5));
        final w2 = b - Offset(ah * cos(theta + 0.5), ah * sin(theta + 0.5));
        canvas.drawLine(b, w1, paint);
        canvas.drawLine(b, w2, paint);
```
`paint()` içinde her committed stroke için `_drawStroke(..., s.kind)` çağır; live için `_liveKind` geç. `_StrokePainter`'a `liveKind` alanı ekle ve `shouldRepaint`'e dahil et.

## ADIM 6 — Araç çubuğu + menü
- Alt bara şekil butonları ekle (dar ise ⋮'ya): `_toolButton(DrawMode.rect, Icons.crop_square, 'Dikdörtgen')`, `_toolButton(DrawMode.arrow, Icons.north_east, 'Ok')`.
- **Kalınlık:** ⋮ menüsüne "İnce/Orta/Kalın" (CheckedPopupMenuItem) → `setState(() => _penWidth = kPenWidths[x]!)`.
- Renk: `_pickColor` zaten paleti gösteriyor; genişletilmiş palet otomatik gelir (Wrap). İstersen şekiller için de kalem rengini kullan (rect/arrow → penColor).

## TEST
1. Kalem kalınlığını ⋮'dan değiştir → çizgi kalınlığı değişir, kaydedilir.
2. Genişletilmiş renk paletinden seç → uygulanır.
3. Dikdörtgen ve Ok çiz → doğru çizilir, tekrar açınca durur, sync olur.
4. S Pen ters ucu ile dokun → siler (destekleyen cihazda).
5. Eski `pen/highlight` çizimler bozulmadan görünür.

## DOĞRULAMA
- [ ] Kalınlık/renk/şekiller çalışıyor ve kalıcı/sync
- [ ] Ters uç silgi (varsa) çalışıyor
- [ ] Bilinmeyen kind painter'ı çökertmiyor
- [ ] Regresyon yok (pen/highlight/eraser)

```powershell
cd <PROJE> && git add -A && git commit -m "Faz 13: isaretleme cilasi (kalinlik, renk, sekiller, ters-uc silgi)"
```
