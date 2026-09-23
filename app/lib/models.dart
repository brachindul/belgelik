import 'dart:ui';

class PdfDoc {
  final String id;
  final String name;
  final String relativePath;
  final int size;
  final int modified;
  final bool favorite;
  final String? localFilePath;
  final bool isCached;
  final int? pageCount;
  final int? currentPage;
  // Sunucu ogelerin turu: "pdf" (varsayilan) veya "note". /library ve /pdfs
  // yanitlari notlari da icerir; app bunu okuyup notlari PDF listesinden
  // ayirir (Bolum 3). Eski sunucular alan gondermeyebilir -> "pdf" kabul et.
  final String kind;

  PdfDoc({
    required this.id,
    required this.name,
    required this.relativePath,
    required this.size,
    required this.modified,
    required this.favorite,
    this.localFilePath,
    this.isCached = false,
    this.pageCount,
    this.currentPage,
    this.kind = 'pdf',
  });

  factory PdfDoc.fromJson(Map<String, dynamic> json) => PdfDoc(
    id: json['id'] as String,
    name: json['name'] as String,
    relativePath: json['relative_path'] as String,
    size: json['size'] as int,
    modified: json['modified'] as int,
    favorite: (json['favorite'] as bool?) ?? false,
    localFilePath: json['local_file_path'] as String?,
    isCached: json['local_file_path'] != null,
    pageCount: json['page_count'] as int?,
    currentPage: json['current_page'] as int?,
    kind: (json['kind'] as String?) ?? 'pdf',
  );
}

// --- Not belgeleri (Faz E) ---
//
// Bir not = sunucuda .belge uzantili JSON dosyasi; PDF'lerle ayni klasorde.
// Sunucu blok yapisini dogrulamaz -> semayi app belirler (Bolum 2).
// Metin bloklari "spans" dizisi tasiyabilir; v1 editor blok-düzeyi stil icin
// tek span kullanir (blokun tum metnine ayni stil uygulanir).

/// Not listesi ogesi: GET /notes ve /library yanitindaki kind=="note" ogeler.
/// Tam icerik (blocks) icin getNote(id) ile NoteDoc cekilir.
class NoteListItem {
  final String id;
  final String name;
  final String relativePath;
  final int size;
  final int modified;
  final String title;

  NoteListItem({
    required this.id,
    required this.name,
    required this.relativePath,
    required this.size,
    required this.modified,
    required this.title,
  });

  factory NoteListItem.fromJson(Map<String, dynamic> json) => NoteListItem(
    id: json['id'] as String,
    name: json['name'] as String,
    relativePath: json['relative_path'] as String,
    size: json['size'] as int,
    modified: json['modified'] as int,
    title: (json['title'] as String?) ?? '',
  );

  /// Gosterim adi: once title (kullanicinin yazdigi), bossa dosya adi.
  String get displayName => title.trim().isNotEmpty ? title.trim() : name;
}

/// Metin bloku icin hizalama. Sunucuya "left"|"center"|"right" olarak yazilir.
enum NoteAlign { left, center, right }

String _alignToJson(NoteAlign a) {
  switch (a) {
    case NoteAlign.center:
      return 'center';
    case NoteAlign.right:
      return 'right';
    case NoteAlign.left:
      return 'left';
  }
}

NoteAlign _alignFromJson(String? s) {
  switch (s) {
    case 'center':
      return NoteAlign.center;
    case 'right':
      return NoteAlign.right;
    default:
      return NoteAlign.left;
  }
}

/// Metin bloku icin tek bir metin parcasi ve bicimi. v1'de blok basina tek
/// span kullanilir (blok-düzeyi stil). color ARGB int (Stroke.color ile ayni).
class TextSpanModel {
  String text;
  bool bold;
  bool italic;
  bool underline;
  int color;
  double size;

  TextSpanModel({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.color = 0xFF111827,
    this.size = 18.0,
  });

  factory TextSpanModel.fromJson(Map<String, dynamic> j) => TextSpanModel(
    text: (j['text'] as String?) ?? '',
    bold: (j['bold'] as bool?) ?? false,
    italic: (j['italic'] as bool?) ?? false,
    underline: (j['underline'] as bool?) ?? false,
    color: (j['color'] as int?) ?? 0xFF111827,
    size: (j['size'] as num?)?.toDouble() ?? 18.0,
  );

  Map<String, dynamic> toJson() => {
    'text': text,
    'bold': bold,
    'italic': italic,
    'underline': underline,
    'color': color,
    'size': size,
  };

  TextSpanModel copy() => TextSpanModel(
    text: text,
    bold: bold,
    italic: italic,
    underline: underline,
    color: color,
    size: size,
  );
}

/// Ink (el yazisi) bloku icin tek cizgi. points normalize 0..1:
/// x blok genisligine, y blok yuksekligine gore (mevcut Stroke deseni).
/// width cizgi kalinligi, blok genisliginin orani.
class InkStroke {
  int color;
  double width;
  List<Offset> points;
  // Kalem basinci (0..1); Stroke.pressures ile ayni [x, y, p] JSON tasima
  // bicimi. Eski notlarda null (cizimde hiz taklidi kullanilir).
  List<double>? pressures;

  InkStroke({
    required this.color,
    required this.width,
    required this.points,
    this.pressures,
  });

  factory InkStroke.fromJson(Map<String, dynamic> j) {
    final (pts, pressures) = Stroke.decodePoints(j['points'] as List);
    return InkStroke(
      color: (j['color'] as int?) ?? 0xFF000000,
      width: (j['width'] as num?)?.toDouble() ?? 0.004,
      points: pts,
      pressures: pressures,
    );
  }

  Map<String, dynamic> toJson() => {
    'color': color,
    'width': width,
    'points': [
      for (var i = 0; i < points.length; i++)
        if (pressures != null && i < pressures!.length)
          [points[i].dx, points[i].dy, pressures![i]]
        else
          [points[i].dx, points[i].dy],
    ],
  };
}

/// Not icindeki bir blok: metin veya el yazisi (ink). blocks SIRALI akar.
class NoteBlock {
  /// "text" | "ink"
  final String type;
  // text bloku alanlari
  NoteAlign align;
  List<TextSpanModel> spans;
  // ink bloku alanlari (LEGACY: artik yeni el yazisi sayfa-seviyesinde tutulur,
  // bkz. NoteDoc.strokes. Eski notlarla uyum icin parse/round-trip korunur.)
  double height;
  List<InkStroke> strokes;

  NoteBlock.text({this.align = NoteAlign.left, TextSpanModel? span})
    : type = 'text',
      spans = [span ?? TextSpanModel(text: '')],
      height = 0,
      strokes = const [];

  NoteBlock.ink({this.height = 220, List<InkStroke>? strokes})
    : type = 'ink',
      align = NoteAlign.left,
      spans = const [],
      strokes = strokes ?? [];

  factory NoteBlock.fromJson(Map<String, dynamic> j) {
    final type = (j['type'] as String?) ?? 'text';
    if (type == 'ink') {
      return NoteBlock.ink(
        height: (j['height'] as num?)?.toDouble() ?? 220,
        strokes: (j['strokes'] as List?)
            ?.map((s) => InkStroke.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
    }
    final spans = (j['spans'] as List?)
        ?.map((s) => TextSpanModel.fromJson(s as Map<String, dynamic>))
        .toList();
    return NoteBlock.text(
      align: _alignFromJson(j['align'] as String?),
      span: spans == null || spans.isEmpty ? null : spans.first,
    );
  }

  Map<String, dynamic> toJson() {
    if (type == 'ink') {
      return {
        'type': 'ink',
        'height': height,
        'strokes': strokes.map((s) => s.toJson()).toList(),
      };
    }
    return {
      'type': 'text',
      'align': _alignToJson(align),
      'spans': spans.map((s) => s.toJson()).toList(),
    };
  }

  /// Metin bloku icin gosterim metni (tek span).
  String get text => spans.isEmpty ? '' : spans.first.text;
  set text(String v) {
    if (spans.isEmpty) {
      spans = [TextSpanModel(text: v)];
    } else {
      spans.first.text = v;
    }
  }
}

/// Tam not belgesi: GET /notes/{id} yaniti. Kaydedilirken komple PUT edilir.
class NoteDoc {
  final int schema;
  final String id;
  String title;
  int updatedAtMs;
  List<NoteBlock> blocks;
  // Sayfa-seviyesi el yazisi/cizim katmani: tum notu kaplar, metnin uzerine/
  // yanina/altina serbestce cizilir. Noktalar HER IKI EKSENDE icerik
  // GENISLIGINE normalize edilir (yukseklik degil) -> cizgiler sayfaya capali
  // kalir, dikey gerilmez. Cizgiler metne degil sayfa konumuna baglidir.
  List<InkStroke> strokes;

  NoteDoc({
    this.schema = 1,
    required this.id,
    required this.title,
    required this.updatedAtMs,
    required this.blocks,
    List<InkStroke>? strokes,
  }) : strokes = strokes ?? [];

  factory NoteDoc.fromJson(Map<String, dynamic> j) => NoteDoc(
    schema: (j['schema'] as int?) ?? 1,
    id: j['id'] as String,
    title: (j['title'] as String?) ?? '',
    updatedAtMs: (j['updated_at_ms'] as int?) ?? 0,
    blocks: (j['blocks'] as List?)
            ?.map((b) => NoteBlock.fromJson(b as Map<String, dynamic>))
            .toList() ??
        [],
    strokes: (j['strokes'] as List?)
        ?.map((s) => InkStroke.fromJson(s as Map<String, dynamic>))
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'schema': schema,
    'id': id,
    'title': title,
    'updated_at_ms': updatedAtMs,
    'blocks': blocks.map((b) => b.toJson()).toList(),
    if (strokes.isNotEmpty) 'strokes': strokes.map((s) => s.toJson()).toList(),
  };

  /// Kütüphane karti onizlemesi: ilk metin blokunun ilk satiri.
  String get preview {
    for (final b in blocks) {
      if (b.type == 'text' && b.text.trim().isNotEmpty) {
        return b.text.trim().replaceAll('\n', ' ');
      }
    }
    return '';
  }

  bool get hasInk =>
      strokes.isNotEmpty ||
      blocks.any((b) => b.type == 'ink' && b.strokes.isNotEmpty);
}

class VideoDoc {
  final String id;
  final String name;
  final String relativePath;
  final int size;
  final int modified;
  final int? durationSec;
  final int? positionSec;
  final int? positionUpdatedAt; // saniye (epoch), son izleme zamani

  VideoDoc({
    required this.id,
    required this.name,
    required this.relativePath,
    required this.size,
    required this.modified,
    this.durationSec,
    this.positionSec,
    this.positionUpdatedAt,
  });

  factory VideoDoc.fromJson(Map<String, dynamic> json) => VideoDoc(
    id: json['id'] as String,
    name: json['name'] as String,
    relativePath: json['relative_path'] as String,
    size: json['size'] as int,
    modified: json['modified'] as int,
    durationSec: json['duration_sec'] as int?,
    positionSec: json['position_sec'] as int?,
    positionUpdatedAt: json['position_updated_at'] as int?,
  );

  /// 0..1 arasi izleme orani; sure yoksa null (pozisyon yoksa 0 kabul edilir,
  /// boylece izlenmemis videolarda da bos cubuk gosterilebilir).
  double? get progress {
    final d = durationSec;
    if (d == null || d <= 0) return null;
    final p = positionSec ?? 0;
    return (p / d).clamp(0.0, 1.0);
  }

  bool get started => (positionSec ?? 0) > 0;

  /// Izlenmis sayilsin: %95'ten fazlasi izlendiyse.
  bool get finished {
    final pr = progress;
    return pr != null && pr >= 0.95;
  }

  /// Toplam sure metni (orn. "2:58:17"); sure yoksa bos.
  String get durationText {
    final d = durationSec;
    if (d == null || d <= 0) return '';
    final h = d ~/ 3600;
    final m = (d % 3600) ~/ 60;
    final s = d % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}

class PomodoroSession {
  final String sessionUuid;
  final String date;
  final String subject;
  final String phase;
  final int minutes;
  final int startedAtMs;
  final int? updatedAtMs;
  final String? updatedByDevice;
  final int? deletedAtMs;

  PomodoroSession({
    required this.sessionUuid,
    required this.date,
    required this.subject,
    required this.phase,
    required this.minutes,
    required this.startedAtMs,
    this.updatedAtMs,
    this.updatedByDevice,
    this.deletedAtMs,
  });

  factory PomodoroSession.fromJson(Map<String, dynamic> j) => PomodoroSession(
    sessionUuid: j['session_uuid'] as String,
    date: j['date'] as String,
    subject: j['subject'] as String,
    phase: j['phase'] as String,
    minutes: j['minutes'] as int,
    startedAtMs: j['started_at_ms'] as int,
    updatedAtMs: j['updated_at_ms'] as int?,
    updatedByDevice: j['updated_by_device'] as String?,
    deletedAtMs: j['deleted_at_ms'] as int?,
  );
}

class ReadingPosition {
  final int page;
  final int updatedAt;
  final String? device;

  ReadingPosition({required this.page, required this.updatedAt, this.device});

  factory ReadingPosition.fromJson(Map<String, dynamic> json) =>
      ReadingPosition(
        page: json['page'] as int,
        updatedAt:
            (json['updated_at_ms'] as int?) ??
            ((json['updated_at'] as int) * 1000),
        device: json['device'] as String?,
      );
}

class ReadingGoal {
  final String docId;
  final String date;
  final int startPage;
  final int targetPages;
  final int? updatedAtMs;
  final String? updatedByDevice;
  final int? deletedAtMs;

  ReadingGoal({
    required this.docId,
    required this.date,
    required this.startPage,
    required this.targetPages,
    this.updatedAtMs,
    this.updatedByDevice,
    this.deletedAtMs,
  });

  factory ReadingGoal.fromJson(Map<String, dynamic> j) => ReadingGoal(
    docId: j['doc_id'] as String,
    date: j['date'] as String,
    startPage: j['start_page'] as int,
    targetPages: j['target_pages'] as int,
    updatedAtMs: j['updated_at_ms'] as int?,
    updatedByDevice: j['updated_by_device'] as String?,
    deletedAtMs: j['deleted_at_ms'] as int?,
  );

  Map<String, dynamic> toJson() => {
    'doc_id': docId,
    'date': date,
    'start_page': startPage,
    'target_pages': targetPages,
    'updated_at_ms': updatedAtMs,
    'updated_by_device': updatedByDevice,
  };
}

class StudyTask {
  final int id;
  final String date;
  final String subject;
  final int targetMinutes;
  final bool done;

  StudyTask({
    required this.id,
    required this.date,
    required this.subject,
    required this.targetMinutes,
    required this.done,
  });

  factory StudyTask.fromJson(Map<String, dynamic> json) => StudyTask(
    id: json['id'] as int,
    date: json['date'] as String,
    subject: json['subject'] as String,
    targetMinutes: json['target_minutes'] as int,
    done: json['done'] as bool,
  );
}

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

class Stroke {
  int? id; // sunucu id'si (kaydedilene kadar null)
  final int page; // 1-tabanli
  final String kind; // 'pen' | 'highlight' | 'rect' | 'arrow' | 'text'
  final int color; // ARGB int
  final double width; // sayfa genisliginin orani
  final List<Offset> points; // normalize 0..1
  // Kalem basinci (0..1), points ile ayni uzunlukta. Eski kayitlarda ve
  // basinc bildirmeyen cihazlarda null; cizimde hiz-temelli taklit kullanilir.
  // JSON'da nokta basina 3. eleman olarak tasinir: [x, y, p] (eski istemciler
  // ilk iki elemani okudugu icin geriye uyumludur).
  final List<double>? pressures;
  final String? text;
  final double? fontSize;
  final String? fontFamily;
  String? strokeUuid;
  int? updatedAtMs;
  String? updatedByDevice;
  int? deletedAtMs;

  Stroke({
    this.id,
    required this.page,
    required this.kind,
    required this.color,
    required this.width,
    required this.points,
    this.pressures,
    this.text,
    this.fontSize,
    this.fontFamily,
    this.strokeUuid,
    this.updatedAtMs,
    this.updatedByDevice,
    this.deletedAtMs,
  });

  /// [x, y] veya [x, y, p] listesinden noktalari okur; herhangi bir noktada
  /// basinc varsa tum liste icin basinc dizisi kurar (eksikler 0.5).
  static (List<Offset>, List<double>?) decodePoints(List raw) {
    final pts = <Offset>[];
    List<double>? pressures;
    for (var i = 0; i < raw.length; i++) {
      final p = raw[i] as List;
      pts.add(Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()));
      if (p.length > 2 && p[2] != null) {
        pressures ??= List<double>.filled(raw.length, 0.5, growable: true);
        pressures[i] = (p[2] as num).toDouble();
      }
    }
    return (pts, pressures);
  }

  factory Stroke.fromJson(Map<String, dynamic> j) {
    final (pts, pressures) = decodePoints(j['points'] as List);
    return Stroke(
    id: j['id'] as int?,
    page: j['page'] as int,
    kind: j['kind'] as String,
    color: j['color'] as int,
    width: (j['width'] as num).toDouble(),
    points: pts,
    pressures: pressures,
    text: j['text'] as String?,
    fontSize: (j['font_size'] as num?)?.toDouble(),
    fontFamily: j['font_family'] as String?,
    strokeUuid: j['stroke_uuid'] as String?,
    updatedAtMs: j['updated_at_ms'] as int?,
    updatedByDevice: j['updated_by_device'] as String?,
    deletedAtMs: j['deleted_at_ms'] as int?,
    );
  }

  /// Basinc varsa [x, y, p] uclusu, yoksa [x, y] cifti uretir.
  List<List<double>> encodePoints() {
    final pr = pressures;
    return [
      for (var i = 0; i < points.length; i++)
        if (pr != null && i < pr.length)
          [points[i].dx, points[i].dy, pr[i]]
        else
          [points[i].dx, points[i].dy],
    ];
  }

  Map<String, dynamic> toJson() => {
    'page': page,
    'kind': kind,
    'color': color,
    'width': width,
    'points': encodePoints(),
    if (text != null) 'text': text,
    if (fontSize != null) 'font_size': fontSize,
    if (fontFamily != null) 'font_family': fontFamily,
    if (strokeUuid != null) 'stroke_uuid': strokeUuid,
  };
}

class LibraryFolder {
  final String name;
  final String path;

  LibraryFolder({required this.name, required this.path});

  factory LibraryFolder.fromJson(Map<String, dynamic> json) =>
      LibraryFolder(name: json['name'] as String, path: json['path'] as String);
}

class LibraryListing {
  final String path;
  final String? parent;
  final List<LibraryFolder> folders;
  final List<PdfDoc> pdfs;
  // Sunucu /library yanitindaki kind=="note" ogeler. Yerel onbellekte
  // tutulmazlar (notlar dosya-temellidir); yalnizca cevrimici listelemede
  // gorunurler.
  final List<NoteListItem> notes;

  LibraryListing({
    required this.path,
    required this.parent,
    required this.folders,
    required this.pdfs,
    this.notes = const [],
  });

  factory LibraryListing.fromJson(Map<String, dynamic> json) {
    final raw = (json['pdfs'] as List?) ?? const [];
    final pdfs = <PdfDoc>[];
    final notes = <NoteListItem>[];
    for (final e in raw) {
      final item = e as Map<String, dynamic>;
      if ((item['kind'] as String?) == 'note') {
        notes.add(NoteListItem.fromJson(item));
      } else {
        pdfs.add(PdfDoc.fromJson(item));
      }
    }
    return LibraryListing(
      path: json['path'] as String,
      parent: json['parent'] as String?,
      folders: (json['folders'] as List)
          .map((e) => LibraryFolder.fromJson(e as Map<String, dynamic>))
          .toList(),
      pdfs: pdfs,
      notes: notes,
    );
  }
}

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
    favorite: false,
    localFilePath: null,
    isCached: false,
  );
}

class ServerStatus {
  final bool reachable;
  final int? latencyMs;
  final int? serverTimeMs;
  final int? uptimeS;
  final int? dbSizeBytes;
  final int? pdfCount;
  final int? pdfTotalBytes;
  final int? indexedDocs;
  final String? lastBackup;

  ServerStatus({
    required this.reachable,
    this.latencyMs,
    this.serverTimeMs,
    this.uptimeS,
    this.dbSizeBytes,
    this.pdfCount,
    this.pdfTotalBytes,
    this.indexedDocs,
    this.lastBackup,
  });

  factory ServerStatus.fromJson(Map<String, dynamic> j, int latencyMs) =>
      ServerStatus(
        reachable: true,
        latencyMs: latencyMs,
        serverTimeMs: j['server_time_ms'] as int?,
        uptimeS: j['uptime_s'] as int?,
        dbSizeBytes: j['db_size_bytes'] as int?,
        pdfCount: j['pdf_count'] as int?,
        pdfTotalBytes: j['pdf_total_bytes'] as int?,
        indexedDocs: j['indexed_docs'] as int?,
        lastBackup: j['last_backup'] as String?,
      );
}
