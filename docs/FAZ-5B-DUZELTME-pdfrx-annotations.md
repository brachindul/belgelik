# FAZ 5B DÜZELTME — Syncfusion'u kaldır, pdfrx'e dön + flutter_pdf_annotations ile işaretleme

> **Ajana not:** Önce `ROADMAP.md`'yi oku. ÖNCEKİ DURUM: Syncfusion okuyucu büyük PDF'lerde çöküyor (OOM) ve serbest kalem (ink) desteklemiyor. ÇÖZÜM: Okuma için **pdfrx**'e geri dönüyoruz (Faz 1-2'de sorunsuz çalışıyordu), işaretleme için **flutter_pdf_annotations** (native editör, gerçek kalem+fosforlu) ekliyoruz. **Karanlık tema (Faz 5A) KORUNACAK** — ona dokunma. Kod bloklarını birebir uygula. DOĞRULAMA başarısızsa dur ve raporla. OS: Windows, PowerShell.
>
> **Önemli:** `app/lib/main.dart`, `config.dart`, `settings_screen.dart` (karanlık tema) ve `api.dart` (uploadPdf dahil) ile `server/main.py` (yükleme endpoint'i) DOĞRU durumda — bunlara DOKUNMA. Sadece aşağıdaki adımları yap.

## Amaç
1. Syncfusion paketlerini kaldır, pdfrx'i geri ekle, flutter_pdf_annotations ekle.
2. Okuyucu = pdfrx (Faz 2 sayfa-sync mantığıyla).
3. Okuyucuda **"İşaretle"** butonu → native annotation editörünü açar → kaydedince sunucuya yükler (mevcut `Api.uploadPdf`) → çapraz cihaz görünür.
4. **EN ÖNEMLİ TEST:** Kullanıcının gerçek büyük PDF'i (örn. ~19MB "hmgs son tekrar.pdf") hem pdfrx'te açılmalı hem editörde çökmeden açılmalı.

---

## ADIM 1 — Paketleri düzelt
```powershell
cd <PROJE>\app
flutter pub remove syncfusion_flutter_pdfviewer syncfusion_flutter_core
flutter pub add pdfrx flutter_pdf_annotations
```
DOĞRULAMA: `pubspec.yaml`'da syncfusion paketleri GİTMELİ, `pdfrx` ve `flutter_pdf_annotations` GÖRÜNMELİ, `flutter pub get` hatasız bitmeli.

---

## ADIM 2 — `app/lib/screens/reader_screen.dart` TAMAMINI şununla değiştir:
```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pdf_annotations/flutter_pdf_annotations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

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
  late Future<_ReaderData> _loadFuture;

  int _currentPage = 1;
  int _reloadKey = 0;
  Timer? _debounce;
  bool _annotating = false;

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

  void _onPageChanged(int? page) {
    if (page == null) return;
    _currentPage = page;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), _savePosition);
  }

  void _savePosition() {
    Api.putPosition(widget.doc.id, _currentPage).catchError((_) {});
  }

  Future<void> _annotate(File currentFile) async {
    setState(() => _annotating = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final outPath = '${dir.path}/annotated_${widget.doc.id}.pdf';

      final result = await FlutterPdfAnnotations.openPDF(
        filePath: currentFile.path,
        savePath: outPath,
        config: PDFAnnotationConfig(
          title: widget.doc.name,
          initialPenColor: Colors.red,
          initialHighlightColor: Colors.yellow.withOpacity(0.4),
          initialStrokeWidth: 3.0,
        ),
      );

      if (result.isSuccess && result.savedPath != null) {
        final bytes = await File(result.savedPath!).readAsBytes();
        await Api.uploadPdf(widget.doc.id, bytes);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('İşaretlemeler kaydedildi')),
          );
          // okuyucuyu guncel (isaretli) dosyayla yeniden yukle
          setState(() {
            _reloadKey++;
            _loadFuture = _load();
          });
        }
      } else if (result.isCancelled) {
        // kullanici vazgecti, bir sey yapma
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('İşaretleme hatası: ${result.error}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('İşaretleme açılamadı: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _annotating = false);
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
      appBar: AppBar(title: Text(widget.doc.name)),
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
          return Stack(
            children: [
              PdfViewer.file(
                data.file.path,
                key: ValueKey('${data.file.path}-$_reloadKey'),
                controller: _controller,
                params: PdfViewerParams(
                  onViewerReady: (document, controller) {
                    final target = data.savedPage;
                    if (target != null && target > 1) {
                      controller.goToPage(pageNumber: target);
                    }
                  },
                  onPageChanged: _onPageChanged,
                ),
              ),
              Positioned(
                right: 16,
                bottom: 16,
                child: FloatingActionButton.extended(
                  onPressed:
                      _annotating ? null : () => _annotate(data.file),
                  icon: _annotating
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.edit),
                  label: const Text('İşaretle'),
                ),
              ),
            ],
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

> **Not (initialPage):** `flutter_pdf_annotations`'ın `PDFAnnotationConfig`'inde `initialPage` parametresi sayfa indekslemesi belirsiz olduğu için bilerek KULLANILMADI (yanlış indeks crash riski). Editör 1. sayfadan açılır, kullanıcı kaydırır. İleride netleşirse eklenebilir.
> **Not (API):** `FlutterPdfAnnotations.openPDF`, `PDFAnnotationConfig`, `result.isSuccess/savedPath/isCancelled/error` çağrıları paket sürümünde farklıysa DUR ve `pubspec.lock`'taki `flutter_pdf_annotations` sürümünü + paket README API'sini raporla. `withOpacity` yeni Flutter'da deprecated olabilir; uyarı verirse `Colors.yellow.withValues(alpha: 0.4)` kullan.

---

## ADIM 3 — Android minSdk kontrolü
`flutter_pdf_annotations` Android API 21+ ister. `app/android/app/build.gradle` (veya `.kts`) içinde `minSdkVersion`/`minSdk` 21'den küçükse 21 yap. `flutter.minSdkVersion` kullanılıyorsa zaten yeterli olabilir — derleme hatası verirse 21'e sabitle.

---

## ADIM 4 — DERLE VE EN KRİTİK TESTİ ÖNCE YAP

```powershell
cd <PROJE>\app
flutter run
```

> **Sunucu açık olmalı.** Token uygulamada kayıtlı değilse Ayarlar'dan gir (token: kullanıcıdan al / `server/data/config.json`).

### TEST SIRASI (büyük PDF'i ÖNCE dene — OOM tuzağını erken yakala):
1. **Büyük gerçek PDF (örn. "hmgs son tekrar.pdf" ~19MB) pdfrx'te açılıyor mu?** → açılmalı, çökmemeli. (Faz 1-2'de açılıyordu.)
2. Aynı büyük PDF'te **İşaretle** butonuna bas → native editör açılmalı, ÇÖKMEMELİ.
3. Editörde **kalem** ile çiz, **fosforlu** ile işaretle, **kaydet/onayla**.
4. Editörden dönünce "İşaretlemeler kaydedildi" mesajı gelmeli ve okuyucuda işaretlemeler görünmeli.
5. Çık, aynı PDF'i tekrar aç → işaretlemeler DURMALI (sunucuya yüklendi).
6. **Sayfa-sync regresyonu:** birkaç sayfa ilerle, çık, tekrar aç → kaldığın sayfadan açılmalı.
7. **Karanlık tema regresyonu:** Ayarlar > Tema > Koyu → çalışmalı.

> **Eğer ADIM 4.2'de native editör büyük PDF'te yine çökerse:** DUR ve raporla. Bu durumda `flutter_pdf_annotations` da büyük dosyada yetersiz demektir; kullanıcıyla farklı strateji (örn. sadece görüntülenen sayfayı işaretleme) konuşulacak. UYDURMA çözüm deneme.

---

## DOĞRULAMA / BİTİŞ KONTROL LİSTESİ
- [ ] syncfusion paketleri kaldırıldı, pdfrx + flutter_pdf_annotations eklendi
- [ ] Büyük PDF pdfrx'te çökmeden açılıyor
- [ ] İşaretle → native editör büyük PDF'te çökmeden açılıyor
- [ ] Kalem ve fosforlu çiziliyor, kaydet çalışıyor
- [ ] İşaretlemeler sunucuya yükleniyor, tekrar açınca duruyor
- [ ] Sayfa-senkronizasyonu çalışıyor (regresyon yok)
- [ ] Karanlık tema çalışıyor (regresyon yok)
- [ ] Program + Pomodoro sekmeleri çalışıyor (regresyon yok)

Hepsi yeşilse:
```powershell
cd <PROJE>
git add .
git commit -m "Faz 5: karanlik tema + pdfrx okuyucu + flutter_pdf_annotations isaretleme (Syncfusion kaldirildi)"
```

---

## Ajan için kurallar
1. Karanlık tema / api.dart / server / config / settings dosyalarına DOKUNMA — onlar doğru.
2. `flutter_pdf_annotations` veya `pdfrx` API'si sürümde farklıysa DUR ve sürüm + README'yi raporla; uydurma düzeltme yapma.
3. Büyük PDF testi (ADIM 4.1 ve 4.2) başarısızsa DUR ve raporla — bu projenin kritik kabul kriteri.
4. Her DOĞRULAMA başarısızsa sonraki adıma geçme.
