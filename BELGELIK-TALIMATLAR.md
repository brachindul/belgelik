# Belgelik — Kalan İş Talimatları (Not Alma: App Tarafı)

Bu dosya, başka bir geliştirici/LLM'in projeyi **soğuktan** (önceki konuşmaları
görmeden) sürdürebilmesi içindir. **Tamamlanan işler bu dosyadan çıkarıldı**;
yalnızca KALAN iş (not alma özelliğinin uygulama tarafı: Faz E.2, E.3, E.4)
anlatılır. Kod yazarken çevredeki kodun stiline uy (yorumlar Türkçe, ASCII;
commit mesajları Türkçe).

---

## 0) Durum Özeti (neyin bittiği — TEKRAR YAPMA)

Bitti ve commit'lendi:
- **Çok profilli izolasyon** (profil başına ayrı SQLite + kütüphane klasörü),
  `GET /profile`, features'a göre sekme görünürlüğü.
- **Faz C — Video upload** (sunucu `POST /videos/upload` akışlı + faststart; app
  Videolar sekmesinde ilerlemeli yükleme). TAMAM.
- **Faz D — "Belgelik" rebranding** (app başlığı, Android label, Windows başlık).
  TAMAM.
- **Faz E.1 — NOT ALMA SUNUCU TARAFI**. TAMAM. Aşağıdaki API hazır ve çalışıyor.

**KALAN İŞ = Faz E.2, E.3, E.4 (hepsi uygulama / Flutter tarafı).** Sunucuya
dokunman GEREKMEZ (zorunlu kalırsa minimal ekle; mevcut not API'sini bozma).

Sürüm: `app/pubspec.yaml` `version: 1.10.1+36`. Yeni iş bitince artır
(örn. `1.11.0+37`). **Build alma** (kullanıcı ayrıca isteyecek); yalnız
`flutter analyze` ile doğrula.

---

## 1) Genel Bağlam

**Proje:** "Belgelik" — kişisel PDF/video/not çalışma kütüphanesi.
`app/` = Flutter (Android + Windows). `server/` = Python FastAPI.
Sunucu: `http://<SUNUCU-IP>:8000` (Tailscale). App base URL'i
`app/lib/config.dart` (`AppConfig.baseUrl`), token `AppConfig.token`.

**Çalıştırma / test:**
- Sunucu (PowerShell):
  `cd server; .\.venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8000`
- App analizi: `cd app; flutter analyze` (TEMİZ olmalı).
- **Commit:** Türkçe mesaj, dosyadan ver (`git commit -F mesaj.txt`). Mesaj sonu:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. **Push yapma.**

**İlgili dosyalar:**
- API katmanı: `app/lib/api.dart` (`Api` sınıfı; `_headers`, `AppConfig.baseUrl`).
- Modeller: `app/lib/models.dart` (`PdfDoc`, `VideoDoc`, `Stroke`).
- Kütüphane ekranı: `app/lib/screens/library_screen.dart` (liste, açma:
  mobilde `MaterialPageRoute(ReaderScreen)`, masaüstünde `onOpenDoc`).
- PDF okuyucu ve **S Pen / çizim altyapısı** (E.3 için ALTIN KAYNAK):
  `app/lib/screens/reader_annotation_layer.dart` — stylus algılama
  (`event.kind == PointerDeviceKind.stylus`), çizim biriktirme, `CustomPainter`.
  `reader_screen.dart` (kullanımı), `reader_page_layout.dart`
  (`kPenPalette`, `kHighlightPalette`, `kDefaultPenWidth`).
- Sekme tanımları: `app/lib/screens/app_tabs.dart`.

**Tuzaklar:**
- Dart: `clamp` `num` döndürür; Slider/double bağlamında `.toDouble()` ekle.
- Async sonrası `BuildContext`: `if (!mounted) return;`.
- PowerShell'de native exe'ye `2>&1` ekleme.

---

## 2) Mevcut NOT SUNUCU API'si (E.1 — hazır, app bununla konuşacak)

Bir not = sunucuda `pdf_dir` altında `.belge` uzantılı JSON dosyası; PDF'lerle
aynı klasörde durur. Tüm uçlar `X-Auth-Token` header'ı ister ve profil-izoledir.

- **`GET /notes`** → `{"items": [ NoteListItem, ... ]}`
  `NoteListItem = {id, name, relative_path, size, modified, title, kind:"note"}`
- **`POST /notes?name=<ad>&folder=<rel|"">`** → yeni boş not oluşturur,
  `NoteListItem` döner. Gövde gerekmez.
- **`GET /notes/{id}`** → notun **JSON içeriği** (aşağıdaki belge şeması).
- **`PUT /notes/{id}`** → gövde = tam JSON belge (içinde `updated_at_ms` olmalı;
  sunucu LWW uygular, daha eskiyse **409** döner). Yanıt: `{ok, updated_at_ms}`.
- **`DELETE /notes/{id}`** → notu siler.
- Notlar **`GET /library`** yanıtındaki `pdfs` dizisinde ve **`GET /pdfs`**
  `items` dizisinde de `kind:"note"` + `title` ile görünür (PDF'lerde
  `kind:"pdf"`).

**Belge (.belge) JSON şeması — `app/lib/models.dart`'ta modelle:**
```json
{
  "schema": 1,
  "id": "<doc_id>",
  "title": "Başlık",
  "updated_at_ms": 0,
  "blocks": [
    { "type": "text", "align": "left|center|right",
      "spans": [ { "text": "...", "bold": false, "italic": false,
                   "underline": false, "color": 4278190080, "size": 18.0 } ] },
    { "type": "ink", "height": 240.0,
      "strokes": [ { "color": 4278190080, "width": 0.004,
                     "points": [[x, y], ...] } ] }
  ]
}
```
- `color`: ARGB int (mevcut `Stroke.color` ile aynı kural).
- `ink.strokes[].points`: ink bloğunun GENİŞLİĞİNE göre normalize 0..1
  (mevcut `Stroke` deseni). `height`: bloğun piksel yüksekliği.
- `blocks` SIRALI akar: kullanıcı metin ve el yazısı bloklarını araya ekleyebilir.
- Sunucu blok yapısını doğrulamaz, JSON'u olduğu gibi saklar → şemayı app belirler.

---

## 3) ÖNEMLİ — Notları PDF'den ayır (ilk yapılacak düzeltme)

Şu an app, `/library` ve `/pdfs` yanıtındaki **not öğelerini (kind=="note")
PDF zannediyor**: listede PDF gibi gösterir, açılınca PDF olarak indirmeye
çalışıp **patlar**; ayrıca `Api.getLibrary` not öğelerini `PdfDoc` olarak
`LocalStore`'a önbelleğe alır. Üretimde henüz not olmadığı için görünmüyor ama
E.2'de not oluşturulur oluşturulmaz kırılır.

**Yap:**
1. `PdfDoc.fromJson`/listeleme akışında `kind` alanını oku. `kind=="note"`
   olanları PDF listesine/önbelleğine KATMA.
2. `Api.getLibrary` ve `Api.listPdfs`: PDF'leri `kind!="note"` diye süz; notları
   ayrı topla (örn. yeni `NoteDoc` modeli) ve kütüphane ekranına ayrı tür olarak
   ver.
3. Kütüphane ekranı (`library_screen.dart`): not öğelerini farklı ikonla
   (`Icons.edit_note`) göster; dokununca `ReaderScreen` yerine
   `NoteEditorScreen` (E.2) aç.

---

## FAZ E.2 — Klavyeyle Zengin Metin Editörü (App)

**Amaç:** Notu klavyeyle yaz; biçim: **kalın, italik, altı çizili**, hizalama
**sol/orta/sağ**, **renk**, **font boyutu**. Bölüm 3'teki ayrım yapılmış olmalı.

1. **Model** (`app/lib/models.dart`): `NoteDoc`, `NoteBlock` (text|ink),
   `TextSpanModel` (text, bold, italic, underline, color, size), `NoteAlign`.
   Bölüm 2'deki şemaya birebir uyan `fromJson`/`toJson`.
2. **API** (`app/lib/api.dart`): `listNotes`, `getNote(id)→NoteDoc`,
   `createNote(name, folder)`, `saveNote(NoteDoc)` (PUT; 409 gelirse sunucu
   sürümü daha yeni — kullanıcıyı uyar / yeniden yükle), `deleteNote(id)`.
   Kaydederken `updated_at_ms`'i `DateTime.now().millisecondsSinceEpoch` yap.
3. **Ekran** `app/lib/screens/note_editor_screen.dart`:
   - Üstte biçim araç çubuğu: **B / I / U** toggle, hizalama (sol/orta/sağ),
     renk seçici (palet: `kPenPalette`'i `reader_page_layout.dart`'tan kullan),
     font boyutu (12–48 slider veya stepper).
   - Gövde: metin blokları editörü. **v1 basit yol:** her metin bloğu bir
     `TextField`; seçili bloğa stil uygula (blok düzeyi stil yeterli). Span
     düzeyi zengin metin gerekiyorsa `flutter_quill` paketi düşünülebilir —
     **ama bağımlılık eklemeden önce kullanıcıdan onay iste.** Onay yoksa
     `TextField` + blok-düzeyi stil ile başla.
   - Otomatik kaydet: `reader_screen.dart`'taki `_debounce` desenini taklit et
     (~2 sn), `Api.saveNote` çağır. Çıkışta da kaydet.
   - "Yeni not" girişi: kütüphanedeki "+" menüsüne ekle (PDF yükleme menüsünün
     yanına), `createNote` → editörü aç.
4. **Kabul:** Klavyeyle yazılır; kalın/italik/altı çizili/hizalama/renk/boyut
   uygulanır; kapat-aç sonrası korunur; kütüphanede notlar PDF'lerden ayrı/uygun
   ikonla görünür ve doğru ekranda açılır.

---

## FAZ E.3 — S Pen El Yazısı Katmanı (App)

**Amaç:** S Pen ile yazınca **el yazısı (ink/çizgi)** olarak çizilsin; klavye
metni ile aynı notta sıralı dursun.

1. `reader_annotation_layer.dart`'taki stylus desenini yeniden kullan:
   `Listener`/`onPointerDown`'da `event.kind == PointerDeviceKind.stylus` ise
   ink modu; parmak/fare ile kaydırma/metin.
2. Not editörüne **ink bloğu** widget'ı: stylus dokununca o blokta çizgi
   biriktir (noktaları blok genişliğine göre normalize 0..1), bırakınca
   `NoteBlock(type:'ink')` olarak modele yaz. Çizim için `CustomPainter`
   (mevcut annotation painter'ı referans al).
3. Kalem rengi/kalınlığı seçimi (`kPenPalette`, `kDefaultPenWidth`). İstersen
   silgi/geri al (mevcut `_undo`/`_eraseAt` desenleri referans).
4. Akış: stylus ile boş alana yazmaya başlayınca otomatik yeni ink bloğu; klavye
   ile metin bloğu. Otomatik algı zorsa **v1:** editörde "el yazısı ekle"
   düğmesi ile ink bloğu eklensin ve stylus ile o bloğa yazılsın.
5. **Kabul:** S Pen ile çizgi-yazı çıkar; klavyeyle metin; ikisi aynı notta
   sıralı; kaydedilip geri yüklenir.

---

## FAZ E.4 — Görüntüleme, Küçük Resim, Senkron (App)

**Amaç:** Notlar cihazlar arası tutarlı; kütüphanede düzgün görünür.

1. **Önizleme:** kütüphane kartında ilk metin satırı veya ink önizlemesi/ikonu.
2. **Senkron (dosya-temelli, en basit yol yeterli):** açılışta/yenilemede
   `GET /notes`; düzenleyince `PUT /notes/{id}` (LWW `updated_at_ms`). 409 gelirse
   sunucudan tazele. Tam offline kuyruğa gerek YOK (PDF çizimlerindeki ağır sync
   altyapısına dokunma) — notlar dosya-temelli kalsın.
3. **Taşı/sil/yeniden adlandır:** kütüphanenin mevcut işlemleriyle uyumlu olsun.
   Sunucuda not taşıma ucu YOK; gerekirse minimal `POST /notes/{id}/move`
   ekleyebilirsin (PDF `move_pdf` desenine bak, `_transfer_doc_id` notes PK'sını
   zaten destekliyor) — yoksa v1'de yalnız sil + yeniden oluştur yeterli.
4. **Kabul:** Bir cihazda oluşturulan/düzenlenen not diğerinde görünür;
   değişiklikler korunur; kütüphanede sil çalışır.

---

## Bitiş
Her faz sonunda `flutter analyze` temiz olmalı, anlamlı Türkçe commit (push yok).
Tüm E fazları bitince kullanıcı (Claude/Opus) son denetimi yapacak; **build'i o
alacak.**
