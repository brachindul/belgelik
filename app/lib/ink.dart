import 'dart:math';
import 'dart:ui' show PointMode;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

/// Ortak murekkep motoru: PDF okuyucu isaretlemeleri ve not editoru ayni
/// boru hattini kullanir (perfect_freehand tabanli basinc duyarli cizim,
/// canli darbe notifier'i, nokta seyreltme, avuc reddi zaman damgasi).

// ---------------------------------------------------------------------------
// Kalem dis cizgisi (outline)
// ---------------------------------------------------------------------------

StrokeOptions _penOptions(
  double sizePx,
  List<double>? pressures,
  bool complete,
) {
  return StrokeOptions(
    size: sizePx,
    thinning: 0.55,
    smoothing: 0.5,
    streamline: 0.45,
    simulatePressure: pressures == null,
    isComplete: complete,
  );
}

/// Kalem darbesini basinc/hiza gore kalinligi degisen kapali bir dis cizgi
/// olarak uretir (Samsung Notes benzeri murekkep hissi).
Path penOutlinePath(
  List<Offset> ptsPx,
  List<double>? pressures,
  double sizePx, {
  required bool complete,
}) {
  final input = <PointVector>[
    for (var i = 0; i < ptsPx.length; i++)
      PointVector(
        ptsPx[i].dx,
        ptsPx[i].dy,
        pressures != null && i < pressures.length ? pressures[i] : null,
      ),
  ];
  final outline = getStroke(
    input,
    options: _penOptions(sizePx, pressures, complete),
  );
  final path = Path();
  if (outline.isEmpty) return path;
  if (outline.length < 3) {
    path.addOval(
      Rect.fromCircle(center: ptsPx.first, radius: max(sizePx / 2, 1)),
    );
    return path;
  }
  // Dis cizgiyi orta noktalardan gecen quadratic bezier'lerle puruzsuzlestir.
  path.moveTo(outline.first.dx, outline.first.dy);
  for (var i = 1; i < outline.length - 1; i++) {
    final p0 = outline[i];
    final p1 = outline[i + 1];
    path.quadraticBezierTo(
      p0.dx,
      p0.dy,
      (p0.dx + p1.dx) / 2,
      (p0.dy + p1.dy) / 2,
    );
  }
  path.close();
  return path;
}

class _CachedPenPath {
  final Size size;
  final Path path;
  _CachedPenPath(this.size, this.path);
}

final Expando<_CachedPenPath> _penPathCache = Expando<_CachedPenPath>();

/// Tamamlanmis kalem darbeleri icin path onbellegi: ayni darbe nesnesi ayni
/// boyutta tekrar boyanirken outline yeniden hesaplanmaz. [key] darbe modeli
/// nesnesidir (Stroke veya InkStroke); noktalar normalize (0..1) verilir,
/// x/y carpanlari ayri olabilir (not editoru y'yi de genislige olcekler).
Path cachedPenPath(
  Object key,
  Size size, {
  required List<Offset> normPoints,
  required List<double>? pressures,
  required double widthFrac,
  double? yScale,
}) {
  final cached = _penPathCache[key];
  if (cached != null && cached.size == size) return cached.path;
  final ys = yScale ?? size.height;
  final pts = [
    for (final p in normPoints) Offset(p.dx * size.width, p.dy * ys),
  ];
  final path = penOutlinePath(
    pts,
    pressures,
    widthFrac * size.width,
    complete: true,
  );
  _penPathCache[key] = _CachedPenPath(size, path);
  return path;
}

/// pen disindaki turlerin (highlight/rect/arrow/duz cizgi) ortak cizimi.
void drawSimpleStroke(
  Canvas canvas,
  List<Offset> pts,
  String kind,
  Color color,
  double strokeWidth,
) {
  if (pts.isEmpty) return;
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = color
    ..strokeWidth = strokeWidth;

  switch (kind) {
    case 'rect':
      if (pts.length < 2) return;
      canvas.drawRect(Rect.fromPoints(pts.first, pts.last), paint);
    case 'arrow':
      if (pts.length < 2) return;
      final a = pts.first, b = pts.last;
      canvas.drawLine(a, b, paint);
      final theta = (b - a).direction;
      const ah = 16.0;
      final w1 = b - Offset(ah * cos(theta - 0.5), ah * sin(theta - 0.5));
      final w2 = b - Offset(ah * cos(theta + 0.5), ah * sin(theta + 0.5));
      canvas.drawLine(b, w1, paint);
      canvas.drawLine(b, w2, paint);
    default:
      if (pts.length == 1) {
        canvas.drawPoints(PointMode.points, [pts.first], paint);
        return;
      }
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      canvas.drawPath(path, paint);
  }
}

// ---------------------------------------------------------------------------
// Canli darbe
// ---------------------------------------------------------------------------

/// Cizim sirasindaki canli darbe. ChangeNotifier oldugu icin canli painter
/// setState'e (widget rebuild'ine) gerek kalmadan yalnizca kendi katmanini
/// boyar — kalem gecikmesinin/janki'nin ana cozumu.
class LiveInkStroke extends ChangeNotifier {
  List<Offset>? points; // normalize 0..1
  List<double?>? pressures;
  String kind = 'pen';
  int color = 0xFF000000;
  double widthFrac = 0.004;

  bool get active => points != null;

  void start(Offset n, double? pressure, String k, int c, double w) {
    kind = k;
    color = c;
    widthFrac = w;
    points = [n];
    pressures = [pressure];
    notifyListeners();
  }

  void add(Offset n, double? pressure) {
    if (points == null) return;
    if (kind == 'pen') {
      points!.add(n);
      pressures!.add(pressure);
    } else {
      // highlight/rect/arrow: 2 nokta (baslangic + guncel)
      points!.length = 1;
      points!.add(n);
    }
    notifyListeners();
  }

  void clear() {
    points = null;
    pressures = null;
    notifyListeners();
  }

  /// Commit icin basinc dizisi: yalnizca kalemde ve gercekten degisen basinc
  /// olculdugunde dondurulur; aksi halde null (cizimde hiz taklidi kullanilir).
  List<double>? commitPressures() {
    if (kind != 'pen') return null;
    final pr = pressures;
    if (pr == null || pr.any((p) => p == null)) return null;
    final values = pr.cast<double>();
    final first = values.first;
    if (values.every((p) => (p - first).abs() < 0.001)) return null;
    return List<double>.from(values);
  }

  /// Canli cizim icin basinc listesi (tumu olculmusse), yoksa null.
  List<double>? livePressures() {
    final pr = pressures;
    if (pr == null || pr.any((p) => p == null)) return null;
    return pr.cast<double>();
  }
}

// ---------------------------------------------------------------------------
// Stylus yardimcilari
// ---------------------------------------------------------------------------

bool isStylusEvent(PointerEvent e) =>
    e.kind == PointerDeviceKind.stylus ||
    e.kind == PointerDeviceKind.invertedStylus;

bool hasStylusButton(PointerEvent e) =>
    (e.buttons & kPrimaryStylusButton) != 0 ||
    (e.buttons & kSecondaryStylusButton) != 0;

/// Cihazin bildirdigi basinci 0..1 araligina getirir; basinc bildirmeyen
/// cihazlarda (araliksiz) null doner.
double? normalizedPressure(PointerEvent e) {
  if (!isStylusEvent(e)) return null;
  final range = e.pressureMax - e.pressureMin;
  if (range <= 0) return null;
  return ((e.pressure - e.pressureMin) / range).clamp(0.0, 1.0);
}

/// Avuc reddi icin uygulama capinda stylus varlik kaydi: S Pen yakin zamanda
/// ekrandayken (temas veya hover) parmak jestleri cizim/silme yapmamali.
class StylusPresence {
  static int _lastSeenMs = 0;
  static bool _everSeen = false;

  static void markSeen() {
    _lastSeenMs = DateTime.now().millisecondsSinceEpoch;
    _everSeen = true;
  }

  static bool get recentlySeen =>
      DateTime.now().millisecondsSinceEpoch - _lastSeenMs < 800;

  /// Bu oturumda hic stylus goruldu mu (arac cubugu gorunurlugu icin).
  static bool get everSeen => _everSeen;
}

/// Cizim sirasinda tek noktanin altinda kalan minimum piksel mesafesi;
/// sensor gurultusunu eler, perfect_freehand'in streamline'i gerisini yapar.
const double kMinInkPointDistPx = 1.2;
