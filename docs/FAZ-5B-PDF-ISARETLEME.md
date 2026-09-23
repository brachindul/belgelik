# FAZ 5B — PDF İşaretleme (Kalem + Fosforlu Kalem) [Syncfusion]

> **Ajana not:** Önce `ROADMAP.md` ve `docs/FAZ-1-PDF-OKUYUCU.md` + `docs/FAZ-2-SENKRONIZASYON.md`'yi oku. Bu faz **mevcut PDF okuyucuyu (pdfrx) Syncfusion ile değiştirir** ve işaretleme ekler. Faz 2 sayfa-senkronizasyonu KORUNMALIDIR. Kod bloklarını birebir uygula. DOĞRULAMA başarısızsa dur ve raporla.
>
> **Syncfusion sürüm hassasiyeti:** `syncfusion_flutter_pdfviewer` API'si sürümler arası değişebilir (`PdfAnnotationMode`, `saveDocument`, `annotationMode`, `onPageChanged` detay tipleri). Derlenmezse UYDURMA — DUR, `pubspec.lock`'taki `syncfusion_flutter_pdfviewer` ve `syncfusion_flutter_core` sürümlerini raporla.

## Amaç
1. PDF okuyucu Syncfusion `SfPdfViewer`'a geçer.
2. Araç çubuğu: **Kalem (ink)**, **Fosforlu (highlight)**, **İmleç (kapat)**, **Kaydet**.
3. Kaydet → işaretlemeler PDF'e gömülür, sunucuya yüklenir, yerel cache güncellenir → çapraz cihaz görünür.
4. Faz 2 sayfa-senkronizasyonu aynen çalışır (açılışta kaldığın sayfa, sayfa değişince kayıt).

---

## ÖN KOŞUL — Syncfusion Community License (KULLANICI YAPAR, BİR KEZ)

> **Bu adımı proje sahibi (kullanıcı) yapmalı; ajan kullanıcıdan key'i istemeli.**
1. <https://www.syncfusion.com/products/communitylicense> adresinden ÜCRETSİZ Community License hesabı aç.
2. Hesap panelinden **Flutter** için bir lisans anahtarı (uzun bir metin) al.
3. Bu anahtarı ajana ver; ajan aşağıda `BURAYA_LISANS_ANAHTARI` yazan yere yapıştıracak.

> Anahtar olmadan uygulama açılışta "trial" uyarı penceresi gösterir ama yine de çalışır. Kişisel kullanım için Community License tamamen yeterli ve ücretsizdir.

---

## BÖLÜM A — SUNUCU (dosya yükleme endpoint'i)

`server/main.py` içinde:

### A1. Import satırını güncelle
Mevcut `from fastapi import Depends, FastAPI, Header, HTTPException` satırına `Request` ekle:
```python
from fastapi import Depends, FastAPI, Header, HTTPException, Request
```

### A2. Yeni endpoint EKLE (diğer `/pdfs` endpoint'lerinin yanına):
```python
@app.put("/pdfs/{doc_id}/file", dependencies=[Depends(check_auth)])
async def upload_pdf_file(doc_id: str, request: Request):
    path = find_pdf_by_id(doc_id)
    if path is None:
        raise HTTPException(status_code=404, detail="PDF bulunamadi")
    data = await request.body()
    if not data:
        raise HTTPException(status_code=400, detail="Bos dosya")
    path.write_bytes(data)
    return {"ok": True, "size": len(data)}
```

### A3. Sunucuyu yeniden başlat
```powershell
cd <PROJE>\server
.\.venv\Scripts\Activate.ps1
uvicorn main:app --host 0.0.0.0 --port 8000
```

---

## BÖLÜM B — FLUTTER PAKETLERİ

```powershell
cd <PROJE>\app
flutter pub add syncfusion_flutter_pdfviewer syncfusion_flutter_core
flutter pub remove pdfrx
```
DOĞRULAMA: `pubspec.yaml`'da iki syncfusion paketi görünmeli, pdfrx kalkmalı, `flutter pub get` hatasız bitmeli.

---

## BÖLÜM C — FLUTTER KODU

### C1. `app/lib/main.dart` — lisansı kaydet
`main()` fonksiyonunda, `runApp` çağrısından ÖNCE Syncfusion lisansını kaydet. Importları ve main()'i şu hale getir (mevcut tema/notification mantığı korunur):
```dart
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_core/core.dart';

import 'config.dart';
import 'notifications.dart';
import 'screens/home_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SyncfusionLicense.registerLicense('BURAYA_LISANS_ANAHTARI');
  await AppConfig.load();
  await Notifications.init();
  runApp(const BelgelikApp());
}
```
> `BURAYA_LISANS_ANAHTARI` yerine kullanıcının verdiği anahtarı yapıştır. Kullanıcı anahtarı henüz vermediyse DUR ve iste.
> NOT: `BelgelikApp` sınıfı (tema mantığı dahil) Faz 5A'daki haliyle kalsın; sadece `main()` ve importlar değişiyor.

### C2. `app/lib/api.dart` — PDF yükleme metodu EKLE (`Api` sınıfı içine):
```dart
  static Future<void> uploadPdf(String docId, List<int> bytes) async {
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
```
> `api.dart` zaten `dart:io` (File) ve `path_provider` import ediyor (Faz 1). Etmiyorsa ekle.

### C3. `app/lib/screens/reader_screen.dart` dosyasının TAMAMINI şu içerikle değiştir:
```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../api.dart';
import '../models.dart';

class ReaderScreen extends StatefulWidget {
  final PdfDoc doc;
  const ReaderScreen({super.key, required this.doc});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final PdfViewerController _controller = PdfViewerController();
  late final Future<_ReaderData> _loadFuture;

  int _currentPage = 1;
  Timer? _debounce;
  PdfAnnotationMode _mode = PdfAnnotationMode.none;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadFuture = _load();
  }

  Future<_ReaderData> _load() async {
    final results = await Future.wait([
      Api.downloadPdf(widget.doc),
      Api.getPosition(widget.doc.id),
    ]);
    return _ReaderData(
      file: results[0] as File,
      savedPage: (results[1] as ReadingPosition?)?.page,
    );
  }

  void _onPageChanged(int page) {
    _currentPage = page;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), _savePosition);
  }

  void _savePosition() {
    Api.putPosition(widget.doc.id, _currentPage).catchError((_) {});
  }

  void _setMode(PdfAnnotationMode mode) {
    setState(() {
      _mode = (_mode == mode) ? PdfAnnotationMode.none : mode;
      _controller.annotationMode = _mode;
    });
  }

  Future<void> _saveAnnotations() async {
    setState(() => _saving = true);
    try {
      final bytes = await _controller.saveDocument();
      await Api.uploadPdf(widget.doc.id, bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('İşaretlemeler kaydedildi')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kaydedilemedi: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _savePosition();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.doc.name),
        actions: [
          IconButton(
            tooltip: 'Kalem',
            isSelected: _mode == PdfAnnotationMode.ink,
            icon: const Icon(Icons.edit),
            onPressed: () => _setMode(PdfAnnotationMode.ink),
          ),
          IconButton(
            tooltip: 'Fosforlu',
            isSelected: _mode == PdfAnnotationMode.highlight,
            icon: const Icon(Icons.highlight),
            onPressed: () => _setMode(PdfAnnotationMode.highlight),
          ),
          IconButton(
            tooltip: 'Kaydet',
            icon: _saving
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            onPressed: _saving ? null : _saveAnnotations,
          ),
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
          return SfPdfViewer.file(
            data.file,
            controller: _controller,
            initialPageNumber: (data.savedPage ?? 1),
            onPageChanged: (details) =>
                _onPageChanged(details.newPageNumber),
          );
        },
      ),
    );
  }
}

class _ReaderData {
  final File file;
  final int? savedPage;
  _ReaderData({required this.file, this.savedPage});
}
```

> **Fosforlu (highlight) notu:** Syncfusion'da `highlight` modu **metin işaretler** — yani metni seçili PDF'lerde çalışır (taranmış/resim PDF'lerde metin olmadığı için highlight tutmaz; orada kalem/ink kullanılır). Kalem (ink) her PDF'te serbest çizim yapar.

---

## BÖLÜM D — TEST

```powershell
cd <PROJE>\app
flutter run
```
1. Bir PDF aç. (Lisans kayıtlıysa "trial" penceresi ÇIKMAMALI.)
2. **Kalem** ikonuna bas, parmakla/kalemle çiz → çizgi görünmeli.
3. **Fosforlu** ikonuna bas, metin üstünde sürükle → metin sarı işaretlenmeli.
4. **Kaydet**'e bas → "İşaretlemeler kaydedildi" mesajı gelmeli.
5. Okuyucudan çık, aynı PDF'i tekrar aç → işaretlemeler DURMALI.
6. **Sync testi:** Başka cihazda aynı PDF'i aç → işaretlemeler görünmeli.
7. **Sayfa-sync regresyon testi:** Birkaç sayfa ilerle, çık, tekrar aç → kaldığın sayfadan açılmalı (Faz 2 hâlâ çalışıyor).

---

## DOĞRULAMA / BİTİŞ KONTROL LİSTESİ
- [ ] Syncfusion okuyucu açılıyor, "trial" uyarısı yok (lisans kayıtlı)
- [ ] Kalem ile serbest çizim yapılıyor
- [ ] Fosforlu ile metin işaretleniyor
- [ ] Kaydet → sunucuya yükleniyor, tekrar açınca işaretlemeler duruyor
- [ ] İşaretlemeler çapraz cihaz görünüyor
- [ ] Faz 2 sayfa-senkronizasyonu hâlâ çalışıyor (regresyon yok)

Hepsi yeşilse Faz 5B bitti.

```powershell
cd <PROJE>
git add .
git commit -m "Faz 5B: Syncfusion okuyucu + kalem/fosforlu isaretleme (sunucuya kayit)"
```

---

## Ajan için kurallar
1. Syncfusion lisans anahtarını kullanıcı vermeden C1'i tamamlama — DUR ve iste.
2. `PdfAnnotationMode`, `saveDocument`, `annotationMode`, `onPageChanged` API'si bu sürümde farklıysa DUR ve sürümleri raporla; uydurma düzeltme yapma.
3. Faz 2 sayfa-sync mantığını bozma (initialPageNumber + onPageChanged + debounce korunmalı).
4. Her DOĞRULAMA başarısızsa sonraki adıma geçme.
