import 'dart:convert';

class LegislationSummary {
  final String mevzuatNo, ad, kisaAd, tur, snapshotVersion;
  final int articleCount, size;
  final int? downloadedAtMs;
  const LegislationSummary({required this.mevzuatNo, required this.ad, required this.kisaAd, required this.tur, required this.snapshotVersion, required this.articleCount, required this.size, this.downloadedAtMs});

  factory LegislationSummary.fromJson(Map<String, dynamic> j) => LegislationSummary(
    mevzuatNo: j['mevzuat_no'] as String,
    ad: j['ad'] as String,
    kisaAd: (j['kisa_ad'] as String?) ?? '',
    tur: (j['tur'] as String?) ?? 'Kanun',
    snapshotVersion: j['snapshot_version'] as String,
    articleCount: (j['article_count'] as num).toInt(),
    size: (j['size'] as num?)?.toInt() ?? 0,
    downloadedAtMs: (j['downloaded_at_ms'] as num?)?.toInt(),
  );
}

class LegislationArticle {
  final String id, mevzuatNo, baslik, maddeNoRaw, metin, snapshotVersion;
  final int sira;
  final Map<String, dynamic> metadata;
  const LegislationArticle({required this.id, required this.mevzuatNo, required this.sira, required this.baslik, required this.maddeNoRaw, required this.metin, required this.metadata, required this.snapshotVersion});

  factory LegislationArticle.fromJson(Map<String, dynamic> j, String lawNo) => LegislationArticle(
    id: j['id'] as String,
    mevzuatNo: lawNo,
    sira: (j['sira'] as num).toInt(),
    baslik: (j['baslik'] as String?) ?? '',
    maddeNoRaw: (j['madde_no_raw'] as String?) ?? '',
    metin: (j['metin'] as String?) ?? '',
    metadata: (j['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
    snapshotVersion: j['snapshot_version'] as String,
  );

  factory LegislationArticle.fromRow(Map<String, dynamic> r) => LegislationArticle(
    id: r['id'] as String,
    mevzuatNo: r['mevzuat_no'] as String,
    sira: r['sira'] as int,
    baslik: r['baslik'] as String,
    maddeNoRaw: r['madde_no_raw'] as String,
    metin: r['metin'] as String,
    metadata: jsonDecode(r['metadata_json'] as String) as Map<String, dynamic>,
    snapshotVersion: r['snapshot_version'] as String,
  );

  List<Map<String, dynamic>> get paragraphs => ((metadata['fikralar'] as List?) ?? const [])
      .map((e) => (e as Map).cast<String, dynamic>()).toList();
  String? get part => metadata['part'] as String?;
  String? get section => metadata['section'] as String?;
}

class MaddeNote {
  final String noteUuid, maddeRef, kind, text;
  final int? renk;
  final String? seciliMetinAraligi;
  final int updatedAtMs;
  final String updatedByDevice;
  final int? deletedAtMs;
  const MaddeNote({required this.noteUuid, required this.maddeRef, required this.kind, this.renk, this.seciliMetinAraligi, required this.text, required this.updatedAtMs, required this.updatedByDevice, this.deletedAtMs});

  factory MaddeNote.fromRow(Map<String, dynamic> r) => MaddeNote(noteUuid: r['note_uuid'] as String, maddeRef: r['madde_ref'] as String, kind: r['kind'] as String, renk: r['renk'] as int?, seciliMetinAraligi: r['secili_metin_araligi'] as String?, text: r['text'] as String? ?? '', updatedAtMs: r['updated_at_ms'] as int, updatedByDevice: r['updated_by_device'] as String? ?? '', deletedAtMs: r['deleted_at_ms'] as int?);
}

class LegislationChange {
  final String maddeRef, oldVersion, newVersion, summary;
  final String? oldText, newText;
  final int createdAtMs;
  const LegislationChange({required this.maddeRef, required this.oldVersion, required this.newVersion, required this.summary, this.oldText, this.newText, required this.createdAtMs});
  factory LegislationChange.fromJson(Map<String, dynamic> j) => LegislationChange(maddeRef: j['madde_ref'] as String, oldVersion: j['old_version'] as String, newVersion: j['new_version'] as String, summary: j['degisiklik_ozeti'] as String, oldText: j['old_text'] as String?, newText: j['new_text'] as String?, createdAtMs: (j['created_at_ms'] as num).toInt());
}
