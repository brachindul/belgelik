# FAZ 6 — Telefondan Kütüphaneye PDF Yükleme

> **Ajana not:** Önce `ROADMAP.md`'yi oku. Bu faz mevcut çalışan uygulamaya eklenir. Amaç: Android cihazdan bir PDF seçip sunucudaki `pdf-kutuphane/` klasörüne yükleyebilmek; yüklenince kütüphane listesinde görünmeli. Kod bloklarını BİREBİR uygula. DOKUNMA: okuyucu, işaretleme, pomodoro, program, tema dosyaları. DOĞRULAMA başarısızsa dur ve raporla. OS: Windows, PowerShell.

## Amaç
1. Sunucu: yeni PDF dosyasını ada göre `pdf-kutuphane/`'ye kaydeden endpoint.
2. Uygulama: Kütüphane ekranında **"+"** butonu → cihazdan PDF seç → sunucuya yükle → liste yenilensin.

---

## BÖLÜM A — SUNUCU (`server/main.py`)

### A1. `Request` import edili olduğundan emin ol
Dosyanın başındaki fastapi import satırında `Request` YOKSA ekle. Hedef satır şu hale gelmeli:
```python
from fastapi import Depends, FastAPI, Header, HTTPException, Request
```

### A2. Yeni endpoint EKLE (diğer `/pdfs` endpoint'lerinin yanına)
```python
@app.post("/pdfs/upload", dependencies=[Depends(check_auth)])
async def upload_new_pdf(name: str, request: Request):
    # Yol kac (path traversal) onleme: sadece dosya adi
    safe = Path(name).name.strip()
    if not safe:
        raise HTTPException(status_code=400, detail="Gecersiz dosya adi")
    if not safe.lower().endswith(".pdf"):
        safe += ".pdf"

    target = PDF_DIR / safe
    # Ayni ad varsa: ad(1).pdf, ad(2).pdf ...
    if target.exists():
        stem = target.stem
        i = 1
        while target.exists():
            target = PDF_DIR / f"{stem}({i}).pdf"
            i += 1

    data = await request.body()
    if not data:
        raise HTTPException(status_code=400, detail="Bos dosya")
    target.write_bytes(data)

    rel = target.relative_to(PDF_DIR).as_posix()
    return {"id": doc_id_for(rel), "name": target.stem}
```
> `Path` ve `doc_id_for` ve `PDF_DIR` zaten tanımlı (Faz 1).

### A3. Sunucuyu yeniden başlat
```powershell
cd <PROJE>\server
.\.venv\Scripts\Activate.ps1
uvicorn main:app --host 0.0.0.0 --port 8000
```

### A4. DOĞRULAMA (sunucu) — `<TOKEN>` gerçek değer
```powershell
curl -X POST "http://localhost:8000/pdfs/upload?name=deneme.pdf" -H "X-Auth-Token: <TOKEN>" -H "Content-Type: application/pdf" --data-binary "@C:\path\to\herhangi.pdf"
curl http://localhost:8000/pdfs -H "X-Auth-Token: <TOKEN>"
```
İlk komut `{"id":...,"name":"deneme"}` dönmeli; ikinci komutta `deneme` listede görünmeli. (Test sonrası `pdf-kutuphane/deneme.pdf`'i silebilirsin.)

---

## BÖLÜM B — UYGULAMA

### B1. file_picker paketini ekle
```powershell
cd <PROJE>\app
flutter pub add file_picker
```
DOĞRULAMA: `pubspec.yaml`'da `file_picker` görünmeli, `flutter pub get` hatasız bitmeli.

### B2. `app/lib/api.dart`'a yükleme metodu EKLE (`Api` sınıfı içine)
```dart
  static Future<void> uploadNewPdf(String fileName, List<int> bytes) async {
    final res = await http.post(
      Uri.parse(
          '${AppConfig.baseUrl}/pdfs/upload?name=${Uri.encodeQueryComponent(fileName)}'),
      headers: {..._headers, 'Content-Type': 'application/pdf'},
      body: bytes,
    );
    if (res.statusCode != 200) {
      throw Exception('Yukleme basarisiz (HTTP ${res.statusCode})');
    }
  }
```

### B3. `app/lib/screens/library_screen.dart` — "+" butonu + yükleme
1. Dosyanın başına importları EKLE:
```dart
import 'dart:io';

import 'package:file_picker/file_picker.dart';
```
2. `_LibraryScreenState` sınıfının içine yükleme metodunu EKLE:
```dart
  Future<void> _uploadPdf() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        withData: true,
      );
      if (result == null) return; // kullanici vazgecti
      final f = result.files.single;
      final bytes = f.bytes ??
          (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (bytes == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Dosya okunamadı')),
          );
        }
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Yükleniyor…')),
        );
      }
      await Api.uploadNewPdf(f.name, bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF eklendi')),
        );
        _refresh();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hata: $e')),
        );
      }
    }
  }
```
3. `Scaffold`'a FloatingActionButton EKLE. `Scaffold(` satırından sonra, `appBar:`'dan ÖNCE şunu ekle:
```dart
      floatingActionButton: FloatingActionButton(
        onPressed: _uploadPdf,
        tooltip: 'PDF ekle',
        child: const Icon(Icons.upload_file),
      ),
```

---

## BÖLÜM C — TEST

```powershell
cd <PROJE>\app
flutter run
```
> Sunucu açık olmalı; token kayıtlı olmalı.

1. Kütüphane sekmesinde sağ altta **+** (yükle) butonu görünmeli.
2. Bas → cihazın dosya seçicisi açılmalı → bir PDF seç.
3. "Yükleniyor…" → "PDF eklendi" mesajları gelmeli.
4. Liste otomatik yenilenmeli ve yüklediğin PDF görünmeli.
5. PDF'e dokun → açılıp okunmalı.
6. **Çapraz cihaz:** başka cihazda kütüphaneyi yenile (aşağı çek) → yeni PDF orada da görünmeli.
7. Aynı adlı bir PDF'i tekrar yükle → `ad(1).pdf` olarak eklenmeli (üzerine yazmamalı).

---

## DOĞRULAMA / BİTİŞ KONTROL LİSTESİ
- [ ] `curl POST /pdfs/upload` çalışıyor, dosya `pdf-kutuphane/`'ye düşüyor
- [ ] Uygulamada + butonu dosya seçici açıyor
- [ ] Seçilen PDF sunucuya yükleniyor, liste yenilenince görünüyor
- [ ] Yüklenen PDF açılıp okunabiliyor
- [ ] Aynı ad çakışması güvenli (üzerine yazmıyor)
- [ ] Okuyucu/işaretleme/pomodoro/program/tema regresyonsuz

Hepsi yeşilse:
```powershell
cd <PROJE>
git add .
git commit -m "Faz 6: telefondan kutuphaneye PDF yukleme"
```

---

## Ajan için kurallar
1. Okuyucu/işaretleme/tema/pomodoro/program dosyalarına DOKUNMA.
2. `file_picker` API'si sürümde farklıysa (`pickFiles`, `withData`, `files.single.bytes/path`) DUR ve `pubspec.lock` sürümünü raporla; uydurma yapma.
3. Büyük PDF (örn. 20MB) yüklemesini de dene; başarısızsa raporla.
4. Her DOĞRULAMA başarısızsa sonraki adıma geçme.
