import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'models.dart';
import 'mevzuat_models.dart';

class LocalStore {
  static Database? _db;

  static Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'belgelik_local.db');
    await _migrateLegacyDbFile(dbPath, path);
    return openDatabase(
      path,
      version: 13,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  // Uygulamanin eski adindan kalan veritabani dosyasini (ve SQLite'in
  // -wal/-shm/-journal yan dosyalarini) yeni ada tasir. Yeni dosya zaten
  // varsa dokunmaz; boylece bir kez calisir.
  static Future<void> _migrateLegacyDbFile(String dbPath, String path) async {
    final legacy = p.join(dbPath, 'hakimlik_local.db');
    if (await File(path).exists() || !await File(legacy).exists()) return;
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final f = File('$legacy$suffix');
      if (await f.exists()) await f.rename('$path$suffix');
    }
  }

  // Mevzuat tam metin arama tablosu. DIKKAT: fts5 modulu yalnizca masaustu
  // (ffi) SQLite'inde, fts4 ise yalnizca Android'in yerlesik SQLite'inde var.
  // Ikisi ayni anda hicbir platformda bulunmuyor; bu yuzden once fts5 denenir,
  // olmazsa fts4'e dusulur. (fts5'in acilista migration icinde kosulsuz
  // calistirilmasi Android'de "no such module: fts5" ile acilis crash'ine
  // yol aciyordu.)
  static Future<void> _createLegislationFts(DatabaseExecutor db) async {
    try {
      await db.execute(
        'CREATE VIRTUAL TABLE IF NOT EXISTS local_legislation_fts USING fts5(mevzuat_no UNINDEXED, madde_ref UNINDEXED, content, tokenize = \'unicode61 remove_diacritics 2\')',
      );
    } catch (_) {
      await db.execute(
        'CREATE VIRTUAL TABLE IF NOT EXISTS local_legislation_fts USING fts4(mevzuat_no, madde_ref, content, notindexed=mevzuat_no, notindexed=madde_ref, tokenize=unicode61)',
      );
    }
  }

  // Yeni tablo/kolon eklerken version'i artir ve _onUpgrade'e ilgili
  // 'if (oldVersion < N)' blogunu ekle. _onCreate her zaman EN GUNCEL
  // semayi kurmalidir (yeni kurulumlar icin).
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute(
        'CREATE TABLE IF NOT EXISTS local_bookmarks (bookmark_uuid TEXT PRIMARY KEY, doc_id TEXT NOT NULL, page INTEGER NOT NULL, label TEXT NOT NULL DEFAULT \'\', updated_at_ms INTEGER NOT NULL, updated_by_device TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, deleted_at_ms INTEGER)',
      );
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE local_annotations ADD COLUMN text TEXT');
      await db.execute(
        'ALTER TABLE local_annotations ADD COLUMN font_size REAL',
      );
      await db.execute(
        'ALTER TABLE local_annotations ADD COLUMN font_family TEXT',
      );
    }
    if (oldVersion < 4) {
      await db.execute(
        'CREATE TABLE IF NOT EXISTS local_recent_hidden (doc_id TEXT PRIMARY KEY, hidden_at_ms INTEGER NOT NULL)',
      );
    }
    if (oldVersion < 5) {
      for (final stmt in [
        'ALTER TABLE pdf_docs ADD COLUMN page_count INTEGER',
        'ALTER TABLE pdf_docs ADD COLUMN current_page INTEGER',
      ]) {
        try {
          await db.execute(stmt);
        } catch (_) {}
      }
      await db.execute(
        'CREATE TABLE IF NOT EXISTS local_pomodoro_sessions (session_uuid TEXT PRIMARY KEY, date TEXT NOT NULL, subject TEXT NOT NULL, phase TEXT NOT NULL, minutes INTEGER NOT NULL, started_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, updated_by_device TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, deleted_at_ms INTEGER)',
      );
    }
    if (oldVersion < 6) {
      await db.execute(
        'CREATE TABLE IF NOT EXISTS local_subject_pdfs (subject TEXT NOT NULL, doc_id TEXT NOT NULL, PRIMARY KEY (subject, doc_id))',
      );
    }
    if (oldVersion < 7) {
      // Onbellege alinan dosyanin o anki sunucu 'modified' degeri. Ayni boyutta
      // farkli icerikle degisen PDF'i yakalamak icin (bkz. downloadPdf).
      try {
        await db.execute(
          'ALTER TABLE pdf_docs ADD COLUMN cached_modified INTEGER',
        );
      } catch (_) {}
    }
    if (oldVersion < 8) {
      await db.execute(
        'CREATE TABLE IF NOT EXISTS local_legislation_docs (mevzuat_no TEXT PRIMARY KEY, ad TEXT NOT NULL, kisa_ad TEXT NOT NULL, tur TEXT NOT NULL, snapshot_version TEXT NOT NULL, article_count INTEGER NOT NULL, downloaded_at_ms INTEGER NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE IF NOT EXISTS local_legislation_articles (id TEXT PRIMARY KEY, mevzuat_no TEXT NOT NULL, sira INTEGER NOT NULL, baslik TEXT NOT NULL, madde_no_raw TEXT NOT NULL, metin TEXT NOT NULL, metadata_json TEXT NOT NULL, snapshot_version TEXT NOT NULL)',
      );
      await _createLegislationFts(db);
      await db.execute(
        'CREATE TABLE IF NOT EXISTS local_legislation_positions (mevzuat_no TEXT PRIMARY KEY, madde_ref TEXT NOT NULL, updated_at_ms INTEGER NOT NULL, updated_by_device TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, deleted_at_ms INTEGER)',
      );
    }
    if (oldVersion < 9) {
      await db.execute(
        'CREATE TABLE IF NOT EXISTS local_madde_notes (note_uuid TEXT PRIMARY KEY, madde_ref TEXT NOT NULL, kind TEXT NOT NULL, renk INTEGER, secili_metin_araligi TEXT, text TEXT NOT NULL DEFAULT \'\', updated_at_ms INTEGER NOT NULL, updated_by_device TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, deleted_at_ms INTEGER)',
      );
    }
    if (oldVersion < 10) {
      await db.execute('CREATE TABLE IF NOT EXISTS local_legislation_changes (madde_ref TEXT NOT NULL, old_version TEXT NOT NULL, new_version TEXT NOT NULL, degisiklik_ozeti TEXT NOT NULL, old_text TEXT, new_text TEXT, created_at_ms INTEGER NOT NULL, PRIMARY KEY (madde_ref, old_version, new_version))');
    }
    if (oldVersion < 11) {
      // FTS tablosu bu platformda desteklenmeyen bir modulle kurulmus ya da
      // hic kurulamamis olabilir (fts5/fts4 ayrimi; ustteki nota bakin).
      // Destekleneni kur ve mevcut maddelerden yeniden doldur.
      try {
        final master = await db.rawQuery(
          "SELECT sql FROM sqlite_master WHERE name = 'local_legislation_fts' LIMIT 1",
        );
        final sql = master.isEmpty
            ? ''
            : (master.first['sql'] as String? ?? '').toLowerCase();
        var usable = false;
        if (sql.isNotEmpty) {
          try {
            await db.rawQuery('SELECT count(*) FROM local_legislation_fts');
            usable = true;
          } catch (_) {
            // Modul bu platformda yok; tablo dusurulup yeniden kurulacak.
          }
        }
        if (!usable) {
          if (sql.isNotEmpty) {
            try {
              await db.execute('DROP TABLE local_legislation_fts');
            } catch (_) {}
          }
          await _createLegislationFts(db);
          final articles = await db.query('local_legislation_articles');
          for (final a in articles) {
            await db.insert('local_legislation_fts', {
              'mevzuat_no': a['mevzuat_no'],
              'madde_ref': a['id'],
              'content': '${a['baslik'] ?? ''}\n${a['metin'] ?? ''}',
            });
          }
        }
      } catch (_) {
        // FTS kurulamazsa mevzuat aramasi calismaz ama uygulama acilmalidir.
      }
    }
    if (oldVersion < 13) {
      // Kart modulu sokuldu (2026-07-24): v12'de olusan yerel kart tablolari
      // dusurulur. v11 ve oncesinde tablolar hic olmadigi icin IF EXISTS yeter.
      for (final t in ['local_cards', 'local_review_state', 'local_review_log']) {
        await db.execute('DROP TABLE IF EXISTS $t');
      }
    }
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute(
      'CREATE TABLE pdf_docs (doc_id TEXT PRIMARY KEY, name TEXT NOT NULL, relative_path TEXT NOT NULL, size INTEGER NOT NULL, modified INTEGER NOT NULL, favorite INTEGER NOT NULL DEFAULT 0, local_file_path TEXT, local_file_size INTEGER, cached_at_ms INTEGER, cached_modified INTEGER, server_seen_at_ms INTEGER, deleted_at_ms INTEGER, page_count INTEGER, current_page INTEGER)',
    );
    await db.execute(
      'CREATE TABLE local_positions (doc_id TEXT PRIMARY KEY, page INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, updated_by_device TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, deleted_at_ms INTEGER)',
    );
    await db.execute(
      'CREATE TABLE local_annotations (stroke_uuid TEXT PRIMARY KEY, server_id INTEGER, doc_id TEXT NOT NULL, page INTEGER NOT NULL, kind TEXT NOT NULL, color INTEGER NOT NULL, width REAL NOT NULL, points TEXT NOT NULL, text TEXT, font_size REAL, font_family TEXT, updated_at_ms INTEGER NOT NULL, updated_by_device TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, deleted_at_ms INTEGER)',
    );
    await db.execute(
      'CREATE TABLE local_favorites (doc_id TEXT PRIMARY KEY, favorite INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, updated_by_device TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0)',
    );
    await db.execute(
      'CREATE TABLE local_recent (doc_id TEXT PRIMARY KEY, opened_at_ms INTEGER NOT NULL, updated_by_device TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0)',
    );
    await db.execute(
      'CREATE TABLE local_recent_hidden (doc_id TEXT PRIMARY KEY, hidden_at_ms INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE local_reading_goals (doc_id TEXT NOT NULL, date TEXT NOT NULL, start_page INTEGER NOT NULL, target_pages INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, updated_by_device TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, deleted_at_ms INTEGER, PRIMARY KEY (doc_id, date))',
    );
    await db.execute(
      'CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE pending_ops (id INTEGER PRIMARY KEY AUTOINCREMENT, op_type TEXT NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, payload TEXT NOT NULL, created_at_ms INTEGER NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0, last_error TEXT)',
    );
    await db.execute(
      'CREATE TABLE local_bookmarks (bookmark_uuid TEXT PRIMARY KEY, doc_id TEXT NOT NULL, page INTEGER NOT NULL, label TEXT NOT NULL DEFAULT \'\', updated_at_ms INTEGER NOT NULL, updated_by_device TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, deleted_at_ms INTEGER)',
    );
    await db.execute(
      'CREATE TABLE local_pomodoro_sessions (session_uuid TEXT PRIMARY KEY, date TEXT NOT NULL, subject TEXT NOT NULL, phase TEXT NOT NULL, minutes INTEGER NOT NULL, started_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, updated_by_device TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, deleted_at_ms INTEGER)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS local_subject_pdfs (subject TEXT NOT NULL, doc_id TEXT NOT NULL, PRIMARY KEY (subject, doc_id))',
    );
    await db.execute(
      'CREATE TABLE local_legislation_docs (mevzuat_no TEXT PRIMARY KEY, ad TEXT NOT NULL, kisa_ad TEXT NOT NULL, tur TEXT NOT NULL, snapshot_version TEXT NOT NULL, article_count INTEGER NOT NULL, downloaded_at_ms INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE local_legislation_articles (id TEXT PRIMARY KEY, mevzuat_no TEXT NOT NULL, sira INTEGER NOT NULL, baslik TEXT NOT NULL, madde_no_raw TEXT NOT NULL, metin TEXT NOT NULL, metadata_json TEXT NOT NULL, snapshot_version TEXT NOT NULL)',
    );
    await _createLegislationFts(db);
    await db.execute(
      'CREATE TABLE local_legislation_positions (mevzuat_no TEXT PRIMARY KEY, madde_ref TEXT NOT NULL, updated_at_ms INTEGER NOT NULL, updated_by_device TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, deleted_at_ms INTEGER)',
    );
    await db.execute(
      'CREATE TABLE local_madde_notes (note_uuid TEXT PRIMARY KEY, madde_ref TEXT NOT NULL, kind TEXT NOT NULL, renk INTEGER, secili_metin_araligi TEXT, text TEXT NOT NULL DEFAULT \'\', updated_at_ms INTEGER NOT NULL, updated_by_device TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, deleted_at_ms INTEGER)',
    );
    await db.execute('CREATE TABLE local_legislation_changes (madde_ref TEXT NOT NULL, old_version TEXT NOT NULL, new_version TEXT NOT NULL, degisiklik_ozeti TEXT NOT NULL, old_text TEXT, new_text TEXT, created_at_ms INTEGER NOT NULL, PRIMARY KEY (madde_ref, old_version, new_version))');
  }

  static Future<void> init() async {
    await database;
  }

  // NOT: Cakisma cozumu (last-write-wins) cihaz saatine dayanir. Cihazlarin
  // saatleri belirgin sekilde kayarsa "son yazan" yanlis secilebilir.
  // Tailscale cihazlari genelde NTP-senkron oldugu icin pratikte sorun olmaz.
  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  static String get deviceId => AppConfig.deviceId;

  // --- PDF docs ---
  static Future<void> upsertPdfDocs(List<PdfDoc> docs) async {
    final db = await database;
    final batch = db.batch();
    final now = _nowMs();
    for (final d in docs) {
      batch.rawInsert(
        '''
        INSERT INTO pdf_docs
          (doc_id, name, relative_path, size, modified, favorite, server_seen_at_ms, page_count, current_page)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(doc_id) DO UPDATE SET
          name = excluded.name,
          relative_path = excluded.relative_path,
          size = excluded.size,
          modified = excluded.modified,
          favorite = excluded.favorite,
          server_seen_at_ms = excluded.server_seen_at_ms,
          page_count = excluded.page_count,
          current_page = excluded.current_page
        ''',
        [
          d.id,
          d.name,
          d.relativePath,
          d.size,
          d.modified,
          d.favorite ? 1 : 0,
          now,
          d.pageCount,
          d.currentPage,
        ],
      );
    }
    await batch.commit(noResult: true);
  }

  static Future<List<PdfDoc>> listPdfDocs() async {
    final db = await database;
    final rows = await db.query(
      'pdf_docs',
      where: 'deleted_at_ms IS NULL',
      orderBy: 'name',
    );
    return rows.map(_pdfDocFromRow).toList();
  }

  /// Son okunan PDF'ler: local_positions'taki en guncel kayitlara gore sirali.
  /// Videolar sekmesindeki "Son acilan PDF'ler" bolumu icin kullanilir.
  static Future<List<PdfDoc>> recentPdfDocs({int limit = 12}) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT d.* FROM pdf_docs d
      JOIN local_positions p ON p.doc_id = d.doc_id
      WHERE d.deleted_at_ms IS NULL AND p.deleted_at_ms IS NULL
      ORDER BY p.updated_at_ms DESC
      LIMIT ?
      ''',
      [limit],
    );
    return rows.map(_pdfDocFromRow).toList();
  }

  static Future<void> markPdfCached(
    String docId,
    String filePath,
    int fileSize, {
    int? modified,
  }) async {
    final db = await database;
    await db.update(
      'pdf_docs',
      {
        'local_file_path': filePath,
        'local_file_size': fileSize,
        'cached_at_ms': _nowMs(),
      'cached_modified': modified,
      },
      where: 'doc_id = ?',
      whereArgs: [docId],
    );
  }

  /// Onbellekteki dosyanin kaydedildigi andaki sunucu 'modified' degeri.
  /// downloadPdf, guncel doc.modified ile karsilastirip bayat cache'i yeniler.
  static Future<int?> cachedPdfModified(String docId) async {
    final db = await database;
    final rows = await db.query(
      'pdf_docs',
      columns: ['cached_modified'],
      where: 'doc_id = ?',
      whereArgs: [docId],
    );
    if (rows.isEmpty) return null;
    return rows.first['cached_modified'] as int?;
  }

  static PdfDoc _pdfDocFromRow(Map<String, dynamic> r) => PdfDoc(
    id: r['doc_id'] as String,
    name: r['name'] as String,
    relativePath: r['relative_path'] as String,
    size: r['size'] as int,
    modified: r['modified'] as int,
    favorite: (r['favorite'] as int) == 1,
    localFilePath: r['local_file_path'] as String?,
    isCached: r['local_file_path'] != null,
    pageCount: r['page_count'] as int?,
    currentPage: r['current_page'] as int?,
  );

  // --- Position ---
  static Future<ReadingPosition?> getPosition(String docId) async {
    final db = await database;
    final rows = await db.query(
      'local_positions',
      where: 'doc_id = ? AND deleted_at_ms IS NULL',
      whereArgs: [docId],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return ReadingPosition(
      page: r['page'] as int,
      updatedAt: r['updated_at_ms'] as int,
      device: r['updated_by_device'] as String,
    );
  }

  static Future<void> putPosition(
    String docId,
    int page, {
    required bool dirty,
  }) async {
    final db = await database;
    await db.insert('local_positions', {
      'doc_id': docId,
      'page': page,
      'updated_at_ms': _nowMs(),
      'updated_by_device': deviceId,
      'dirty': dirty ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.update(
      'pdf_docs',
      {'current_page': page},
      where: 'doc_id = ?',
      whereArgs: [docId],
    );
  }

  static Future<List<Map<String, dynamic>>> getDirtyPositions() async {
    final db = await database;
    return db.query('local_positions', where: 'dirty = 1');
  }

  static Future<void> clearPositionDirty(String docId) async {
    final db = await database;
    await db.update(
      'local_positions',
      {'dirty': 0},
      where: 'doc_id = ?',
      whereArgs: [docId],
    );
  }

  static Future<void> applyRemotePosition(Map<String, dynamic> row) async {
    final db = await database;
    await db.insert('local_positions', {
      'doc_id': row['doc_id'],
      'page': row['page'],
      'updated_at_ms': row['updated_at_ms'],
      'updated_by_device': row['updated_by_device'] ?? '',
      'dirty': 0,
      'deleted_at_ms': row['deleted_at_ms'],
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.update(
      'pdf_docs',
      {'current_page': row['page']},
      where: 'doc_id = ?',
      whereArgs: [row['doc_id']],
    );
  }

  // --- Annotations ---
  static Future<List<Stroke>> getLocalAnnotations(String docId) async {
    final db = await database;
    final rows = await db.query(
      'local_annotations',
      where: 'doc_id = ? AND deleted_at_ms IS NULL',
      whereArgs: [docId],
    );
    return rows.map(_strokeFromRow).toList();
  }

  static Future<void> upsertStroke(
    Stroke stroke,
    String docId, {
    required bool dirty,
  }) async {
    final db = await database;
    await db.insert(
      'local_annotations',
      _strokeToRow(stroke, docId, dirty),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> markStrokeDeleted(String strokeUuid) async {
    final db = await database;
    final now = _nowMs();
    // updated_at_ms ilerletilmezse sunucu LWW karsilastirmasi eski kaydi
    // "daha yeni" sayip silmeyi reddedebilir (not geri gelir).
    await db.update(
      'local_annotations',
      {
        'deleted_at_ms': now,
        'updated_at_ms': now,
        'updated_by_device': deviceId,
        'dirty': 1,
      },
      where: 'stroke_uuid = ?',
      whereArgs: [strokeUuid],
    );
  }

  static Future<List<Map<String, dynamic>>> getDirtyAnnotations() async {
    final db = await database;
    return db.query('local_annotations', where: 'dirty = 1');
  }

  static Future<void> clearAnnotationDirty(String strokeUuid) async {
    final db = await database;
    await db.update(
      'local_annotations',
      {'dirty': 0},
      where: 'stroke_uuid = ?',
      whereArgs: [strokeUuid],
    );
  }

  static Future<void> applyRemoteAnnotation(Map<String, dynamic> row) async {
    final db = await database;
    // Yerel kayit dirty (push edilmemis) ya da daha yeniyse ezme
    final existing = await db.query(
      'local_annotations',
      columns: ['updated_at_ms', 'dirty'],
      where: 'stroke_uuid = ?',
      whereArgs: [row['stroke_uuid']],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final localMs = existing.first['updated_at_ms'] as int? ?? 0;
      final localDirty = (existing.first['dirty'] as int? ?? 0) == 1;
      final remoteMs = row['updated_at_ms'] as int? ?? 0;
      if (localDirty || localMs >= remoteMs) return;
    }
    final deletedAt = row['deleted_at_ms'];
    await db.insert('local_annotations', {
      'stroke_uuid': row['stroke_uuid'],
      'server_id': row['id'],
      'doc_id': row['doc_id'],
      'page': row['page'],
      'kind': row['kind'],
      'color': row['color'],
      'width': row['width'],
      'points': jsonEncode(row['points']),
      'text': row['text'],
      'font_size': row['font_size'],
      'font_family': row['font_family'],
      'updated_at_ms': row['updated_at_ms'],
      'updated_by_device': row['updated_by_device'] ?? '',
      'dirty': 0,
      'deleted_at_ms': deletedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Stroke _strokeFromRow(Map<String, dynamic> r) {
    final (pts, pressures) = Stroke.decodePoints(
      jsonDecode(r['points'] as String) as List,
    );
    return Stroke(
    strokeUuid: r['stroke_uuid'] as String,
    id: r['server_id'] as int?,
    page: r['page'] as int,
    kind: r['kind'] as String,
    color: r['color'] as int,
    width: (r['width'] as num).toDouble(),
    points: pts,
    pressures: pressures,
    text: r['text'] as String?,
    fontSize: (r['font_size'] as num?)?.toDouble(),
    fontFamily: r['font_family'] as String?,
    updatedAtMs: r['updated_at_ms'] as int?,
    updatedByDevice: r['updated_by_device'] as String?,
    );
  }

  static Map<String, dynamic> _strokeToRow(
    Stroke s,
    String docId,
    bool dirty,
  ) => {
    'stroke_uuid': s.strokeUuid,
    'server_id': s.id,
    'doc_id': docId,
    'page': s.page,
    'kind': s.kind,
    'color': s.color,
    'width': s.width,
    'points': jsonEncode(s.encodePoints()),
    'text': s.text,
    'font_size': s.fontSize,
    'font_family': s.fontFamily,
    'updated_at_ms': s.updatedAtMs ?? _nowMs(),
    'updated_by_device': s.updatedByDevice ?? deviceId,
    'dirty': dirty ? 1 : 0,
    'deleted_at_ms': s.deletedAtMs,
  };

  // --- Favorites ---
  static Future<void> setFavorite(
    String docId,
    bool favorite, {
    required bool dirty,
  }) async {
    final db = await database;
    await db.insert('local_favorites', {
      'doc_id': docId,
      'favorite': favorite ? 1 : 0,
      'updated_at_ms': _nowMs(),
      'updated_by_device': deviceId,
      'dirty': dirty ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    // Also update pdf_docs
    await db.update(
      'pdf_docs',
      {'favorite': favorite ? 1 : 0},
      where: 'doc_id = ?',
      whereArgs: [docId],
    );
  }

  static Future<List<Map<String, dynamic>>> getDirtyFavorites() async {
    final db = await database;
    return db.query('local_favorites', where: 'dirty = 1');
  }

  static Future<void> clearFavoriteDirty(String docId) async {
    final db = await database;
    await db.update(
      'local_favorites',
      {'dirty': 0},
      where: 'doc_id = ?',
      whereArgs: [docId],
    );
  }

  static Future<void> applyRemoteFavorite(Map<String, dynamic> row) async {
    final db = await database;
    final existing = await db.query(
      'local_favorites',
      columns: ['updated_at_ms', 'dirty'],
      where: 'doc_id = ?',
      whereArgs: [row['doc_id']],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final localMs = existing.first['updated_at_ms'] as int? ?? 0;
      final localDirty = (existing.first['dirty'] as int? ?? 0) == 1;
      final remoteMs = row['updated_at_ms'] as int? ?? 0;
      if (localDirty || localMs >= remoteMs) return;
    }
    final favorite = row['favorite'] == true || row['favorite'] == 1;
    await db.insert('local_favorites', {
      'doc_id': row['doc_id'],
      'favorite': favorite ? 1 : 0,
      'updated_at_ms': row['updated_at_ms'],
      'updated_by_device': row['updated_by_device'] ?? '',
      'dirty': 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.update(
      'pdf_docs',
      {'favorite': favorite ? 1 : 0},
      where: 'doc_id = ?',
      whereArgs: [row['doc_id']],
    );
  }

  // --- Recent ---
  static Future<void> markRecent(String docId) async {
    final db = await database;
    await db.delete(
      'local_recent_hidden',
      where: 'doc_id = ?',
      whereArgs: [docId],
    );
    await db.insert('local_recent', {
      'doc_id': docId,
      'opened_at_ms': _nowMs(),
      'updated_by_device': deviceId,
      'dirty': 1,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, dynamic>>> getDirtyRecent() async {
    final db = await database;
    return db.query('local_recent', where: 'dirty = 1');
  }

  static Future<void> clearRecentDirty(String docId) async {
    final db = await database;
    await db.update(
      'local_recent',
      {'dirty': 0},
      where: 'doc_id = ?',
      whereArgs: [docId],
    );
  }

  static Future<void> removeRecent(String docId) async {
    final db = await database;
    await db.delete('local_recent', where: 'doc_id = ?', whereArgs: [docId]);
    await db.insert('local_recent_hidden', {
      'doc_id': docId,
      'hidden_at_ms': _nowMs(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> applyRemoteRecent(Map<String, dynamic> row) async {
    final db = await database;
    final existing = await db.query(
      'local_recent',
      columns: ['opened_at_ms', 'dirty'],
      where: 'doc_id = ?',
      whereArgs: [row['doc_id']],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final localMs = existing.first['opened_at_ms'] as int? ?? 0;
      final localDirty = (existing.first['dirty'] as int? ?? 0) == 1;
      final remoteMs = row['opened_at_ms'] as int? ?? 0;
      if (localDirty || localMs >= remoteMs) return;
    }
    final hidden = await db.query(
      'local_recent_hidden',
      where: 'doc_id = ?',
      whereArgs: [row['doc_id']],
      limit: 1,
    );
    if (hidden.isNotEmpty) return;
    await db.insert('local_recent', {
      'doc_id': row['doc_id'],
      'opened_at_ms': row['opened_at_ms'],
      'updated_by_device': row['updated_by_device'] ?? '',
      'dirty': 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<PdfDoc>> getRecent({int limit = 5}) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT p.* FROM local_recent r JOIN pdf_docs p ON r.doc_id = p.doc_id LEFT JOIN local_recent_hidden h ON h.doc_id = r.doc_id WHERE p.deleted_at_ms IS NULL AND h.doc_id IS NULL ORDER BY r.opened_at_ms DESC LIMIT ?',
      [limit],
    );
    return rows.map(_pdfDocFromRow).toList();
  }

  // --- Reading goals ---
  static Future<ReadingGoal?> getReadingGoal(
    String docId,
    DateTime date,
  ) async {
    final db = await database;
    final dateKey = date.toIso8601String().substring(0, 10);
    final rows = await db.query(
      'local_reading_goals',
      where: 'doc_id = ? AND date = ? AND deleted_at_ms IS NULL',
      whereArgs: [docId, dateKey],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return ReadingGoal(
      docId: r['doc_id'] as String,
      date: r['date'] as String,
      startPage: r['start_page'] as int,
      targetPages: r['target_pages'] as int,
      updatedAtMs: r['updated_at_ms'] as int?,
      updatedByDevice: r['updated_by_device'] as String?,
      deletedAtMs: r['deleted_at_ms'] as int?,
    );
  }

  static Future<ReadingGoal> putReadingGoal(
    String docId,
    DateTime date,
    int startPage,
    int targetPages, {
    required bool dirty,
  }) async {
    final db = await database;
    final dateKey = date.toIso8601String().substring(0, 10);
    final updatedAtMs = _nowMs();
    await db.insert('local_reading_goals', {
      'doc_id': docId,
      'date': dateKey,
      'start_page': startPage,
      'target_pages': targetPages,
      'updated_at_ms': updatedAtMs,
      'updated_by_device': deviceId,
      'dirty': dirty ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return ReadingGoal(
      docId: docId,
      date: dateKey,
      startPage: startPage,
      targetPages: targetPages,
      updatedAtMs: updatedAtMs,
      updatedByDevice: deviceId,
    );
  }

  static Future<void> upsertReadingGoal(
    ReadingGoal goal, {
    required bool dirty,
  }) async {
    final db = await database;
    await db.insert('local_reading_goals', {
      'doc_id': goal.docId,
      'date': goal.date,
      'start_page': goal.startPage,
      'target_pages': goal.targetPages,
      'updated_at_ms': goal.updatedAtMs ?? _nowMs(),
      'updated_by_device': goal.updatedByDevice ?? deviceId,
      'dirty': dirty ? 1 : 0,
      'deleted_at_ms': goal.deletedAtMs,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, dynamic>>> getDirtyReadingGoals() async {
    final db = await database;
    return db.query('local_reading_goals', where: 'dirty = 1');
  }

  static Future<void> clearReadingGoalDirty(String docId, String date) async {
    final db = await database;
    await db.update(
      'local_reading_goals',
      {'dirty': 0},
      where: 'doc_id = ? AND date = ?',
      whereArgs: [docId, date],
    );
  }

  static Future<String?> getSyncState(String key) async {
    final db = await database;
    final rows = await db.query(
      'sync_state',
      where: 'key = ?',
      whereArgs: [key],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  static Future<void> setSyncState(String key, String value) async {
    final db = await database;
    await db.insert('sync_state', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // --- Offline mevzuat ---
  static Future<List<LegislationSummary>> listLegislation() async {
    final db = await database;
    final rows = await db.query('local_legislation_docs', orderBy: 'ad COLLATE NOCASE');
    return rows.map((r) => LegislationSummary.fromJson({...r, 'size': 0})).toList();
  }

  static Future<LegislationSummary?> getLegislation(String lawNo) async {
    final db = await database;
    final rows = await db.query('local_legislation_docs', where: 'mevzuat_no = ?', whereArgs: [lawNo], limit: 1);
    return rows.isEmpty ? null : LegislationSummary.fromJson({...rows.first, 'size': 0});
  }

  static Future<void> installLegislation(Map<String, dynamic> bundle) async {
    final law = (bundle['mevzuat'] as Map).cast<String, dynamic>();
    final articles = (bundle['articles'] as List).cast<Map>();
    final db = await database;
    await db.transaction((tx) async {
      await tx.delete('local_legislation_fts', where: 'mevzuat_no = ?', whereArgs: [law['mevzuat_no']]);
      await tx.delete('local_legislation_articles', where: 'mevzuat_no = ?', whereArgs: [law['mevzuat_no']]);
      await tx.delete('local_legislation_changes', where: 'madde_ref LIKE ?', whereArgs: ['${law['mevzuat_no']}/%']);
      await tx.insert('local_legislation_docs', {
        'mevzuat_no': law['mevzuat_no'], 'ad': law['ad'], 'kisa_ad': law['kisa_ad'] ?? '',
        'tur': law['tur'] ?? 'Kanun', 'snapshot_version': law['snapshot_version'],
        'article_count': articles.length, 'downloaded_at_ms': _nowMs(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      for (final raw in articles) {
        final a = raw.cast<String, dynamic>();
        final metadata = (a['metadata'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
        await tx.insert('local_legislation_articles', {
          'id': a['id'], 'mevzuat_no': law['mevzuat_no'], 'sira': a['sira'], 'baslik': a['baslik'] ?? '',
          'madde_no_raw': a['madde_no_raw'] ?? '', 'metin': a['metin'] ?? '',
          'metadata_json': jsonEncode(metadata), 'snapshot_version': a['snapshot_version'] ?? law['snapshot_version'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await tx.insert('local_legislation_fts', {'mevzuat_no': law['mevzuat_no'], 'madde_ref': a['id'], 'content': '${a['baslik'] ?? ''}\n${a['metin'] ?? ''}' });
      }
      for (final raw in ((bundle['changes'] as List?) ?? const [])) {
        final c = (raw as Map).cast<String, dynamic>();
        await tx.insert('local_legislation_changes', {'madde_ref': c['madde_ref'], 'old_version': c['old_version'], 'new_version': c['new_version'], 'degisiklik_ozeti': c['degisiklik_ozeti'], 'old_text': c['old_text'], 'new_text': c['new_text'], 'created_at_ms': c['created_at_ms']}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  static Future<void> deleteLegislation(String lawNo) async {
    final db = await database;
    await db.transaction((tx) async {
      await tx.delete('local_legislation_fts', where: 'mevzuat_no = ?', whereArgs: [lawNo]);
      await tx.delete('local_legislation_articles', where: 'mevzuat_no = ?', whereArgs: [lawNo]);
      await tx.delete('local_legislation_docs', where: 'mevzuat_no = ?', whereArgs: [lawNo]);
      await tx.delete('local_legislation_positions', where: 'mevzuat_no = ?', whereArgs: [lawNo]);
      await tx.delete('local_legislation_changes', where: 'madde_ref LIKE ?', whereArgs: ['$lawNo/%']);
    });
  }

  static Future<List<LegislationArticle>> listLegislationArticles(String lawNo) async {
    final db = await database;
    final rows = await db.query('local_legislation_articles', where: 'mevzuat_no = ?', whereArgs: [lawNo], orderBy: 'sira');
    return rows.map(LegislationArticle.fromRow).toList();
  }

  static Future<LegislationArticle?> getLegislationArticle(String ref) async {
    final db = await database;
    final rows = await db.query('local_legislation_articles', where: 'id = ?', whereArgs: [ref], limit: 1);
    return rows.isEmpty ? null : LegislationArticle.fromRow(rows.first);
  }

  static Future<List<LegislationChange>> listLegislationChanges(String lawNo) async {
    final db = await database;
    final rows = await db.query('local_legislation_changes', where: 'madde_ref LIKE ?', whereArgs: ['$lawNo/%'], orderBy: 'created_at_ms DESC');
    return rows.map(LegislationChange.fromJson).toList();
  }

  static Future<LegislationChange?> changeForArticle(String ref) async {
    final db = await database;
    final rows = await db.query('local_legislation_changes', where: 'madde_ref = ?', whereArgs: [ref], orderBy: 'created_at_ms DESC', limit: 1);
    return rows.isEmpty ? null : LegislationChange.fromJson(rows.first);
  }

  static Future<List<Map<String, dynamic>>> searchLegislation(String query) async {
    // Harf/rakam disindaki karakterleri at: hem fts5 hem fts4 sorgu
    // sozdiziminde ozel anlam tasiyabilirler.
    final words = query
        .trim()
        .split(RegExp(r'\s+'))
        .map((e) => e.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), ''))
        .where((e) => e.isNotEmpty)
        .toList();
    if (words.isEmpty) return const [];
    final db = await database;
    // Tablo fts5 mi fts4 mu? (Masaustunde fts5, Android'de fts4 kurulur;
    // snippet() imzalari ve siralama destegi farklidir.)
    final master = await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE name = 'local_legislation_fts' LIMIT 1",
    );
    if (master.isEmpty) return const [];
    final fts5 =
        (master.first['sql'] as String? ?? '').toLowerCase().contains('fts5');
    // Bosluk iki sozdiziminde de ortuk AND'dir; on-ek icin sona '*'.
    final terms = fts5
        ? words.map((w) => '"$w"*').join(' ')
        : words.map((w) => '$w*').join(' ');
    final snippetExpr = fts5
        ? "snippet(local_legislation_fts, 2, '[', ']', '…', 12)"
        : "snippet(local_legislation_fts, '[', ']', '…', 2, 12)";
    final orderBy = fts5 ? 'ORDER BY rank' : '';
    return db.rawQuery(
      'SELECT mevzuat_no, madde_ref, $snippetExpr AS snippet FROM local_legislation_fts WHERE local_legislation_fts MATCH ? $orderBy LIMIT 100',
      [terms],
    );
  }

  static Future<List<Map<String, dynamic>>> getDirtyLegislationPositions() async {
    final db = await database;
    return db.query('local_legislation_positions', where: 'dirty = 1');
  }

  static Future<void> putLegislationPosition(String lawNo, String ref, {required bool dirty}) async {
    final db = await database;
    await db.insert('local_legislation_positions', {'mevzuat_no': lawNo, 'madde_ref': ref, 'updated_at_ms': _nowMs(), 'updated_by_device': deviceId, 'dirty': dirty ? 1 : 0}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> clearLegislationPositionDirty(String lawNo) async {
    final db = await database;
    await db.update('local_legislation_positions', {'dirty': 0}, where: 'mevzuat_no = ?', whereArgs: [lawNo]);
  }

  static Future<void> applyRemoteLegislationPosition(Map<String, dynamic> row) async {
    final db = await database;
    await db.insert('local_legislation_positions', {...row, 'dirty': 0}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // --- Madde notları ---
  static Future<List<MaddeNote>> listMaddeNotes(String lawNo, {String? kind}) async {
    final db = await database;
    final where = <String>['madde_ref LIKE ?', 'deleted_at_ms IS NULL'];
    final args = <Object?>['$lawNo/%'];
    if (kind != null) { where.add('kind = ?'); args.add(kind); }
    final rows = await db.query('local_madde_notes', where: where.join(' AND '), whereArgs: args, orderBy: 'updated_at_ms DESC');
    return rows.map(MaddeNote.fromRow).toList();
  }

  static Future<List<MaddeNote>> notesForArticle(String maddeRef) async {
    final db = await database;
    final rows = await db.query('local_madde_notes', where: 'madde_ref = ? AND deleted_at_ms IS NULL', whereArgs: [maddeRef], orderBy: 'updated_at_ms DESC');
    return rows.map(MaddeNote.fromRow).toList();
  }

  static Future<void> upsertMaddeNote(MaddeNote note, {required bool dirty}) async {
    final db = await database;
    await db.insert('local_madde_notes', {'note_uuid': note.noteUuid, 'madde_ref': note.maddeRef, 'kind': note.kind, 'renk': note.renk, 'secili_metin_araligi': note.seciliMetinAraligi, 'text': note.text, 'updated_at_ms': note.updatedAtMs, 'updated_by_device': note.updatedByDevice, 'dirty': dirty ? 1 : 0, 'deleted_at_ms': note.deletedAtMs}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> markMaddeNoteDeleted(String uuid) async {
    final db = await database;
    final now = _nowMs();
    await db.update('local_madde_notes', {'deleted_at_ms': now, 'updated_at_ms': now, 'updated_by_device': deviceId, 'dirty': 1}, where: 'note_uuid = ?', whereArgs: [uuid]);
  }

  static Future<List<Map<String, dynamic>>> getDirtyMaddeNotes() async => (await database).query('local_madde_notes', where: 'dirty = 1');
  static Future<void> clearMaddeNoteDirty(String uuid) async => (await database).update('local_madde_notes', {'dirty': 0}, where: 'note_uuid = ?', whereArgs: [uuid]);
  static Future<void> applyRemoteMaddeNote(Map<String, dynamic> row) async {
    final db = await database;
    final existing = await db.query('local_madde_notes', columns: ['updated_at_ms', 'dirty'], where: 'note_uuid = ?', whereArgs: [row['note_uuid']], limit: 1);
    if (existing.isNotEmpty && ((existing.first['dirty'] as int? ?? 0) == 1 || (existing.first['updated_at_ms'] as int? ?? 0) >= (row['updated_at_ms'] as int? ?? 0))) return;
    await db.insert('local_madde_notes', {...row, 'dirty': 0}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<int> pendingCount() async {
    final db = await database;
    const tables = [
      'local_positions',
      'local_annotations',
      'local_favorites',
      'local_recent',
      'local_reading_goals',
      'local_bookmarks',
      'local_pomodoro_sessions',
      'local_madde_notes',
    ];
    var total = 0;
    for (final t in tables) {
      try {
        final rows = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM $t WHERE dirty = 1',
        );
        total += (rows.first['c'] as int?) ?? 0;
      } catch (_) {}
    }
    return total;
  }

  static Future<void> applyRemoteDeletedDoc(Map<String, dynamic> row) async {
    final db = await database;
    final docId = row['doc_id'] as String;
    final deletedAtMs =
        row['deleted_at_ms'] as int? ?? DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    batch.update(
      'pdf_docs',
      {'deleted_at_ms': deletedAtMs},
      where: 'doc_id = ?',
      whereArgs: [docId],
    );
    batch.delete('local_positions', where: 'doc_id = ?', whereArgs: [docId]);
    batch.delete('local_annotations', where: 'doc_id = ?', whereArgs: [docId]);
    batch.delete('local_favorites', where: 'doc_id = ?', whereArgs: [docId]);
    batch.delete('local_recent', where: 'doc_id = ?', whereArgs: [docId]);
    batch.delete(
      'local_reading_goals',
      where: 'doc_id = ?',
      whereArgs: [docId],
    );
    batch.delete('local_bookmarks', where: 'doc_id = ?', whereArgs: [docId]);
    await batch.commit(noResult: true);
  }

  // --- Pomodoro sessions ---
  static Future<void> upsertPomodoroSession(
    PomodoroSession session, {
    required bool dirty,
  }) async {
    final db = await database;
    await db.insert('local_pomodoro_sessions', {
      'session_uuid': session.sessionUuid,
      'date': session.date,
      'subject': session.subject,
      'phase': session.phase,
      'minutes': session.minutes,
      'started_at_ms': session.startedAtMs,
      'updated_at_ms': session.updatedAtMs ?? _nowMs(),
      'updated_by_device': session.updatedByDevice ?? deviceId,
      'dirty': dirty ? 1 : 0,
      'deleted_at_ms': session.deletedAtMs,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, dynamic>>> getDirtyPomodoroSessions() async {
    final db = await database;
    return db.query('local_pomodoro_sessions', where: 'dirty = 1');
  }

  static Future<void> clearPomodoroDirty(String uuid) async {
    final db = await database;
    await db.update(
      'local_pomodoro_sessions',
      {'dirty': 0},
      where: 'session_uuid = ?',
      whereArgs: [uuid],
    );
  }

  static Future<void> applyRemotePomodoroSession(
    Map<String, dynamic> row,
  ) async {
    final db = await database;
    final existing = await db.query(
      'local_pomodoro_sessions',
      columns: ['updated_at_ms', 'dirty'],
      where: 'session_uuid = ?',
      whereArgs: [row['session_uuid']],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final localMs = existing.first['updated_at_ms'] as int? ?? 0;
      final localDirty = (existing.first['dirty'] as int? ?? 0) == 1;
      final remoteMs = row['updated_at_ms'] as int? ?? 0;
      if (localDirty || localMs >= remoteMs) return;
    }
    await db.insert('local_pomodoro_sessions', {
      'session_uuid': row['session_uuid'],
      'date': row['date'],
      'subject': row['subject'],
      'phase': row['phase'],
      'minutes': row['minutes'],
      'started_at_ms': row['started_at_ms'],
      'updated_at_ms': row['updated_at_ms'],
      'updated_by_device': row['updated_by_device'] ?? '',
      'dirty': 0,
      'deleted_at_ms': row['deleted_at_ms'],
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<PomodoroSession>> listPomodoroSessions({
    String? fromDate,
    String? toDate,
  }) async {
    final db = await database;
    final where = <String>['deleted_at_ms IS NULL'];
    final args = <Object?>[];
    if (fromDate != null) {
      where.add('date >= ?');
      args.add(fromDate);
    }
    if (toDate != null) {
      where.add('date <= ?');
      args.add(toDate);
    }
    final rows = await db.query(
      'local_pomodoro_sessions',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'date DESC, started_at_ms DESC',
    );
    return rows
        .map(
          (r) => PomodoroSession(
            sessionUuid: r['session_uuid'] as String,
            date: r['date'] as String,
            subject: r['subject'] as String,
            phase: r['phase'] as String,
            minutes: r['minutes'] as int,
            startedAtMs: r['started_at_ms'] as int,
            updatedAtMs: r['updated_at_ms'] as int?,
            updatedByDevice: r['updated_by_device'] as String?,
            deletedAtMs: r['deleted_at_ms'] as int?,
          ),
        )
        .toList();
  }

  static Future<int> pagesReadOn(DateTime date) async {
    final db = await database;
    final key = date.toIso8601String().substring(0, 10);
    final rows = await db.rawQuery(
      '''
      SELECT SUM(
        CASE
          WHEN p.page IS NULL THEN 0
          WHEN p.page <= g.start_page THEN 0
          WHEN p.page - g.start_page > g.target_pages THEN g.target_pages
          ELSE p.page - g.start_page
        END
      ) AS pages
      FROM local_reading_goals g
      LEFT JOIN local_positions p ON p.doc_id = g.doc_id
      WHERE g.date = ? AND g.deleted_at_ms IS NULL
      ''',
      [key],
    );
    return (rows.first['pages'] as int?) ?? 0;
  }

  // --- Bookmarks ---
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
    await db.update(
      'local_bookmarks',
      {'deleted_at_ms': _nowMs(), 'dirty': 1},
      where: 'bookmark_uuid = ?',
      whereArgs: [uuid],
    );
  }

  static Future<List<Map<String, dynamic>>> getDirtyBookmarks() async {
    final db = await database;
    return db.query('local_bookmarks', where: 'dirty = 1');
  }

  static Future<void> clearBookmarkDirty(String uuid) async {
    final db = await database;
    await db.update(
      'local_bookmarks',
      {'dirty': 0},
      where: 'bookmark_uuid = ?',
      whereArgs: [uuid],
    );
  }

  static Future<void> applyRemoteBookmark(Map<String, dynamic> row) async {
    final db = await database;
    final existing = await db.query(
      'local_bookmarks',
      columns: ['updated_at_ms', 'dirty'],
      where: 'bookmark_uuid = ?',
      whereArgs: [row['bookmark_uuid']],
      limit: 1,
    );
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

  static Future<void> associatePdfWithSubject(
    String subject,
    String docId,
  ) async {
    final db = await database;
    await db.insert('local_subject_pdfs', {
      'subject': subject,
      'doc_id': docId,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> removePdfFromSubject(String subject, String docId) async {
    final db = await database;
    await db.delete(
      'local_subject_pdfs',
      where: 'subject = ? AND doc_id = ?',
      whereArgs: [subject, docId],
    );
  }

  static Future<List<PdfDoc>> getAssociatedPdfsForSubject(
    String subject,
  ) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT p.*
      FROM local_subject_pdfs s
      JOIN pdf_docs p ON p.doc_id = s.doc_id
      WHERE s.subject = ? AND p.deleted_at_ms IS NULL
      ORDER BY p.name
      ''',
      [subject],
    );
    return rows.map(_pdfDocFromRow).toList();
  }
}
