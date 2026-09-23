# FAZ 11 — Yer İmleri (Bookmark) + İçindekiler (Outline)

> **Ajana not:** Önce `ROADMAP-V2.md` FAZ 11'i oku. Yer imleri mevcut offline-first sync desenine (local SQLite + dirty + /sync/push,/pull + soft-delete) **annotations'ı birebir taklit ederek** eklenir. İçindekiler PDF'ten okunur, saklanmaz. Mevcut sync/annotation mantığını BOZMA. DOĞRULAMA başarısızsa dur. pdfrx outline API'si sürümde farklıysa DUR ve sürümü raporla.

## Amaç
1. PDF'te sayfayı yer imine ekle/sil, listeden o sayfaya atla; çapraz cihaz sync.
2. PDF'in kendi içindekiler (TOC/outline) ağacıyla gezinme.

---

## BÖLÜM A — VERİ MODELİ

### A1. `app/lib/models.dart` — `Bookmark` EKLE
```dart
class Bookmark {
  String? bookmarkUuid;
  final String docId;
  final int page;
  final String label;
  final int? updatedAtMs;
  final String? updatedByDevice;
  final int? deletedAtMs;

  Bookmark({
    this.bookmarkUuid,
    required this.docId,
    required this.page,
    required this.label,
    this.updatedAtMs,
    this.updatedByDevice,
    this.deletedAtMs,
  });

  factory Bookmark.fromJson(Map<String, dynamic> j) => Bookmark(
        bookmarkUuid: j['bookmark_uuid'] as String?,
        docId: j['doc_id'] as String,
        page: j['page'] as int,
        label: (j['label'] as String?) ?? '',
        updatedAtMs: j['updated_at_ms'] as int?,
        updatedByDevice: j['updated_by_device'] as String?,
        deletedAtMs: j['deleted_at_ms'] as int?,
      );
}
```

---

## BÖLÜM B — SUNUCU (`server/main.py`)

### B1. `init_db()` içine tablo EKLE (annotations CREATE'inin yanına)
```python
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS bookmarks (
                bookmark_uuid     TEXT PRIMARY KEY,
                doc_id            TEXT NOT NULL,
                page              INTEGER NOT NULL,
                label             TEXT NOT NULL DEFAULT '',
                updated_at_ms     INTEGER NOT NULL,
                updated_by_device TEXT,
                deleted_at_ms     INTEGER
            )
            """
        )
```

### B2. `/sync/push` ve `/sync/pull`'a `bookmarks` EKLE
> Bu iki endpoint'te `annotations` nasıl ele alınıyorsa bookmarks'ı **aynen** mirror et.

**Pydantic giriş modeli** (push gövdesindeki `annotations`'ın yanına `bookmarks` alanı). Bookmark item şekli:
`{bookmark_uuid, doc_id, page, label, updated_at_ms, updated_by_device, deleted_at_ms}`.

**push** içinde, annotations için yapılan upsert bloğunun hemen ardına bookmarks için aynı mantıkla bir `INSERT ... ON CONFLICT(bookmark_uuid) DO UPDATE` ekle (last-write-wins: gelen `updated_at_ms` mevcuttan büyükse güncelle; soft-delete `deleted_at_ms` taşı).

**pull** içinde, `since_ms`'den sonra `updated_at_ms > since_ms` olan bookmarks satırlarını çekip yanıt JSON'una `"bookmarks": [...]` olarak ekle (annotations ile aynı biçimde).

> Annotations bloğunu kopyalayıp alan adlarını bookmark'a uyarlamak yeterli. Şema/biçim annotations ile birebir paralel.

### B3. Sunucuyu yeniden başlat, curl ile push/pull'da `bookmarks` alanının döndüğünü doğrula.

---

## BÖLÜM C — YEREL DEPO (`app/lib/local_store.dart`)

### C1. `_onCreate`'e tablo EKLE
```dart
    await db.execute(
      'CREATE TABLE local_bookmarks (bookmark_uuid TEXT PRIMARY KEY, doc_id TEXT NOT NULL, page INTEGER NOT NULL, label TEXT NOT NULL DEFAULT \'\', updated_at_ms INTEGER NOT NULL, updated_by_device TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, deleted_at_ms INTEGER)',
    );
```
> NOT: Mevcut DB version=1 ve onCreate kuruluysa, bu tabloyu yeni kurulumlarda oluşturur. Var olan kurulumlar için: DB version'ı **2'ye çıkar** ve `_onUpgrade` içine `if (oldVersion < 2) { await db.execute('CREATE TABLE IF NOT EXISTS local_bookmarks ...'); }` ekle (aynı SQL). Böylece eski cihazlarda tablo eklenir.

### C2. Metotlar EKLE (annotations metotlarını taklit et)
```dart
  static Future<List<Bookmark>> getLocalBookmarks(String docId) async {
    final db = await database;
    final rows = await db.query(
      'local_bookmarks',
      where: 'doc_id = ? AND deleted_at_ms IS NULL',
      whereArgs: [docId],
      orderBy: 'page',
    );
    return rows.map(_bookmarkFromRow).toList();
  }

  static Future<void> upsertBookmark(Bookmark b, {required bool dirty}) async {
    final db = await database;
    await db.insert('local_bookmarks', {
      'bookmark_uuid': b.bookmarkUuid,
      'doc_id': b.docId,
      'page': b.page,
      'label': b.label,
      'updated_at_ms': b.updatedAtMs ?? _nowMs(),
      'updated_by_device': b.updatedByDevice ?? deviceId,
      'dirty': dirty ? 1 : 0,
      'deleted_at_ms': b.deletedAtMs,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> markBookmarkDeleted(String uuid) async {
    final db = await database;
    await db.update('local_bookmarks', {'deleted_at_ms': _nowMs(), 'dirty': 1},
        where: 'bookmark_uuid = ?', whereArgs: [uuid]);
  }

  static Future<List<Map<String, dynamic>>> getDirtyBookmarks() async {
    final db = await database;
    return db.query('local_bookmarks', where: 'dirty = 1');
  }

  static Future<void> clearBookmarkDirty(String uuid) async {
    final db = await database;
    await db.update('local_bookmarks', {'dirty': 0},
        where: 'bookmark_uuid = ?', whereArgs: [uuid]);
  }

  static Future<void> applyRemoteBookmark(Map<String, dynamic> row) async {
    final db = await database;
    final existing = await db.query('local_bookmarks',
        columns: ['updated_at_ms', 'dirty'],
        where: 'bookmark_uuid = ?', whereArgs: [row['bookmark_uuid']], limit: 1);
    if (existing.isNotEmpty) {
      final localMs = existing.first['updated_at_ms'] as int? ?? 0;
      final localDirty = (existing.first['dirty'] as int? ?? 0) == 1;
      final remoteMs = row['updated_at_ms'] as int? ?? 0;
      if (localDirty || localMs >= remoteMs) return;
    }
    await db.insert('local_bookmarks', {
      'bookmark_uuid': row['bookmark_uuid'],
      'doc_id': row['doc_id'],
      'page': row['page'],
      'label': row['label'] ?? '',
      'updated_at_ms': row['updated_at_ms'],
      'updated_by_device': row['updated_by_device'] ?? '',
      'dirty': 0,
      'deleted_at_ms': row['deleted_at_ms'],
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Bookmark _bookmarkFromRow(Map<String, dynamic> r) => Bookmark(
        bookmarkUuid: r['bookmark_uuid'] as String,
        docId: r['doc_id'] as String,
        page: r['page'] as int,
        label: r['label'] as String,
        updatedAtMs: r['updated_at_ms'] as int?,
        updatedByDevice: r['updated_by_device'] as String?,
        deletedAtMs: r['deleted_at_ms'] as int?,
      );
```

---

## BÖLÜM D — SYNC (`app/lib/sync_service.dart`)
`_pushDirty` ve `_pull`'a bookmarks'ı annotations gibi EKLE:
- `_pushDirty`: `final dirtyBookmarks = await LocalStore.getDirtyBookmarks();` → boşluk kontrolüne ekle; gövdeye `'bookmarks': dirtyBookmarks.map(_bookmarkPayload).toList()`; başarıdan sonra `clearBookmarkDirty`.
- `_bookmarkPayload`: `{bookmark_uuid, doc_id, page, label, updated_at_ms, updated_by_device, deleted_at_ms}`.
- `_pull`: `if (data['bookmarks'] != null) for (final b in data['bookmarks']) await LocalStore.applyRemoteBookmark(b);`

---

## BÖLÜM E — OKUYUCU (`app/lib/screens/reader_screen.dart`)

### E1. Yer imi state + yükleme
- `_load()` içinde annotations yüklenirken bookmarks'ı da yükle: `final bms = await LocalStore.getLocalBookmarks(widget.doc.id);` ve state'e koy: `List<Bookmark> _bookmarks = [];`.
- `int _strokeSeq` gibi `int _bmSeq = 0;`.

### E2. Yer imi ekle/sil + git
```dart
  Future<void> _toggleBookmark() async {
    final existing =
        _bookmarks.where((b) => b.page == _currentPage).toList();
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
      bookmarkUuid:
          'bm-${DateTime.now().microsecondsSinceEpoch}-${_bmSeq++}',
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
              .map((b) => ListTile(
                    leading: const Icon(Icons.bookmark),
                    title: Text(b.label),
                    subtitle: Text('Sayfa ${b.page}'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _controller.goToPage(pageNumber: b.page);
                    },
                  ))
              .toList(),
        );
      },
    );
  }
```

### E3. İçindekiler (outline)
```dart
  Future<void> _openOutline() async {
    final doc = _controller.document; // pdfrx: yuklenmis dokuman
    final outline = await doc.loadOutline();
    if (!mounted) return;
    if (outline.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('İçindekiler yok')));
      return;
    }
    // Agaci duzlestir (girinti ile)
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
            contentPadding:
                EdgeInsets.only(left: 16.0 + depth * 16, right: 16),
            title: Text(node.title ?? '', maxLines: 2,
                overflow: TextOverflow.ellipsis),
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
```
> **pdfrx API doğrulaması:** `_controller.document`, `document.loadOutline()`, `PdfOutlineNode.title/children/dest`, `dest.pageNumber` çağrıları kurulu pdfrx sürümünde farklıysa DUR ve doğru API'yi raporla. (Gerekirse `loadOutline` `PdfDocument` üzerinde; controller'dan dokümana erişim sürüme göre `_controller.documentRef`/`_controller.document` olabilir.)

### E4. ⋮ menüsüne / üst çubuğa girişler
`_readerMenu` itemBuilder'ına EKLE (onSelected'e karşılık gelen case'lerle):
```dart
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'bm_toggle', child: Text('Bu sayfayı yer imle')),
        const PopupMenuItem(value: 'bm_list', child: Text('Yer imleri')),
        const PopupMenuItem(value: 'outline', child: Text('İçindekiler')),
```
onSelected switch'e:
```dart
          case 'bm_toggle':
            _toggleBookmark();
          case 'bm_list':
            _openBookmarks();
          case 'outline':
            _openOutline();
```

---

## TEST
1. Bir PDF aç, ⋮ > "Bu sayfayı yer imle" → ⋮ > "Yer imleri" listede görünür, dokununca o sayfaya atlar.
2. Yer imini tekrar ekle/sil çalışır.
3. Offline ekle → online olunca başka cihazda görünür (sync).
4. ⋮ > "İçindekiler" → PDF'in TOC'u (varsa) listelenir, gezinme çalışır; yoksa "İçindekiler yok".
5. Sayfa-sync, çizim, regresyonsuz.

## DOĞRULAMA
- [ ] Yer imi ekle/sil/git çalışıyor, kalıcı
- [ ] Yer imleri çapraz cihaz sync
- [ ] Outline gezinme çalışıyor (TOC olan PDF'te)
- [ ] DB version 2 migration eski kurulumda local_bookmarks oluşturuyor
- [ ] Regresyon yok

```powershell
cd <PROJE> && git add -A && git commit -m "Faz 11: yer imleri (sync) + icindekiler"
```
