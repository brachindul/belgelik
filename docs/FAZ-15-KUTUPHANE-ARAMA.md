# FAZ 15 — Kütüphane Geneli Arama (Tam Metin)

> **Ajana not:** Önce `ROADMAP-V2.md` FAZ 15'i oku. Asıl iş SUNUCUDA: PyMuPDF ile PDF metni çıkar, SQLite **FTS5** ile indeksle, `/search` endpoint'i sun. Uygulamada içerik arama ekranı + sonuçtan PDF'i doğru sayfada açma. Mevcut sync/okuyucu/yükleme mantığını BOZMA. DOĞRULAMA başarısızsa dur. Büyük kütüphanede indeksleme uzun sürebilir → arka planda.

## Amaç
"Bu konu/kelime hangi PDF'te, hangi sayfada geçiyor?" — tüm kaynaklarda tam metin arama; sonuca dokununca PDF o sayfada açılır.

**Kapsam dışı:** Taranmış (görsel) PDF'lerde metin yoktur → OCR YOK (ileride opsiyon). Metin tabanlı PDF'lerde çalışır.

---

## BÖLÜM A — SUNUCU (`server/`)

### A1. Bağımlılık
`server/requirements.txt`'e ekle:
```
pymupdf
```
Kur:
```powershell
cd <PROJE>\server
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```
DOĞRULAMA: `python -c "import fitz; print(fitz.__doc__)"` hata vermemeli (fitz = PyMuPDF).

> **FTS5 kontrolü:** `python -c "import sqlite3; c=sqlite3.connect(':memory:'); c.execute('CREATE VIRTUAL TABLE t USING fts5(x)'); print('FTS5 OK')"`. Hata verirse DUR ve raporla (Python'un sqlite'ında FTS5 yok demektir; nadir).

### A2. `server/main.py` — import + tablolar
Üst importlara ekle:
```python
import fitz  # PyMuPDF
```
`init_db()` içine (with bloğunda) EKLE:
```python
        # Tam metin arama (FTS5) + indeks meta
        conn.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS pdf_text "
            "USING fts5(doc_id UNINDEXED, page UNINDEXED, content, "
            "tokenize = 'unicode61 remove_diacritics 2')"
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS pdf_index_meta (
                doc_id        TEXT PRIMARY KEY,
                relative_path TEXT NOT NULL,
                name          TEXT NOT NULL,
                size          INTEGER NOT NULL,
                modified      INTEGER NOT NULL,
                indexed_at    INTEGER NOT NULL
            )
            """
        )
```

### A3. İndeksleme fonksiyonları (yardımcılar bölümüne)
```python
def index_pdf(path: Path) -> None:
    """Tek bir PDF'i (yeniden) indeksler."""
    rel = path.relative_to(PDF_DIR).as_posix()
    doc_id = doc_id_for(rel)
    stat = path.stat()
    try:
        doc = fitz.open(path)
    except Exception:
        return
    try:
        with db() as conn:
            conn.execute("DELETE FROM pdf_text WHERE doc_id = ?", (doc_id,))
            for i in range(doc.page_count):
                text = doc.load_page(i).get_text("text")
                if text and text.strip():
                    conn.execute(
                        "INSERT INTO pdf_text (doc_id, page, content) VALUES (?, ?, ?)",
                        (doc_id, i + 1, text),
                    )
            conn.execute(
                """
                INSERT INTO pdf_index_meta (doc_id, relative_path, name, size, modified, indexed_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(doc_id) DO UPDATE SET
                    relative_path=excluded.relative_path, name=excluded.name,
                    size=excluded.size, modified=excluded.modified, indexed_at=excluded.indexed_at
                """,
                (doc_id, rel, path.stem, stat.st_size, int(stat.st_mtime), int(time.time())),
            )
    finally:
        doc.close()


def reindex_all() -> dict:
    """Yeni/degisen PDF'leri indeksler, silinmis olanlari temizler."""
    seen = set()
    indexed = 0
    for path in PDF_DIR.rglob("*.pdf"):
        rel = path.relative_to(PDF_DIR).as_posix()
        doc_id = doc_id_for(rel)
        seen.add(doc_id)
        stat = path.stat()
        with db() as conn:
            row = conn.execute(
                "SELECT size, modified FROM pdf_index_meta WHERE doc_id = ?", (doc_id,)
            ).fetchone()
        if row is None or row["size"] != stat.st_size or row["modified"] != int(stat.st_mtime):
            index_pdf(path)
            indexed += 1
    # silinmis dosyalari temizle
    with db() as conn:
        rows = conn.execute("SELECT doc_id FROM pdf_index_meta").fetchall()
        for r in rows:
            if r["doc_id"] not in seen:
                conn.execute("DELETE FROM pdf_text WHERE doc_id = ?", (r["doc_id"],))
                conn.execute("DELETE FROM pdf_index_meta WHERE doc_id = ?", (r["doc_id"],))
    return {"indexed": indexed, "total": len(seen)}


def _fts_query(q: str) -> str:
    """Kullanici girdisini guvenli FTS5 sorgusuna cevirir (prefix + AND)."""
    terms = [t for t in q.replace('"', " ").split() if t]
    if not terms:
        return ""
    return " ".join(f'"{t}"*' for t in terms)
```

### A4. Endpoint'ler
```python
from fastapi import BackgroundTasks  # ust importa ekle


@app.post("/reindex", dependencies=[Depends(check_auth)])
def reindex(background_tasks: BackgroundTasks):
    background_tasks.add_task(reindex_all)
    return {"ok": True, "status": "started"}


@app.get("/search", dependencies=[Depends(check_auth)])
def search(q: str, limit: int = 50):
    match = _fts_query(q)
    if not match:
        return {"items": []}
    sql = """
        SELECT t.doc_id AS doc_id, t.page AS page,
               snippet(pdf_text, 2, '[', ']', '…', 12) AS snippet,
               m.name AS name, m.relative_path AS relative_path,
               m.size AS size, m.modified AS modified
        FROM pdf_text t
        JOIN pdf_index_meta m ON m.doc_id = t.doc_id
        WHERE pdf_text MATCH ?
        ORDER BY rank
        LIMIT ?
    """
    with db() as conn:
        rows = conn.execute(sql, (match, limit)).fetchall()
    return {
        "items": [
            {
                "doc_id": r["doc_id"],
                "page": r["page"],
                "snippet": r["snippet"],
                "name": r["name"],
                "relative_path": r["relative_path"],
                "size": r["size"],
                "modified": r["modified"],
            }
            for r in rows
        ]
    }
```

### A5. Yükleme sonrası otomatik indeks
`upload_new_pdf` endpoint'inin sonunda (dosya yazıldıktan sonra, `return`'den önce) EKLE:
```python
    try:
        index_pdf(target)
    except Exception:
        pass
```

### A6. İlk indeksleme + DOĞRULAMA
Sunucuyu yeniden başlat. Sonra bir kez tam indeksleme tetikle:
```powershell
curl -X POST http://localhost:8000/reindex -H "X-Auth-Token: <TOKEN>"
# birkac saniye/dakika bekle (kutuphane buyuklugune gore), sonra:
curl "http://localhost:8000/search?q=idare" -H "X-Auth-Token: <TOKEN>"
```
- `/search` sonuç döndürmeli: `{items:[{doc_id,page,snippet,name,...}]}`.
- Türkçe/diakritik: "idare" ↔ "İdare" makul eşleşmeli (remove_diacritics sayesinde).

> İndeksleme arka planda olduğu için `/reindex` hemen döner; metin birkaç saniye sonra hazırdır. İlk büyük kütüphanede dakikalar sürebilir.

---

## BÖLÜM B — UYGULAMA

### B1. Model (`app/lib/models.dart`)
```dart
class SearchHit {
  final String docId;
  final int page;
  final String snippet;
  final String name;
  final String relativePath;
  final int size;
  final int modified;

  SearchHit({
    required this.docId,
    required this.page,
    required this.snippet,
    required this.name,
    required this.relativePath,
    required this.size,
    required this.modified,
  });

  factory SearchHit.fromJson(Map<String, dynamic> j) => SearchHit(
        docId: j['doc_id'] as String,
        page: j['page'] as int,
        snippet: (j['snippet'] as String?) ?? '',
        name: j['name'] as String,
        relativePath: j['relative_path'] as String,
        size: j['size'] as int,
        modified: j['modified'] as int,
      );

  PdfDoc toPdfDoc() => PdfDoc(
        id: docId,
        name: name,
        relativePath: relativePath,
        size: size,
        modified: modified,
      );
}
```
> `PdfDoc` constructor'ında `favorite`/`localFilePath`/`isCached` alanları varsa ve zorunluysa, opsiyonel/varsayılan değerlerle çağır (örn. `favorite: false`). Mevcut `PdfDoc` imzasına uydur.

### B2. API (`app/lib/api.dart`)
```dart
  static Future<List<SearchHit>> searchContent(String query) async {
    final res = await http.get(
      Uri.parse(
          '${AppConfig.baseUrl}/search?q=${Uri.encodeQueryComponent(query)}'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw Exception('Arama başarısız (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (data['items'] as List)
        .map((e) => SearchHit.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> reindex() async {
    await http.post(
      Uri.parse('${AppConfig.baseUrl}/reindex'),
      headers: _headers,
    );
  }
```

### B3. Okuyucuya belirli sayfada açma desteği
`reader_screen.dart`'ta `ReaderScreen`'e opsiyonel `initialPage` EKLE:
```dart
  final int? initialPage;
  const ReaderScreen({super.key, required this.doc, this.initialPage});
```
Açılışta sayfaya atlarken `initialPage`'i önceliklendir. `onViewerReady` içindeki hedef hesabını değiştir:
```dart
              onViewerReady: (document, controller) {
                _pageCount = document.pages.length;
                // ... mevcut text searcher kurulumu kalsin ...
                final target = widget.initialPage ?? data.savedPage;
                if (target != null && target > 1) {
                  controller.goToPage(pageNumber: target);
                }
                _scheduleReadingGoalNotifications();
              },
```

### B4. İçerik arama ekranı (`app/lib/screens/content_search_screen.dart`)
```dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'reader_screen.dart';

class ContentSearchScreen extends StatefulWidget {
  const ContentSearchScreen({super.key});

  @override
  State<ContentSearchScreen> createState() => _ContentSearchScreenState();
}

class _ContentSearchScreenState extends State<ContentSearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  Future<List<SearchHit>>? _future;
  String _last = '';

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      final q = v.trim();
      if (q.length < 2) {
        setState(() => _future = null);
        return;
      }
      _last = q;
      setState(() => _future = Api.searchContent(q));
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Tüm PDF’lerde ara…',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
        ),
      ),
      body: _future == null
          ? const Center(child: Text('En az 2 harf yazın'))
          : FutureBuilder<List<SearchHit>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text('Hata: ${snap.error}'));
                }
                final hits = snap.data!;
                if (hits.isEmpty) {
                  return const Center(child: Text('Sonuç yok'));
                }
                return ListView.separated(
                  itemCount: hits.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final h = hits[i];
                    return ListTile(
                      leading: const Icon(Icons.find_in_page),
                      title: Text('${h.name}  ·  s.${h.page}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(h.snippet,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ReaderScreen(
                            doc: h.toPdfDoc(),
                            initialPage: h.page,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}
```

### B5. Kütüphaneden giriş
`library_screen.dart` AppBar action'larına (arama ikonunun yanına) içerik araması ikonu EKLE:
```dart
                if (!_searching)
                  IconButton(
                    tooltip: 'İçerikte ara',
                    icon: const Icon(Icons.manage_search),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ContentSearchScreen(),
                      ),
                    ),
                  ),
```
Importu ekle: `import 'content_search_screen.dart';`
> Mevcut `Icons.search` (yerel ada-göre filtre) KALSIN; bu yeni `Icons.manage_search` "içerikte ara"dır. İkisi ayrı.

(Opsiyonel) Ayarlar'a "Aramayı yeniden indeksle" butonu: `Api.reindex()` çağırır + "İndeksleme başladı" snackbar.

---

## TEST
1. `pip install` sonrası `import fitz` ve FTS5 kontrolü geçer.
2. `/reindex` → birkaç sn sonra `/search?q=...` sonuç döner (curl).
3. Uygulamada kütüphane > "İçerikte ara" (büyüteç+) → kelime yaz → sonuçlar (PDF adı · sayfa · bağlam).
4. Sonuca dokun → PDF **o sayfada** açılır.
5. Yeni bir PDF yükle → kısa süre sonra aramada çıkar (otomatik indeks).
6. Türkçe: "İdare/idare" makul eşleşir.

## DOĞRULAMA / BİTİŞ
- [ ] PyMuPDF kurulu, FTS5 çalışıyor
- [ ] `/reindex` + `/search` curl ile çalışıyor
- [ ] İçerik arama ekranı sonuç gösteriyor
- [ ] Sonuçtan PDF doğru sayfada açılıyor
- [ ] Yeni yüklenen PDF otomatik indeksleniyor
- [ ] Okuyucu/sync/yerel-arama regresyonsuz

```powershell
cd <PROJE> && git add -A && git commit -m "Faz 15: kutuphane geneli tam metin arama (PyMuPDF + FTS5)"
```

---

## Ajan için kurallar
1. `fitz` (PyMuPDF) API'si (`open`, `page_count`, `load_page`, `get_text`) sürümde farklıysa DUR ve raporla.
2. FTS5 yoksa DUR ve raporla (alternatif: LIKE tabanlı yavaş arama — ancak önce raporla).
3. Büyük kütüphanede indeksleme uzun → arka plan task; kullaniciyi bloklamayan akış.
4. `PdfDoc` constructor imzasına uy (zorunlu alanlar için varsayılan ver).
5. `initialPage` eklenince mevcut sayfa-sync (savedPage) davranışını bozma — sadece initialPage öncelikli.
6. Her DOĞRULAMA başarısızsa sonraki adıma geçme.
