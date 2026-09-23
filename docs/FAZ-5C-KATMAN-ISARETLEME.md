# FAZ 5C — Kendi Katman-Bazlı İşaretleme (pdfrx overlay, OOM-proof)

> **Ajana not:** Önce `ROADMAP.md`'yi oku. ÖNCEKİ DURUM: `flutter_pdf_annotations` ve Syncfusion büyük PDF'lerde çöküyordu (tüm sayfaları belleğe rasterize ediyorlar). ÇÖZÜM: işaretlemeyi KENDİMİZ yapıyoruz — çizgileri vektör koordinat olarak sunucuda saklayıp pdfrx'in `pageOverlaysBuilder` kancasıyla sayfa üstüne çiziyoruz. Tüm dökümanı asla rasterize etmez. Kod bloklarını BİREBİR uygula. DOĞRULAMA başarısızsa dur ve raporla. OS: Windows, PowerShell.
>
> **DOKUNMA:** `main.dart`, `config.dart`, `settings_screen.dart` (karanlık tema), pomodoro/program dosyaları DOĞRU — değiştirme.

## Mimarinin özeti
- Çizgi (stroke) = `{page, kind(pen/highlight), color, width, points[]}`. `points` sayfaya göre normalize (0..1) koordinatlar. `width` sayfa genişliğinin oranı.
- Sunucu bunları SQLite'ta tutar, çapraz cihaz sync olur.
- Okuyucuda araç çubuğu: **El (kaydır) / Kalem / Fosforlu / Silgi**.
- Çizim, görünen sayfanın üstündeki şeffaf katmanda yapılır; pan modunda katman dokunmayı yok sayar (normal kaydırma).

---

## ADIM 1 — flutter_pdf_annotations'ı kaldır
```powershell
cd <PROJE>\app
flutter pub remove flutter_pdf_annotations
```
> `pdfrx`, `http`, `path_provider`, `shared_preferences` KALACAK. Sadece flutter_pdf_annotations kalkıyor.

---

## ADIM 2 — SUNUCU: `server/main.py`

### 2a. `init_db()` içine annotations tablosunu EKLE
`init_db` fonksiyonundaki `with db() as conn:` bloğunun içine, `tasks` tablosu CREATE'inden SONRA ekle:
```python
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS annotations (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                doc_id     TEXT NOT NULL,
                page       INTEGER NOT NULL,
                kind       TEXT NOT NULL,
                color      INTEGER NOT NULL,
                width      REAL NOT NULL,
                points     TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                device     TEXT
            )
            """
        )
```

### 2b. Pydantic modeli EKLE (diğer `...In` sınıflarının yanına)
```python
class AnnotationIn(BaseModel):
    page: int
    kind: str
    color: int
    width: float
    points: list[list[float]]
    device: str | None = None
```

### 2c. Endpoint'leri EKLE (dosyanın sonuna, diğer endpoint'lerin yanına)
```python
@app.get("/annotations/{doc_id}", dependencies=[Depends(check_auth)])
def list_annotations(doc_id: str):
    with db() as conn:
        rows = conn.execute(
            "SELECT * FROM annotations WHERE doc_id = ? ORDER BY id", (doc_id,)
        ).fetchall()
    return {
        "items": [
            {
                "id": r["id"],
                "page": r["page"],
                "kind": r["kind"],
                "color": r["color"],
                "width": r["width"],
                "points": json.loads(r["points"]),
            }
            for r in rows
        ]
    }


@app.post("/annotations/{doc_id}", dependencies=[Depends(check_auth)])
def add_annotation(doc_id: str, body: AnnotationIn):
    now = int(time.time())
    with db() as conn:
        cur = conn.execute(
            """
            INSERT INTO annotations
                (doc_id, page, kind, color, width, points, updated_at, device)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (doc_id, body.page, body.kind, body.color, body.width,
             json.dumps(body.points), now, body.device),
        )
        new_id = cur.lastrowid
    return {"id": new_id}


@app.delete("/annotations/{stroke_id}", dependencies=[Depends(check_auth)])
def delete_annotation(stroke_id: int):
    with db() as conn:
        conn.execute("DELETE FROM annotations WHERE id = ?", (stroke_id,))
    return {"ok": True}
```
> `json` ve `time` zaten import edili (Faz 2/4). Değilse ekle.

### 2d. Sunucuyu yeniden başlat ve test et
```powershell
cd <PROJE>\server
.\.venv\Scripts\Activate.ps1
uvicorn main:app --host 0.0.0.0 --port 8000
```
Ayrı pencerede (`<TOKEN>`, `<ID>` gerçek):
```powershell
curl -X POST http://localhost:8000/annotations/<ID> -H "X-Auth-Token: <TOKEN>" -H "Content-Type: application/json" -d "{\"page\":1,\"kind\":\"pen\",\"color\":-2400000,\"width\":0.004,\"points\":[[0.1,0.1],[0.2,0.2]]}"
curl http://localhost:8000/annotations/<ID> -H "X-Auth-Token: <TOKEN>"
```
İkinci komut eklenen stroke'u `id` ile dönmeli.

---

## ADIM 3 — `app/lib/models.dart`'a `Stroke` EKLE (mevcutlar kalsın)
Dosyanın EN ÜSTÜNE import ekle (yoksa):
```dart
import 'dart:ui';
```
Sona ekle:
```dart
class Stroke {
  int? id; // sunucu id'si (kaydedilene kadar null)
  final int page; // 1-tabanli
  final String kind; // 'pen' | 'highlight'
  final int color; // ARGB int
  final double width; // sayfa genisliginin orani
  final List<Offset> points; // normalize 0..1

  Stroke({
    this.id,
    required this.page,
    required this.kind,
    required this.color,
    required this.width,
    required this.points,
  });

  factory Stroke.fromJson(Map<String, dynamic> j) => Stroke(
        id: j['id'] as int?,
        page: j['page'] as int,
        kind: j['kind'] as String,
        color: j['color'] as int,
        width: (j['width'] as num).toDouble(),
        points: (j['points'] as List)
            .map((p) => Offset(
                (p[0] as num).toDouble(), (p[1] as num).toDouble()))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'page': page,
        'kind': kind,
        'color': color,
        'width': width,
        'points': points.map((o) => [o.dx, o.dy]).toList(),
      };
}
```

---

## ADIM 4 — `app/lib/api.dart`'a 3 metot EKLE (`Api` sınıfı içine)
```dart
  static Future<List<Stroke>> getAnnotations(String docId) async {
    final res = await http.get(
      Uri.parse('${AppConfig.baseUrl}/annotations/$docId'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw Exception('Isaretlemeler alinamadi (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (data['items'] as List)
        .map((e) => Stroke.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<int> addStroke(String docId, Stroke s) async {
    final res = await http.post(
      Uri.parse('${AppConfig.baseUrl}/annotations/$docId'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({...s.toJson(), 'device': AppConfig.deviceId}),
    );
    if (res.statusCode != 200) {
      throw Exception('Isaretleme eklenemedi (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return data['id'] as int;
  }

  static Future<void> deleteStroke(int id) async {
    await http.delete(
      Uri.parse('${AppConfig.baseUrl}/annotations/$id'),
      headers: _headers,
    );
  }
```

---

## ADIM 5 — `app/lib/screens/reader_screen.dart` TAMAMINI değiştir
```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../api.dart';
import '../models.dart';

enum DrawMode { pan, pen, highlight, eraser }

const int kPenColor = 0xFFE53935; // kirmizi
const int kHighlightColor = 0x55FFEB3B; // yari saydam sari
const double kPenWidth = 0.004;
const double kHighlightWidth = 0.022;

class ReaderScreen extends StatefulWidget {
  final PdfDoc doc;
  const ReaderScreen({super.key, required this.doc});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final PdfViewerController _controller = PdfViewerController();
  late Future<_ReaderData> _loadFuture;

  int _currentPage = 1;
  Timer? _debounce;
  DrawMode _mode = DrawMode.pan;
  final Map<int, List<Stroke>> _byPage = {};
  bool _annotationsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadFuture = _load();
  }

  Future<_ReaderData> _load() async {
    final results = await Future.wait([
      Api.downloadPdf(widget.doc),
      Api.getPosition(widget.doc.id),
      Api.getAnnotations(widget.doc.id),
    ]);
    final strokes = results[2] as List<Stroke>;
    _byPage.clear();
    for (final s in strokes) {
      (_byPage[s.page] ??= []).add(s);
    }
    _annotationsLoaded = true;
    return _ReaderData(
      file: results[0] as File,
      savedPage: (results[1] as ReadingPosition?)?.page,
    );
  }

  void _onPageChanged(int? page) {
    if (page == null) return;
    _currentPage = page;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), _savePosition);
  }

  void _savePosition() {
    Api.putPosition(widget.doc.id, _currentPage).catchError((_) {});
  }

  Future<void> _commitStroke(int page, List<Offset> pts) async {
    if (pts.isEmpty) return;
    final isPen = _mode == DrawMode.pen;
    final stroke = Stroke(
      page: page,
      kind: isPen ? 'pen' : 'highlight',
      color: isPen ? kPenColor : kHighlightColor,
      width: isPen ? kPenWidth : kHighlightWidth,
      points: pts,
    );
    setState(() => (_byPage[page] ??= []).add(stroke));
    try {
      final id = await Api.addStroke(widget.doc.id, stroke);
      stroke.id = id;
    } catch (_) {}
  }

  void _eraseAt(int page, Offset norm) {
    final list = _byPage[page];
    if (list == null) return;
    for (final s in List.of(list)) {
      for (final p in s.points) {
        if ((p - norm).distance < 0.02) {
          setState(() => list.remove(s));
          if (s.id != null) Api.deleteStroke(s.id!).catchError((_) {});
          return;
        }
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _savePosition();
    super.dispose();
  }

  Widget _modeBtn(DrawMode m, IconData icon, String tip) {
    return IconButton(
      tooltip: tip,
      isSelected: _mode == m,
      icon: Icon(icon),
      onPressed: () => setState(() => _mode = m),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.doc.name),
        actions: [
          _modeBtn(DrawMode.pan, Icons.pan_tool, 'Kaydır'),
          _modeBtn(DrawMode.pen, Icons.edit, 'Kalem'),
          _modeBtn(DrawMode.highlight, Icons.highlight, 'Fosforlu'),
          _modeBtn(DrawMode.eraser, Icons.cleaning_services, 'Silgi'),
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
          return PdfViewer.file(
            data.file.path,
            controller: _controller,
            params: PdfViewerParams(
              onViewerReady: (document, controller) {
                final target = data.savedPage;
                if (target != null && target > 1) {
                  controller.goToPage(pageNumber: target);
                }
              },
              onPageChanged: _onPageChanged,
              pageOverlaysBuilder: (context, pageRect, page) {
                if (!_annotationsLoaded) return const [];
                return [
                  Positioned.fill(
                    child: _PageAnnotationLayer(
                      key: ValueKey('anno-${page.pageNumber}-${_mode.index}-'
                          '${_byPage[page.pageNumber]?.length ?? 0}'),
                      strokes: _byPage[page.pageNumber] ?? const [],
                      mode: _mode,
                      onCommit: (pts) => _commitStroke(page.pageNumber, pts),
                      onErase: (n) => _eraseAt(page.pageNumber, n),
                    ),
                  ),
                ];
              },
            ),
          );
        },
      ),
    );
  }
}

class _PageAnnotationLayer extends StatefulWidget {
  final List<Stroke> strokes;
  final DrawMode mode;
  final void Function(List<Offset> normalizedPoints) onCommit;
  final void Function(Offset normalizedPoint) onErase;

  const _PageAnnotationLayer({
    super.key,
    required this.strokes,
    required this.mode,
    required this.onCommit,
    required this.onErase,
  });

  @override
  State<_PageAnnotationLayer> createState() => _PageAnnotationLayerState();
}

class _PageAnnotationLayerState extends State<_PageAnnotationLayer> {
  List<Offset>? _live;
  Size _size = Size.zero;

  Offset _norm(Offset local) => Offset(
        (local.dx / _size.width).clamp(0.0, 1.0),
        (local.dy / _size.height).clamp(0.0, 1.0),
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = Size(constraints.maxWidth, constraints.maxHeight);
        final painter = CustomPaint(
          size: _size,
          painter: _StrokePainter(
            committed: widget.strokes,
            live: _live,
            liveIsPen: widget.mode == DrawMode.pen,
          ),
        );

        if (widget.mode == DrawMode.pan) {
          return IgnorePointer(child: painter);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) {
            final n = _norm(d.localPosition);
            if (widget.mode == DrawMode.eraser) {
              widget.onErase(n);
            } else {
              setState(() => _live = [n]);
            }
          },
          onPanUpdate: (d) {
            final n = _norm(d.localPosition);
            if (widget.mode == DrawMode.eraser) {
              widget.onErase(n);
            } else {
              setState(() => _live = [...?_live, n]);
            }
          },
          onPanEnd: (_) {
            if (widget.mode != DrawMode.eraser && _live != null) {
              widget.onCommit(_live!);
              setState(() => _live = null);
            }
          },
          child: painter,
        );
      },
    );
  }
}

class _StrokePainter extends CustomPainter {
  final List<Stroke> committed;
  final List<Offset>? live;
  final bool liveIsPen;

  _StrokePainter({
    required this.committed,
    required this.live,
    required this.liveIsPen,
  });

  void _drawNorm(Canvas canvas, Size size, List<Offset> pts, int color,
      double widthFrac) {
    if (pts.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Color(color)
      ..strokeWidth = widthFrac * size.width;
    Offset toLocal(Offset n) => Offset(n.dx * size.width, n.dy * size.height);
    if (pts.length == 1) {
      canvas.drawPoints(PointMode.points, [toLocal(pts.first)], paint);
      return;
    }
    final path = Path()..moveTo(toLocal(pts.first).dx, toLocal(pts.first).dy);
    for (var i = 1; i < pts.length; i++) {
      final p = toLocal(pts[i]);
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in committed) {
      _drawNorm(canvas, size, s.points, s.color, s.width);
    }
    if (live != null) {
      _drawNorm(
        canvas,
        size,
        live!,
        liveIsPen ? kPenColor : kHighlightColor,
        liveIsPen ? kPenWidth : kHighlightWidth,
      );
    }
  }

  @override
  bool shouldRepaint(_StrokePainter old) =>
      old.committed != committed || old.live != live;
}

class _ReaderData {
  final File file;
  final int? savedPage;
  _ReaderData({required this.file, this.savedPage});
}
```

> `PointMode` `dart:ui`'dendir; `package:flutter/material.dart` zaten onu yeniden ihraç eder, ek import gerekmez. Derlemede `PointMode` bulunamazsa dosya başına `import 'dart:ui' show PointMode;` ekle.

---

## ADIM 6 — DERLE VE TEST

```powershell
cd <PROJE>\app
flutter run
```
> Sunucu açık olmalı; token kayıtlı değilse Ayarlar'dan gir.

### TEST SIRASI (büyük PDF'i de dahil et):
1. **Büyük gerçek PDF (hmgs son tekrar ~19MB) açılıyor mu?** → pdfrx açar, ÇÖKMEZ. (Artık rasterize eden plugin yok.)
2. Sağ üstten **Kalem** seç, parmakla çiz → kırmızı çizgi görünmeli.
3. **Fosforlu** seç, metin/satır üstünden geç → yarı saydam sarı.
4. **El (kaydır)** seç → sayfa normal kayar/zoom yapar, çizgiler yerinde kalır.
5. **Zoom yap** → çizgiler sayfayla birlikte ölçeklenmeli (kaymamalı).
6. **Silgi** seç, bir çizgiye dokun → o çizgi silinmeli.
7. Okuyucudan çık, tekrar aç → çizimler DURMALI (sunucuya kaydedildi).
8. **Sync:** başka cihazda aynı PDF → çizimler görünmeli.
9. **Sayfa-sync regresyonu:** sayfa ilerle, çık, tekrar aç → kaldığın sayfadan açılmalı.
10. **Karanlık tema / Program / Pomodoro** regresyonsuz çalışmalı.

---

## DOĞRULAMA / BİTİŞ KONTROL LİSTESİ
- [ ] Büyük PDF çökmeden açılıyor (KRİTİK)
- [ ] Kalem ve fosforlu serbest çizim yapıyor
- [ ] El modunda kaydırma/zoom çalışıyor, çizgiler sayfayla ölçekleniyor
- [ ] Silgi çizgi siliyor
- [ ] Çizimler sunucuya kaydediliyor, tekrar açınca duruyor
- [ ] Çizimler çapraz cihaz sync oluyor
- [ ] Sayfa-sync + karanlık tema + program + pomodoro regresyonsuz

Hepsi yeşilse:
```powershell
cd <PROJE>
git add .
git commit -m "Faz 5C: katman-bazli isaretleme (pdfrx overlay, vektor sync, OOM-proof)"
```

---

## Ajan için kurallar
1. Karanlık tema / pomodoro / program / config / settings / main.dart dosyalarına DOKUNMA.
2. `pageOverlaysBuilder`, `pagePaintCallbacks`, `PdfViewerParams`, `goToPage(pageNumber:)` pdfrx 2.2.24'te mevcut — derlemede farklı çıkarsa DUR ve `pubspec.lock`'taki pdfrx sürümünü + ilgili API'yi raporla; uydurma yapma.
3. Büyük PDF testi (ADIM 6.1) başarısızsa DUR ve raporla.
4. Çizim modunda pinch-zoom çalışmazsa bu BEKLENEN davranıştır (katman dokunmayı yakalıyor); zoom için "El" moduna geçilir.
5. Her DOĞRULAMA başarısızsa sonraki adıma geçme.
