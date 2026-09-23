# FAZ 9 - Offline First PDF Çalışma ve Sync

> **Ajana not:** Önce `ROADMAP.md`, `docs/FAZ-7-PDF-DOSYA-YONETICISI.md` ve `docs/FAZ-8A-KUTUPHANE-HIZLANDIRMA.md` dosyalarını oku. Bu faz DeepSeek/opencode tarafından uygulanacak. Amaç: Android cihaz sunucuya/Tailscale ağına bağlanamadığında da PDF'leri açabilsin, okuyabilsin, çizim/işaretleme yapabilsin ve okuma ilerlemesini kaydedebilsin. Sunucu tekrar erişilebilir olduğunda en yeni kayıtlar last-write-wins kuralıyla senkronize edilecek.
>
> **Belirsizlikte DUR ve raporla.** Sync tasarımında varsayım uydurma. Her alt fazın doğrulamaları başarılı olmadan sonraki alt faza geçme. OS: Windows, PowerShell.
>
> **Kesin kararlar:** Tek kullanıcı. Üyelik, Play Store, çoklu hesap, cloud servis yok. PDF okuyucu `pdfrx` kalacak. İşaretleme sistemi rasterize edilmeyecek. Tüm dokümanı bellekte rasterize eden paket eklenmeyecek. Tailscale sunucusu ana veri kaynağıdır; Android offline çalışırken yerel kopya kullanır.

---

## 0. Kapsam ve Öncelik

Bu fazın hedefi **offline okuma ve offline çalışma**dır.

Bu fazda yapılacaklar:

- Android cihaz PDF listesini local cache'ten gösterebilecek.
- PDF dosyaları Android'de local dosya olarak saklanacak.
- Sunucu yokken PDF açılacak.
- Sunucu yokken okuma pozisyonu local kaydedilecek.
- Sunucu yokken çizim/işaretleme local kaydedilecek.
- Favoriler, son açılanlar ve günlük okuma hedefi local kaydedilecek.
- Sunucu tekrar erişilebilir olunca local değişiklikler sunucuya gönderilecek.
- Sunucudaki daha yeni değişiklikler Android'e çekilecek.

Bu fazda yapılmayacaklar:

- Offline PDF taşıma/kopyalama/silme YOK.
- Offline klasör oluşturma/yeniden adlandırma/silme YOK.
- PDF upload offline kuyruğu YOK.
- Çok cihazlı gerçek zamanlı sync YOK.
- Kullanıcıya manuel conflict çözüm ekranı YOK.
- OCR, PDF metin indexleme, arama motoru YOK.

**Neden offline dosya yöneticisi yok?**

Mevcut `doc_id = sha1(relative_path)[:16]` kuralı nedeniyle PDF taşınınca `doc_id` değişir. Offline dosya yönetimi bu kimlik modelinde op-log ve rename mapping gerektirir. Bu yüzden Faz 9'da önce okuma/işaretleme/pozisyon/favori/recent/hedef offline yapılacak. Offline dosya yöneticisi ayrı bir Faz 10 konusu olmalıdır.

---

## 1. Mevcut Durumu Doğrula

Çalışmaya başlamadan önce:

```powershell
cd <PROJE>
git status --short
```

- Beklenmeyen değişiklik varsa DUR ve raporla.
- Özellikle aşağıdaki dosyaları oku:
  - `server/main.py`
  - `app/lib/models.dart`
  - `app/lib/api.dart`
  - `app/lib/config.dart`
  - `app/lib/notifications.dart`
  - `app/lib/screens/library_screen.dart`
  - `app/lib/screens/reader_screen.dart`
  - `app/lib/screens/favorites_screen.dart`
  - `app/lib/screens/recent_screen.dart`

Bu faz mevcut PDF okuyucu, çizim, search, favori, recent, günlük hedef ve klasör gezintisi davranışlarını bozmayacak.

---

## 2. Sync Modeli

### 2.1 Genel Kural

Her sync edilebilir kayıt şu alanları taşıyacak:

- `updated_at_ms`: Android veya sunucu tarafından üretilmiş Unix epoch milisaniye.
- `updated_by_device`: `AppConfig.deviceId`.
- `deleted_at_ms`: nullable. Silme gerekiyorsa satır hemen yok edilmeyecek, tombstone olarak işaretlenecek.

Çakışma kuralı:

```text
1. updated_at_ms büyük olan kazanır.
2. updated_at_ms eşitse updated_by_device string karşılaştırmasında büyük olan kazanır.
3. Silme tombstone'u da normal kayıt gibi last-write-wins kuralına girer.
```

### 2.2 Kayıt Bazlı Merge

Komple cihaz kazandırma yapma. Her veri türü kendi satır/kayıt bazında merge edilir:

- Okuma pozisyonu: `doc_id` bazında tek kayıt, en yeni kazanır.
- İşaretleme stroke: `stroke_uuid` bazında merge edilir.
- Favori: `doc_id` bazında en yeni toggle kazanır.
- Recent: `doc_id` bazında en yeni `opened_at_ms` kazanır.
- Günlük hedef: `doc_id + date` bazında en yeni kayıt kazanır.
- PDF metadata: sunucu canonical kabul edilir; client local listeyi sunucudan gelen metadata ile günceller.

### 2.3 Stroke Kimliği

Mevcut sunucuda annotation id'si integer autoincrement. Offline eklenen çizgilerin sunucu id'si yoktur. Bu yüzden annotations için yeni kalıcı kimlik gerekir.

Beklenti:

- `annotations` tablosuna `stroke_uuid TEXT` ekle.
- Android local store'da her yeni stroke için UUID üret.
- Sunucuya gönderirken `stroke_uuid` ile gönder.
- Sunucu integer `id` alanını geriye dönük uyumluluk için koruyabilir.
- Silme işlemleri sync tarafında `stroke_uuid` ile yapılmalı.

SQLite migration:

- `ALTER TABLE annotations ADD COLUMN stroke_uuid TEXT`
- `ALTER TABLE annotations ADD COLUMN updated_at_ms INTEGER`
- `ALTER TABLE annotations ADD COLUMN updated_by_device TEXT`
- `ALTER TABLE annotations ADD COLUMN deleted_at_ms INTEGER`
- Eski satırlarda `stroke_uuid` yoksa deterministic veya random UUID üret. Deterministic tercih:
  - `legacy-{id}`.

**DUR koşulu:** Mevcut Flutter `Stroke.id` ile tüm silme akışı `id` üzerinden çalışıyorsa, offline silme için `strokeUuid` eklemeden devam etme. Önce model/API uyarlamasını yap.

---

## 3. Alt Fazlar

Fazlar sırayla uygulanacak:

- 9A: Flutter local store altyapısı.
- 9B: PDF dosya cache'i ve offline kütüphane listesi.
- 9C: Offline pozisyon, işaretleme, favori, recent, günlük hedef.
- 9D: Sunucu sync tabloları ve endpoint'leri.
- 9E: Flutter sync motoru.
- 9F: UI durumu, regresyon ve kabul testi.

9A bitmeden 9B'ye geçme. 9C bitmeden sunucu sync endpoint'lerine geçme. 9D bitmeden client sync motorunu yazma.

---

## FAZ 9A - Flutter Local Store Altyapısı

### Amaç

Android'de offline verileri saklayacak SQLite altyapısını kurmak.

### Dokunulacak dosyalar

- `app/pubspec.yaml`
- `app/lib/models.dart`
- `app/lib/local_store.dart` yeni dosya
- `app/lib/main.dart` gerekirse init çağrısı

### Paket

Tercih: `sqflite`.

Sebep:

- Basit.
- Mobilde yaygın.
- Bu uygulama tek kullanıcı ve küçük veri hacimli.

`drift` ancak mevcut kod çok karmaşık hale gelirse tercih edilebilir. Bu fazda `sqflite` yeterlidir.

### Local tablolar

`local_store.dart` içinde SQLite database aç:

```text
pdf_docs
local_positions
local_annotations
local_favorites
local_recent
local_reading_goals
sync_state
pending_ops
```

Beklenen kolonlar:

`pdf_docs`:

- `doc_id TEXT PRIMARY KEY`
- `name TEXT NOT NULL`
- `relative_path TEXT NOT NULL`
- `size INTEGER NOT NULL`
- `modified INTEGER NOT NULL`
- `favorite INTEGER NOT NULL DEFAULT 0`
- `local_file_path TEXT`
- `local_file_size INTEGER`
- `cached_at_ms INTEGER`
- `server_seen_at_ms INTEGER`
- `deleted_at_ms INTEGER`

`local_positions`:

- `doc_id TEXT PRIMARY KEY`
- `page INTEGER NOT NULL`
- `updated_at_ms INTEGER NOT NULL`
- `updated_by_device TEXT NOT NULL`
- `dirty INTEGER NOT NULL DEFAULT 0`
- `deleted_at_ms INTEGER`

`local_annotations`:

- `stroke_uuid TEXT PRIMARY KEY`
- `server_id INTEGER`
- `doc_id TEXT NOT NULL`
- `page INTEGER NOT NULL`
- `kind TEXT NOT NULL`
- `color INTEGER NOT NULL`
- `width REAL NOT NULL`
- `points TEXT NOT NULL`
- `updated_at_ms INTEGER NOT NULL`
- `updated_by_device TEXT NOT NULL`
- `dirty INTEGER NOT NULL DEFAULT 0`
- `deleted_at_ms INTEGER`

`local_favorites`:

- `doc_id TEXT PRIMARY KEY`
- `favorite INTEGER NOT NULL`
- `updated_at_ms INTEGER NOT NULL`
- `updated_by_device TEXT NOT NULL`
- `dirty INTEGER NOT NULL DEFAULT 0`

`local_recent`:

- `doc_id TEXT PRIMARY KEY`
- `opened_at_ms INTEGER NOT NULL`
- `updated_by_device TEXT NOT NULL`
- `dirty INTEGER NOT NULL DEFAULT 0`

`local_reading_goals`:

- `doc_id TEXT NOT NULL`
- `date TEXT NOT NULL`
- `start_page INTEGER NOT NULL`
- `target_pages INTEGER NOT NULL`
- `updated_at_ms INTEGER NOT NULL`
- `updated_by_device TEXT NOT NULL`
- `dirty INTEGER NOT NULL DEFAULT 0`
- `deleted_at_ms INTEGER`
- primary key: `(doc_id, date)`

`sync_state`:

- `key TEXT PRIMARY KEY`
- `value TEXT NOT NULL`

`pending_ops`:

- `id INTEGER PRIMARY KEY AUTOINCREMENT`
- `op_type TEXT NOT NULL`
- `entity_type TEXT NOT NULL`
- `entity_id TEXT NOT NULL`
- `payload TEXT NOT NULL`
- `created_at_ms INTEGER NOT NULL`
- `attempt_count INTEGER NOT NULL DEFAULT 0`
- `last_error TEXT`

### Model güncellemeleri

`PdfDoc`:

- `localFilePath String?`
- `isCached bool`

`Stroke`:

- `strokeUuid String`
- `updatedAtMs int?`
- `updatedByDevice String?`
- `deletedAtMs int?`

Mevcut API cevaplarında bu alanlar yoksa geriye dönük uyumlu parse et.

### LocalStore metodları

Minimum beklenen metodlar:

```dart
Future<void> init();
Future<void> upsertPdfDocs(List<PdfDoc> docs);
Future<List<PdfDoc>> listPdfDocs({String path = ''});
Future<PdfDoc?> getPdfDoc(String docId);
Future<void> markPdfCached(String docId, String filePath, int fileSize);

Future<ReadingPosition?> getPosition(String docId);
Future<void> putPosition(String docId, int page, {required bool dirty});

Future<List<Stroke>> getAnnotations(String docId);
Future<void> upsertStroke(Stroke stroke, {required bool dirty});
Future<void> markStrokeDeleted(String strokeUuid, {required bool dirty});

Future<void> setFavorite(String docId, bool favorite, {required bool dirty});
Future<List<PdfDoc>> getFavorites();

Future<void> markRecent(String docId, {required bool dirty});
Future<List<PdfDoc>> getRecent({int limit = 5});

Future<ReadingGoal?> getReadingGoal(String docId, DateTime date);
Future<void> putReadingGoal(ReadingGoal goal, {required bool dirty});
```

### Kabul kriterleri

- App açılışında local DB oluşur.
- Mevcut online davranış bozulmaz.
- `flutter analyze` temizdir.
- Local store unit test veya en azından widget construct testi bozulmaz.

### Doğrulama

```powershell
cd <PROJE>\app
C:\src\flutter\bin\flutter.bat pub get
C:\src\flutter\bin\flutter.bat analyze
C:\src\flutter\bin\flutter.bat test --no-pub
```

Başarısızlıkta DUR ve raporla.

---

## FAZ 9B - PDF Offline Cache ve Kütüphane Fallback

### Amaç

PDF dosyaları Android'de local cache'te saklansın. Sunucu yoksa kütüphane local listeden açılsın.

### Dokunulacak dosyalar

- `app/lib/api.dart`
- `app/lib/local_store.dart`
- `app/lib/screens/library_screen.dart`
- `app/lib/screens/reader_screen.dart`

### Kurallar

- Online iken `/library` ve `/pdfs` cevapları local `pdf_docs` tablosuna yazılır.
- `Api.downloadPdf` başarılı olursa PDF dosyası kalıcı local cache'e yazılır ve `pdf_docs.local_file_path` güncellenir.
- Sunucu yoksa:
  - Kütüphane local `pdf_docs` tablosundan gösterilir.
  - Yalnız cache'lenmiş PDF'ler açılabilir.
  - Cache'lenmemiş PDF için kullanıcıya net mesaj göster: `Bu PDF henüz offline kullanılabilir değil.`

### Cache yolu

`getApplicationDocumentsDirectory()` altında:

```text
pdf_cache/{doc_id}.pdf
```

Mevcut cache davranışını koru ama local store ile metadata ekle.

### "Tümünü Offline Hazırla" Butonu

Library AppBar veya overflow menüye bir aksiyon ekle:

- Etiket: `Tüm PDF’leri offline hazırla`
- Online iken bütün PDF'leri sırayla indirir.
- İndirme sırasında küçük progress/snackbar yeterli.
- Aynı anda çoklu download başlatma. Sırayla indir.
- Hata olursa kalanları durdurma; sonunda kaç başarılı/kaç hata raporla.

### Kabul kriterleri

- Online iken PDF açınca cache'e yazılır.
- Sunucu kapalıyken daha önce açılmış PDF tekrar açılır.
- Sunucu kapalıyken hiç cache'lenmemiş PDF açılmaya çalışırsa uygulama çökmez.
- Local kütüphane listeleme klasör path'lerine saygı gösterir.

### Doğrulama

```powershell
cd <PROJE>\app
C:\src\flutter\bin\flutter.bat analyze
C:\src\flutter\bin\flutter.bat test --no-pub
```

Manuel test:

1. Sunucu açıkken PDF listesini aç.
2. Bir PDF aç, kapat.
3. Sunucuyu kapat.
4. Aynı PDF'yi tekrar aç.
5. Cache'lenmemiş PDF açma denemesinde çökme olmadığını doğrula.

Başarısızlıkta DUR ve raporla.

---

## FAZ 9C - Offline Pozisyon, İşaretleme, Favori, Recent, Günlük Hedef

### Amaç

Sunucu yokken yapılan çalışma kaybolmasın.

### Dokunulacak dosyalar

- `app/lib/api.dart`
- `app/lib/local_store.dart`
- `app/lib/screens/reader_screen.dart`
- `app/lib/screens/library_screen.dart`
- `app/lib/screens/favorites_screen.dart`
- `app/lib/screens/recent_screen.dart`

### Position

Reader sayfa değişiminde:

1. Önce local store'a yaz.
2. Online ise sunucuya yazmayı dene.
3. Sunucu başarısızsa local kayıt `dirty=1` kalsın.

`updated_at_ms` Android tarafında `DateTime.now().millisecondsSinceEpoch` ile üretilecek.

### Annotation

Stroke ekleme:

1. `strokeUuid` üret.
2. Local store'a hemen yaz.
3. UI'da hemen göster.
4. Online ise sunucuya gönder.
5. Sunucu başarısızsa `dirty=1` kalsın.

Stroke silme:

1. Local row'u hemen silme.
2. `deleted_at_ms` set et.
3. UI'da gösterme.
4. Online ise sunucuya tombstone gönder.
5. Sunucu başarısızsa `dirty=1` kalsın.

### Favorite

Yıldız toggle:

1. Önce local store.
2. UI anında güncellenir.
3. Online push denenir.
4. Başarısızsa dirty kalır.

### Recent

PDF açılınca:

1. Local recent güncellenir.
2. Online push denenir.

### Reading Goal

Günlük hedef:

1. Local goal yoksa local oluştur.
2. Online ise server goal ile merge et.
3. Sunucu yoksa hedef barı local değerle çalışır.
4. Bildirimler local kalan sayfaya göre planlanır.

### API Wrapper Prensibi

Flutter `Api` sınıfı şu davranışa sahip olacak:

- Online success: server cevabı local store'a yazılır.
- Online failure: local fallback döner.
- Mutation success: local dirty temizlenir.
- Mutation failure: local dirty kalır.

Bu yaklaşım için gerekirse `Api` içinde küçük private helper'lar yaz:

```dart
static bool _isNetworkFailure(Object error)
```

Ancak geniş ve karmaşık yeni abstraction yazma.

### Kabul kriterleri

- Sunucu kapalıyken PDF içinde sayfa ilerlemesi kaybolmaz.
- Sunucu kapalıyken çizim yapılır, uygulama kapanıp açılınca çizim durur.
- Sunucu kapalıyken silinen local stroke tekrar görünmez.
- Sunucu kapalıyken favori/recent/hedef local çalışır.

### Doğrulama

```powershell
cd <PROJE>\app
C:\src\flutter\bin\flutter.bat analyze
C:\src\flutter\bin\flutter.bat test --no-pub
```

Manuel test:

1. Bir PDF'i cache'le.
2. Sunucuyu kapat.
3. PDF'i aç.
4. Sayfa değiştir.
5. Çizim yap.
6. Uygulamayı kapat/aç.
7. PDF'i tekrar aç.
8. Sayfa ve çizimin local kaldığını doğrula.

Başarısızlıkta DUR ve raporla.

---

## FAZ 9D - Sunucu Sync Altyapısı

### Amaç

Android local değişiklikleri sunucuya gönderebilsin, sunucudaki yeni değişiklikleri çekebilsin.

### Dokunulacak dosya

- `server/main.py`

### Migration

Mevcut tabloları bozmadan kolon ekle.

Beklenen ek kolonlar:

`positions`:

- `updated_at_ms INTEGER`
- `updated_by_device TEXT`
- `deleted_at_ms INTEGER`

`annotations`:

- `stroke_uuid TEXT`
- `updated_at_ms INTEGER`
- `updated_by_device TEXT`
- `deleted_at_ms INTEGER`

`pdf_favorites`:

- `favorite INTEGER NOT NULL DEFAULT 1`
- `updated_at_ms INTEGER`
- `updated_by_device TEXT`

`pdf_recent`:

- `opened_at_ms INTEGER`
- `updated_by_device TEXT`

`reading_goals`:

- `updated_at_ms INTEGER`
- `updated_by_device TEXT`
- `deleted_at_ms INTEGER`

Eski `updated_at` saniye alanları geriye dönük kalabilir. Yeni sync endpoint'leri `updated_at_ms` kullanacak.

### Endpointler

Yeni endpointler:

```text
GET  /sync/pull?since_ms=0
POST /sync/push
GET  /sync/status
```

Hepsi `X-Auth-Token` ister.

### `/sync/status`

Döner:

```json
{
  "ok": true,
  "server_time_ms": 1710000000000
}
```

### `/sync/pull`

Query:

- `since_ms`: client'ın son başarılı pull zamanı.

Dönüş:

```json
{
  "server_time_ms": 1710000000000,
  "pdfs": [],
  "positions": [],
  "annotations": [],
  "favorites": [],
  "recent": [],
  "reading_goals": []
}
```

Kurallar:

- `since_ms` sonrası değişen kayıtları döndür.
- PDF metadata için `modified` veya server_seen zamanı kullanılabilir.
- `deleted_at_ms` olan annotation/goal kayıtlarını da döndür; client tombstone'u uygulayacak.
- PDF dosya baytları bu endpoint'ten dönmez.

### `/sync/push`

Body:

```json
{
  "device_id": "cihaz-123",
  "positions": [],
  "annotations": [],
  "favorites": [],
  "recent": [],
  "reading_goals": []
}
```

Dönüş:

```json
{
  "ok": true,
  "server_time_ms": 1710000000000,
  "accepted": {
    "positions": 1,
    "annotations": 3,
    "favorites": 1,
    "recent": 1,
    "reading_goals": 1
  }
}
```

Merge kuralları:

- Gelen kaydın `updated_at_ms` değeri server'daki kayıttan yeniyse uygula.
- Eşitse `updated_by_device` tie-breaker kullan.
- Daha eskiyse ignore et ama hata dönme.
- Annotation için `stroke_uuid` zorunlu.

### Existing endpoint uyumluluğu

Mevcut endpoint'ler bozulmayacak:

- `/position/{doc_id}`
- `/annotations/{doc_id}`
- `/favorites`
- `/recent`
- `/reading-goal/{doc_id}`

Ancak bu endpoint'ler de yeni alanları mümkünse döndürmeli:

- `updated_at_ms`
- `updated_by_device`
- `stroke_uuid`
- `deleted_at_ms`

Geriye dönük uyumluluk için eski Flutter parse etmeye devam edebilmeli.

### PDF move/delete/rename etkisi

Faz 7 operasyonlarında yeni tablolar/kolonlar da korunacak:

- PDF taşıma: `positions`, `annotations`, `pdf_favorites`, `pdf_recent`, `reading_goals` yeni `doc_id`ye aktarılır.
- PDF silme: ilgili kayıtlar ya silinir ya tombstone yapılır. Bu fazda server canonical olduğu için direkt silme kabul edilebilir, ama sync/pull client'a silme bilgisini veremiyorsa DUR ve raporla.
- Klasör rename: alt PDF'lerin `doc_id` aktarımları korunur.

### Kabul kriterleri

- `python -m py_compile server\main.py` geçer.
- `/sync/status` auth ile çalışır.
- `/sync/push` yeni position gönderince server kaydeder.
- `/sync/pull?since_ms=0` o position'ı döndürür.
- Daha eski kayıt push edilince server'daki yeni kayıt ezilmez.

### Doğrulama

```powershell
cd <PROJE>
python -m py_compile server\main.py
```

Sunucuyu başlat:

```powershell
cd <PROJE>
.\server\.venv\Scripts\Activate.ps1
python -m uvicorn server.main:app --host 0.0.0.0 --port 8000
```

Manuel HTTP testleri için token'ı `server\data\config.json` içinden oku. PowerShell örnekleri yazarken gerçek token'ı kullan.

Başarısızlıkta DUR ve raporla.

---

## FAZ 9E - Flutter Sync Motoru

### Amaç

Flutter online olduğunda local dirty kayıtları server'a push etsin ve server değişikliklerini pull etsin.

### Dokunulacak dosyalar

- `app/lib/api.dart`
- `app/lib/local_store.dart`
- `app/lib/sync_service.dart` yeni dosya
- `app/lib/main.dart`
- `app/lib/screens/library_screen.dart`

### SyncService

Yeni `sync_service.dart` oluştur.

Minimum davranış:

```dart
class SyncService {
  static Future<void> init();
  static Future<void> syncNow();
  static Future<bool> isOnline();
}
```

### Sync tetikleyicileri

Sync şu anlarda denenmeli:

- App açılışında.
- Kütüphane ekranı açıldığında.
- PDF okuyucu kapatılırken veya pozisyon kaydedildikten sonra debounce ile.
- Kullanıcı `Şimdi senkronize et` butonuna basınca.

Arka planda sürekli polling yapma. Basit ve kontrollü tut.

### Push sırası

Önerilen sıra:

1. positions
2. annotations
3. favorites
4. recent
5. reading_goals

PDF dosya upload/rename/delete offline olmadığı için pending op içinde bunlar olmamalı.

### Pull sonrası local apply

Server'dan gelen kayıtlar local store'a merge edilir.

Merge:

- Server kaydı local'den yeniyse local'i güncelle.
- Local dirty kayıt server'dan yeniyse local korunur ve bir sonraki push'ta tekrar gider.
- Tombstone gelen stroke UI'da görünmez.

### Sync state

`sync_state` içinde:

- `last_pull_ms`
- `last_successful_sync_ms`
- `last_sync_error`

### UI durum göstergesi

Kütüphane ekranında sade bir gösterge yeterli:

- Online ve sync başarılı: küçük metin veya icon `Senkronize`
- Offline: `Offline`
- Hata: `Sync hatası`

Bu gösterge UI'ı kalabalıklaştırmamalı.

### Kabul kriterleri

- Sunucu kapalıyken local değişiklikler dirty kalır.
- Sunucu açılınca `syncNow()` dirty kayıtları gönderir.
- Server'daki daha yeni position client'a gelir.
- Client'taki daha yeni position server'ı ezer.
- Annotation ekleme/silme offline sonrası sync olur.

### Doğrulama

```powershell
cd <PROJE>\app
C:\src\flutter\bin\flutter.bat analyze
C:\src\flutter\bin\flutter.bat test --no-pub
```

Manuel test:

1. Sunucu açıkken bir PDF'i cache'le.
2. Sunucuyu kapat.
3. PDF'te sayfa değiştir ve çizim yap.
4. Uygulamayı kapat/aç.
5. Sunucuyu aç.
6. Sync tetikle.
7. Server DB'de position/annotation geldiğini doğrula.
8. Başka cihaz/simülasyon yoksa server kaydını elle daha yeni timestamp ile değiştir ve pull sonrası client'ın güncellendiğini doğrula.

Başarısızlıkta DUR ve raporla.

---

## FAZ 9F - Regresyon, Kabul Testi ve Sınırlar

### Amaç

Offline-first entegrasyonun mevcut özellikleri bozmadığını doğrulamak.

### Zorunlu kontroller

Sunucu açıkken:

- PDF listesi gelir.
- Klasör gezintisi çalışır.
- PDF açılır.
- PDF search çalışır.
- Çizim yapılır.
- Silgi çalışır.
- Sayfa pozisyonu kaydedilir.
- Favori toggle çalışır.
- Son açılanlar güncellenir.
- Günlük hedef barı ve bildirim planlama çalışır.

Sunucu kapalıyken:

- Uygulama açılır.
- Local kütüphane görünür.
- Cache'li PDF açılır.
- Cache'siz PDF için çökmeden uyarı gösterilir.
- Çizim yapılır ve app restart sonrası durur.
- Sayfa pozisyonu app restart sonrası durur.
- Favori/recent/hedef local çalışır.

Sunucu tekrar açılınca:

- Dirty kayıtlar sync olur.
- Daha yeni server kaydı local'i günceller.
- Daha eski server kaydı local dirty kaydı ezmez.

### Zorunlu komutlar

```powershell
cd <PROJE>
python -m py_compile server\main.py

cd <PROJE>\app
C:\src\flutter\bin\flutter.bat analyze
C:\src\flutter\bin\flutter.bat test --no-pub
```

### Teslim raporu

İş bittiğinde şu formatta rapor ver:

```text
FAZ 9 tamamlandı.

Değişen dosyalar:
- ...

Eklenen tablolar:
- ...

Eklenen endpointler:
- ...

Manuel test sonucu:
- Online test: ...
- Offline test: ...
- Reconnect sync test: ...

Bilinen sınırlar:
- Offline dosya taşıma/kopyalama/silme bu fazda yok.
- Offline upload bu fazda yok.
```

---

## Denetim Notu

Bu faz tamamlandıktan sonra ben ayrıca review yapacağım:

- `git diff` okuyacağım.
- Server migration ve sync merge kurallarını denetleyeceğim.
- Flutter local store ve dirty kayıt akışını kontrol edeceğim.
- PDF okuyucuda offline annotation davranışını test edeceğim.
- `flutter analyze`, `flutter test`, `python -m py_compile` çalıştıracağım.
- Bulguları önem sırasına göre dosya/satır referansıyla raporlayacağım.

