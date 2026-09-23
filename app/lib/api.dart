import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'config.dart';
import 'local_store.dart';
import 'models.dart';
import 'mevzuat_models.dart';

class ApiClient {
  Map<String, String> get _headers => {'X-Auth-Token': AppConfig.token};

  Future<List<LegislationSummary>> listLegislation() async {
    final res = await http.get(Uri.parse('${AppConfig.baseUrl}/legislation'), headers: _headers).timeout(_timeout);
    if (res.statusCode != 200) throw Exception('Mevzuat listesi alınamadı (HTTP ${res.statusCode})');
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (data['items'] as List).map((e) => LegislationSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Map<String, dynamic>> downloadLegislationBundle(String lawNo) async {
    final res = await http.get(Uri.parse('${AppConfig.baseUrl}/legislation/$lawNo/bundle'), headers: _headers).timeout(_timeout);
    if (res.statusCode != 200) throw Exception('Mevzuat paketi alınamadı (HTTP ${res.statusCode})');
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  // Kucuk istek/yanit cagrilar icin varsayilan timeout. Kopuk baglantida
  // (Tailscale/Wi-Fi) istekler suresiz asili kalmasin. Buyuk govdeli yukleme
  // (uploadPdf) ve akisli indirmeler (downloadPdf/downloadApk) HARIC.
  final Duration _timeout = const Duration(seconds: 20);

  /// Profil bilgisi: {id, name, features}. Sekme gorunurlugu icin kullanilir.
  Future<Map<String, dynamic>> fetchProfile() async {
    final res = await http
        .get(Uri.parse('${AppConfig.baseUrl}/profile'), headers: _headers)
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) {
      throw Exception('Profil alınamadı (HTTP ${res.statusCode})');
    }
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  Future<List<PdfDoc>> listPdfs() async {
    final res = await http
        .get(Uri.parse('${AppConfig.baseUrl}/pdfs'), headers: _headers)
        .timeout(const Duration(seconds: 3));
    if (res.statusCode != 200) {
      throw Exception('Liste alınamadı (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    // /pdfs yaniti notlari da icerir (kind=="note"); onlari PDF listesinden
    // ayir, yalnizca gercek PDF'leri dondur (Bolum 3).
    final items = (data['items'] as List)
        .map((e) => PdfDoc.fromJson(e as Map<String, dynamic>))
        .where((d) => d.kind != 'note')
        .toList();
    return items;
  }

  Future<List<VideoDoc>> listVideos() async {
    final res = await http
        .get(Uri.parse('${AppConfig.baseUrl}/videos'), headers: _headers)
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) {
      throw Exception('Video listesi alınamadı (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (data['items'] as List)
        .map((e) => VideoDoc.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Oynatici dogrudan bu URL'den akis (Range) ile izler; indirme yapilmaz.
  Uri videoStreamUrl(String docId) =>
      Uri.parse('${AppConfig.baseUrl}/videos/$docId/file');

  /// video_player'a verilecek kimlik dogrulama header'lari.
  Map<String, String> get videoHeaders => _headers;

  Future<File> downloadPdf(PdfDoc doc) async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${dir.path}/pdf_cache');
    if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
    final file = File('${cacheDir.path}/${doc.id}.pdf');

    // Cache isabeti: dosya var + boyut ayni + kaydedildigi andaki sunucu
    // 'modified' su anki doc.modified ile ayni. modified karsilastirmasi, ayni
    // boyutta farkli icerikle degisen PDF'i yakalar (yeniden indirmeyi tetikler).
    if (file.existsSync() && file.lengthSync() == doc.size) {
      final cachedMod = await LocalStore.cachedPdfModified(doc.id);
      if (cachedMod == null || cachedMod == doc.modified) {
        return file;
      }
    }

    // Buyuk PDF'lerde sabit toplam timeout indirmeyi iptal ediyordu.
    // Akisli indirme: toplam sure sinirsiz, ama baglanti kurulumu ve
    // chunk'lar arasi bekleme 15 sn ile sinirli (kopuk baglantida asili kalmaz).
    final req = http.Request(
      'GET',
      Uri.parse('${AppConfig.baseUrl}/pdfs/${doc.id}/file'),
    );
    req.headers.addAll(_headers);
    final res = await req.send().timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('PDF indirilemedi (HTTP ${res.statusCode})');
    }
    final tmp = File('${file.path}.part');
    final sink = tmp.openWrite();
    try {
      await for (final chunk in res.stream.timeout(
        const Duration(seconds: 15),
      )) {
        sink.add(chunk);
      }
      await sink.close();
      if (tmp.existsSync()) {
        if (file.existsSync()) file.deleteSync();
        tmp.renameSync(file.path);
      }
    } catch (e) {
      await sink.close();
      if (tmp.existsSync()) tmp.deleteSync();
      throw Exception('PDF indirilemedi: $e');
    }
    try {
      await LocalStore.markPdfCached(
        doc.id,
        file.path,
        file.lengthSync(),
        modified: doc.modified,
      );
    } catch (_) {}
    return file;
  }

  Future<ReadingPosition?> getPosition(String docId) async {
    final res = await http
        .get(
          Uri.parse('${AppConfig.baseUrl}/position/$docId'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 3));
    if (res.statusCode != 200) {
      throw Exception('Pozisyon alınamadı (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final pos = data['position'];
    if (pos == null) return null;
    return ReadingPosition.fromJson(pos as Map<String, dynamic>);
  }

  Future<void> putPosition(String docId, int page) async {
    await http
        .put(
          Uri.parse('${AppConfig.baseUrl}/position/$docId'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'page': page, 'device': AppConfig.deviceId}),
        )
        .timeout(_timeout);
  }

  String _dateParam(DateTime date) =>
      date.toIso8601String().substring(0, 10);

  Future<ReadingGoal?> getReadingGoal(
    String docId,
    DateTime date,
  ) async {
    final uri = Uri.parse(
      '${AppConfig.baseUrl}/reading-goal/$docId',
    ).replace(queryParameters: {'date': _dateParam(date)});
    final res = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 3));
    if (res.statusCode != 200) {
      throw Exception('Okuma hedefi alınamadı (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final goal = data['goal'];
    if (goal == null) return null;
    return ReadingGoal.fromJson(goal as Map<String, dynamic>);
  }

  Future<ReadingGoal> putReadingGoal(
    String docId,
    DateTime date,
    int startPage,
    int targetPages,
  ) async {
    final uri = Uri.parse(
      '${AppConfig.baseUrl}/reading-goal/$docId',
    ).replace(queryParameters: {'date': _dateParam(date)});
    final res = await http
        .put(
          uri,
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'start_page': startPage,
            'target_pages': targetPages,
          }),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Okuma hedefi kaydedilemedi (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return ReadingGoal.fromJson(data['goal'] as Map<String, dynamic>);
  }

  Future<List<StudyTask>> getTasks(String date) async {
    try {
      final res = await http
          .get(
            Uri.parse('${AppConfig.baseUrl}/tasks?date=$date'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) {
        return const [];
      }
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return (data['items'] as List)
          .map((e) => StudyTask.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> createTask(
    String date,
    String subject,
    int targetMinutes,
  ) async {
    final res = await http
        .post(
          Uri.parse('${AppConfig.baseUrl}/tasks'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'date': date,
            'subject': subject,
            'target_minutes': targetMinutes,
          }),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Görev eklenemedi (HTTP ${res.statusCode})');
    }
  }

  Future<void> updateTask(int id, {bool? done}) async {
    final res = await http
        .put(
          Uri.parse('${AppConfig.baseUrl}/tasks/$id'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'done': done}),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Görev güncellenemedi (HTTP ${res.statusCode})');
    }
  }

  Future<void> deleteTask(int id) async {
    await http
        .delete(
          Uri.parse('${AppConfig.baseUrl}/tasks/$id'),
          headers: _headers,
        )
        .timeout(_timeout);
  }

  Future<void> uploadPdf(String docId, List<int> bytes) async {
    final res = await http.put(
      Uri.parse('${AppConfig.baseUrl}/pdfs/$docId/file'),
      headers: {..._headers, 'Content-Type': 'application/pdf'},
      body: bytes,
    );
    if (res.statusCode != 200) {
      throw Exception('PDF yuklenemedi (HTTP ${res.statusCode})');
    }
    // yerel cache'i de guncelle ki tekrar indirmeye gerek kalmasin
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/pdf_cache/$docId.pdf');
    await file.writeAsBytes(bytes);
  }

  Future<List<Stroke>> getAnnotations(String docId) async {
    final res = await http
        .get(
          Uri.parse('${AppConfig.baseUrl}/annotations/$docId'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 3));
    if (res.statusCode != 200) {
      throw Exception('İşaretlemeler alınamadı (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (data['items'] as List)
        .map((e) => Stroke.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<int> addStroke(String docId, Stroke s) async {
    final res = await http
        .post(
          Uri.parse('${AppConfig.baseUrl}/annotations/$docId'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({...s.toJson(), 'device': AppConfig.deviceId}),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Isaretleme eklenemedi (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return data['id'] as int;
  }

  Future<void> deleteStroke(int id) async {
    await http
        .delete(
          Uri.parse('${AppConfig.baseUrl}/annotations/$id'),
          headers: _headers,
        )
        .timeout(_timeout);
  }

  Future<void> uploadNewPdf(
    String fileName,
    List<int> bytes, {
    String folder = '',
  }) async {
    final uri = Uri.parse(
      '${AppConfig.baseUrl}/pdfs/upload?name=${Uri.encodeQueryComponent(fileName)}&folder=${Uri.encodeQueryComponent(folder)}',
    );
    final res = await http.post(
      uri,
      headers: {..._headers, 'Content-Type': 'application/pdf'},
      body: bytes,
    );
    if (res.statusCode != 200) {
      throw Exception('Yükleme başarısız (HTTP ${res.statusCode})');
    }
  }

  /// Video yukle. Buyuk dosyalar icin body'yi bellege almadan dosyayi
  /// openRead() parcalariyla akisli gonderir; [onProgress] 0..1 arasi oran
  /// besler. Yanit: sunucudan donen VideoDoc.
  Future<VideoDoc> uploadNewVideo(
    String fileName,
    File file, {
    String folder = '',
    void Function(double)? onProgress,
  }) async {
    final uri = Uri.parse(
      '${AppConfig.baseUrl}/videos/upload?name=${Uri.encodeQueryComponent(fileName)}&folder=${Uri.encodeQueryComponent(folder)}',
    );
    final total = file.lengthSync();
    var sent = 0;

    // http.StreamedRequest: govde byte'larini kendimiz uretip akisli yazariz;
    // buyuk video dosyalarinda butunu bellege yuklemeden gonderir.
    final req = _VideoUploadRequest(
      file,
      (bytes) {
        sent += bytes;
        onProgress?.call(total > 0 ? (sent / total).clamp(0.0, 1.0) : 0.0);
      },
      uri,
    );
    req.headers.addAll(_headers);

    final streamed = await req.send();
    if (streamed.statusCode != 200) {
      throw Exception('Yükleme başarısız (HTTP ${streamed.statusCode})');
    }
    final bodyBytes = await streamed.stream.toBytes();
    final data = jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
    return VideoDoc.fromJson(data);
  }

  Future<LibraryListing> getLibrary(String path) async {
    final uri = Uri.parse(
      '${AppConfig.baseUrl}/library',
    ).replace(queryParameters: path.isNotEmpty ? {'path': path} : {});
    final res = await http.get(uri, headers: _headers).timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Kütüphane alınamadı (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    // Yalnizca gercek PDF'leri yerel onbellege al. Notlar (kind=="note")
    // dosya-temellidir ve PdfDoc olarak onbelleğe KONMAMALI (Bolum 3); yoksa
    // app onlari PDF sanip indirmeye calisir.
    try {
      final pdfItems = (data['pdfs'] as List?)
          ?.map((e) => PdfDoc.fromJson(e as Map<String, dynamic>))
          .where((d) => d.kind != 'note')
          .toList();
      if (pdfItems != null) await LocalStore.upsertPdfDocs(pdfItems);
    } catch (_) {}
    return LibraryListing.fromJson(data);
  }

  Future<void> createFolder(String path, String name) async {
    final res = await http
        .post(
          Uri.parse('${AppConfig.baseUrl}/folders'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'path': path, 'name': name}),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Klasör oluşturulamadı (HTTP ${res.statusCode})');
    }
  }

  Future<void> renameFolder(String path, String newName) async {
    final res = await http
        .put(
          Uri.parse('${AppConfig.baseUrl}/folders/rename'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'path': path, 'new_name': newName}),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception(
        'Klasör yeniden adlandırılamadı (HTTP ${res.statusCode})',
      );
    }
  }

  Future<void> deleteFolder(String path) async {
    final uri = Uri.parse(
      '${AppConfig.baseUrl}/folders',
    ).replace(queryParameters: {'path': path});
    final res = await http.delete(uri, headers: _headers).timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Klasör silinemedi (HTTP ${res.statusCode})');
    }
  }

  Future<PdfDoc> movePdf(String docId, String targetFolder) async {
    final res = await http
        .post(
          Uri.parse('${AppConfig.baseUrl}/pdfs/$docId/move'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'target_folder': targetFolder}),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('PDF taşınamadı (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return PdfDoc.fromJson(data['item'] as Map<String, dynamic>);
  }

  Future<PdfDoc> copyPdf(String docId, String targetFolder) async {
    final res = await http
        .post(
          Uri.parse('${AppConfig.baseUrl}/pdfs/$docId/copy'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'target_folder': targetFolder}),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('PDF kopyalanamadı (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return PdfDoc.fromJson(data['item'] as Map<String, dynamic>);
  }

  Future<void> deletePdf(String docId) async {
    final res = await http
        .delete(
          Uri.parse('${AppConfig.baseUrl}/pdfs/$docId'),
          headers: _headers,
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('PDF silinemedi (HTTP ${res.statusCode})');
    }
  }

  // --- Notlar (Faz E) ---
  //
  // Notlar sunucuda .belge uzantili JSON dosyalari; PDF'lerle ayni klasorde.
  // Tum uçlar X-Auth-Token ister ve profil-izoledir. Kaydedilirken komple
  // JSON PUT edilir; sunucu LWW (updated_at_ms) uygular, daha eskiyse 409.

  /// Tum notlarin liste ogesi (GET /notes).
  Future<List<NoteListItem>> listNotes() async {
    final res = await http
        .get(Uri.parse('${AppConfig.baseUrl}/notes'), headers: _headers)
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) {
      throw Exception('Not listesi alınamadı (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (data['items'] as List)
        .map((e) => NoteListItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Notun tam icerigi (GET /notes/{id}) -> NoteDoc.
  Future<NoteDoc> getNote(String id) async {
    final res = await http
        .get(Uri.parse('${AppConfig.baseUrl}/notes/$id'), headers: _headers)
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) {
      throw Exception('Not alınamadı (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return NoteDoc.fromJson(data);
  }

  /// Yeni bos not olustur (POST /notes?name=&folder=). NoteListItem doner.
  Future<NoteListItem> createNote(String name, {String folder = ''}) async {
    final uri = Uri.parse(
      '${AppConfig.baseUrl}/notes?name=${Uri.encodeQueryComponent(name)}&folder=${Uri.encodeQueryComponent(folder)}',
    );
    final res = await http.post(uri, headers: _headers).timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Not oluşturulamadı (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return NoteListItem.fromJson(data);
  }

  /// Notu kaydet (PUT /notes/{id}). updated_at_ms su anki zaman yapilir.
  /// Sunucu LWW uygular: istemci daha eskiyse 409 doner -> [conflict]=true.
  /// 409 durumda document yeniden yuklenmeli (cagiran yapar).
  Future<({bool conflict, int? updatedAtMs})> saveNote(NoteDoc doc) async {
    doc.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
    final res = await http
        .put(
          Uri.parse('${AppConfig.baseUrl}/notes/${doc.id}'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode(doc.toJson()),
        )
        .timeout(_timeout);
    if (res.statusCode == 409) {
      return (conflict: true, updatedAtMs: null);
    }
    if (res.statusCode != 200) {
      throw Exception('Not kaydedilemedi (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final uam = data['updated_at_ms'] as int?;
    return (conflict: false, updatedAtMs: uam);
  }

  /// Notu sil (DELETE /notes/{id}).
  Future<void> deleteNote(String id) async {
    final res = await http
        .delete(
          Uri.parse('${AppConfig.baseUrl}/notes/$id'),
          headers: _headers,
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Not silinemedi (HTTP ${res.statusCode})');
    }
  }

  /// Notu tasi (POST /notes/{id}/move). PDF move_pdf desenine uyar; sunucu
  /// _transfer_doc_id ile notes tablosunun PK'ini gunceller. NoteListItem doner.
  Future<NoteListItem> moveNote(String id, String targetFolder) async {
    final res = await http
        .post(
          Uri.parse('${AppConfig.baseUrl}/notes/$id/move'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'target_folder': targetFolder}),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Not taşınamadı (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return NoteListItem.fromJson(data['item'] as Map<String, dynamic>);
  }

  Future<List<PdfDoc>> getFavorites() async {
    final res = await http
        .get(
          Uri.parse('${AppConfig.baseUrl}/favorites'),
          headers: _headers,
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Favoriler alınamadı (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (data['items'] as List)
        .map((e) => PdfDoc.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> setFavorite(String docId, bool favorite) async {
    final res = await http
        .put(
          Uri.parse('${AppConfig.baseUrl}/favorites/$docId'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'favorite': favorite}),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Favori güncellenemedi (HTTP ${res.statusCode})');
    }
  }

  Future<List<PdfDoc>> getRecent({int limit = 5}) async {
    final res = await http
        .get(
          Uri.parse('${AppConfig.baseUrl}/recent?limit=$limit'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 3));
    if (res.statusCode != 200) {
      throw Exception('Son açılanlar alınamadı (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (data['items'] as List)
        .map((e) => PdfDoc.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> markRecent(String docId) async {
    final res = await http
        .post(
          Uri.parse('${AppConfig.baseUrl}/recent/$docId'),
          headers: _headers,
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Son açılan güncellenemedi (HTTP ${res.statusCode})');
    }
  }

  Future<void> deleteRecent(String docId) async {
    final res = await http
        .delete(
          Uri.parse('${AppConfig.baseUrl}/recent/$docId'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) {
      throw Exception('Son açılan silinemedi (HTTP ${res.statusCode})');
    }
  }

  Future<List<SearchHit>> searchContent(String query) async {
    final res = await http
        .get(
          Uri.parse(
            '${AppConfig.baseUrl}/search?q=${Uri.encodeQueryComponent(query)}',
          ),
          headers: _headers,
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Arama basarisiz (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (data['items'] as List)
        .map((e) => SearchHit.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> reindex() async {
    await http
        .post(
          Uri.parse('${AppConfig.baseUrl}/reindex'),
          headers: _headers,
        )
        .timeout(_timeout);
  }

  Future<ServerStatus> getServerStatus() async {
    final sw = Stopwatch()..start();
    try {
      final res = await http
          .get(Uri.parse('${AppConfig.baseUrl}/health'), headers: _headers)
          .timeout(const Duration(seconds: 3));
      sw.stop();
      if (res.statusCode != 200) {
        return ServerStatus(
          reachable: false,
          latencyMs: sw.elapsedMilliseconds,
        );
      }
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return ServerStatus.fromJson(data, sw.elapsedMilliseconds);
    } catch (_) {
      sw.stop();
      return ServerStatus(reachable: false, latencyMs: sw.elapsedMilliseconds);
    }
  }

  Future<void> triggerBackup() async {
    final res = await http
        .post(Uri.parse('${AppConfig.baseUrl}/backup'), headers: _headers)
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) {
      throw Exception('Yedekleme baslatilamadi (HTTP ${res.statusCode})');
    }
  }

  Future<Map<String, dynamic>?> getAppVersion() async {
    try {
      final res = await http
          .get(Uri.parse('${AppConfig.baseUrl}/app/version'), headers: _headers)
          .timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return null;
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<File> downloadApk({
    void Function(int received, int total)? onProgress,
  }) async {
    final dir = await getApplicationCacheDirectory();
    final file = File('${dir.path}/belgelik-update.apk');
    final req = http.Request('GET', Uri.parse('${AppConfig.baseUrl}/app/apk'));
    req.headers.addAll(_headers);
    final res = await req.send();
    if (res.statusCode != 200) {
      throw Exception('APK indirilemedi (HTTP ${res.statusCode})');
    }
    final total = res.contentLength ?? 0;
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } finally {
      await sink.close();
    }
    return file;
  }

  Future<bool> isServerReachable() async {
    try {
      final res = await http
          .get(Uri.parse('${AppConfig.baseUrl}/health'), headers: _headers)
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

/// Video yukleme icin akisli istek. Dosyayi parcalarla okuyup govdeye yazar;
/// her parcada [_onBytes] ile ilerlemeyi besler. Boylece buyuk video dosyalari
/// butunuyle bellege yuklenmeden gonderilir.
class _VideoUploadRequest extends http.StreamedRequest {
  _VideoUploadRequest(this._file, this._onBytes, Uri uri)
      : super('POST', uri);

  final File _file;
  final void Function(int bytes) _onBytes;

  @override
  http.ByteStream finalize() {
    // finalized bayragini isle ve govde akisini kur. openRead() akisini her
    // parca icin sayan bir transformer ile sarmala; stream bir kez okunur.
    final progress = _file.openRead().transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          _onBytes(chunk.length);
          sink.add(chunk);
        },
      ),
    );
    // finalized'i super ile isaretleyip body akisini degistir.
    super.finalize();
    return http.ByteStream(progress);
  }
}
