# FAZ 20 — Sağlamlaştırma ve Refaktör (Kapsamlı Talimat)

> **Ajana not:** Bu doküman kendi kendine yeterlidir (bazı eski FAZ dosyaları `ROADMAP-V2.md`'ye atıf yapar; o dosya repoda yok, aramaya gerek yok). Önce `ROADMAP.md`'yi oku. Bölümler **sırayla** yapılır; her bölüm kendi başına çalışır+test edilmiş halde **ayrı commit** ile biter. Bir bölümün DOĞRULAMA'sı geçmeden sonrakine geçme. Belirsizlikte varsayım yapma, sor.

## Kapsam ve sıra

| Bölüm | Konu | Boyut | Risk | Zorunlu mu? |
|-------|------|-------|------|-------------|
| 1 | `backup.py` çoklu profil düzeltmesi | Küçük | Düşük | **EVET (kritik)** |
| 2 | Sync pull imleci: sunucu saati (`received_at_ms`) | Orta | Orta | **EVET (kritik)** |
| 3 | İstemci sync timeout'ları | Küçük | Düşük | EVET |
| 4 | PDF cache tazeliği (`modified` karşılaştırması) | Küçük | Düşük | EVET |
| 5 | Tombstone temizliği | Küçük | Düşük | EVET |
| 6 | CI (GitHub Actions) + `run-tests.ps1` | Küçük | Düşük | EVET |
| 7 | `main.py`'yi router modüllerine bölme | Orta | Orta | EVET |
| 8 | Sunucu şema migrasyonları: `PRAGMA user_version` | Orta | Orta | EVET |
| 9 | Jenerik sync protokolü v2 (tekrarların kaldırılması) | Büyük | Yüksek | EVET (dikkatli) |
| 10 | Flutter DI: statik servislerden kurtulma | Büyük | Orta | EVET (kademeli) |
| 11 | Token'ı güvenli depoya taşıma | Küçük | Düşük | Opsiyonel |
| 12 | Sözleşme (contract) testleri; drift/OpenAPI değerlendirmesi | Orta | Düşük | Opsiyonel |

**Genel kurallar (her bölüm için geçerli):**
- Sunucu değişikliğinden sonra: `cd server; .\.venv\Scripts\python.exe -m pytest -q` yeşil.
- Flutter değişikliğinden sonra: `flutter analyze` temiz + `flutter test` yeşil (`C:\src\flutter\bin\flutter.bat`).
- Davranış değişikliği yalnızca ilgili bölümün amacı kadar; yan etki yok.
- Mevcut cihazlardaki eski veriler **kaybolmamalı**; tüm şema değişiklikleri geriye uyumlu migrasyonla.
- Not: Yedek saklama süresi `KEEP_COUNT = 1` **bilinçli karardır** (Google Drive'da ayrıca yedek var). DEĞİŞTİRME.

---

## BÖLÜM 1 — `backup.py` çoklu profil düzeltmesi (KRİTİK)

### Sorun
Çoklu profil geçişinde veritabanları `server/data/<profil-id>/app.db` altına taşındı ve kütüphaneler profil başına klasörlere (`pdf-profil2/` vb.) ayrıldı. `server/backup.py` hâlâ eski yolları (`data/app.db`, `pdf-kutuphane/`) yedekliyor → **asıl profil veritabanları yedeklenmiyor**, `/backup` endpoint'i yanıltıcı şekilde "ok" dönüyor.

### ADIM 1.1 — backup.py'yi config'e bağla
`backup.py`, `data/config.json`'ı okuyup profilleri dolaşsın. `main.py`'deki `_resolve_dir` mantığının aynısı (mutlak yol ise aynen, değilse `BASE` altında çöz):

```python
import json

def load_profiles():
    cfg_path = BASE / "data" / "config.json"
    if not cfg_path.exists():
        return []
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    profiles = []
    for r in cfg.get("profiles", []):
        pid = r["id"]
        pdf_dir = Path(r.get("pdf_dir", f"pdf-{pid}"))
        profiles.append({
            "id": pid,
            "db": BASE / "data" / pid / "app.db",
            "pdf_dir": pdf_dir if pdf_dir.is_absolute() else BASE / pdf_dir,
        })
    return profiles
```

### ADIM 1.2 — Yedekleme profil başına
- `backup_db` → her profil için `backups/YYYY-MM-DD/<profil-id>/app.db` (SQLite backup API aynen).
- `backup_pdfs` (`--pdfs`) → her profil için `backups/YYYY-MM-DD/<profil-id>/pdf-kutuphane.zip`.
- Eski tekil `data/app.db` hâlâ diskte duruyorsa onu da `backups/YYYY-MM-DD/_legacy/app.db` olarak kopyala (zararsız sigorta).
- `rotate()` aynen kalsın (`KEEP_COUNT = 1`).
- Config yoksa/boşsa eski davranışa düş (mevcut yollar) ve uyarı yaz.

### ADIM 1.3 — Test
`server/test/test_backup.py` ekle (pytest `tmp_path` kullan):
1. Geçici dizinde sahte `data/config.json` (2 profil) + her profil için içinde 1 tablo olan `app.db` + birkaç sahte PDF oluştur.
2. `backup.py`'nin fonksiyonlarını `BASE`'i parametreleyerek çağırılabilir yap (modül sabitlerini fonksiyon parametresine çevir; `main()` varsayılanı korur).
3. Çıktıda her iki profilin `app.db`'sinin ve zip'lerinin oluştuğunu doğrula.
4. `rotate` testinde 3 tarihli klasör oluştur, yalnızca en yenisinin kaldığını doğrula.

### ADIM 1.4 — RESTORE.md güncelle
`server/RESTORE.md`'deki geri yükleme adımlarını yeni yedek düzenine (`backups/TARIH/<profil>/...` → `data/<profil>/app.db`) göre güncelle.

### DOĞRULAMA
- [ ] `python backup.py --pdfs` gerçek kurulumda çalışıyor; `backups/BUGÜN/` altında her profil klasörü + db + zip var.
- [ ] pytest yeşil.
- [ ] Commit: `Faz 20.1: backup.py coklu profil duzeltmesi`

---

## BÖLÜM 2 — Sync pull imleci: sunucu saati (KRİTİK)

### Sorun
`/sync/pull?since_ms=` filtresi, push sırasında **istemcinin gönderdiği** `updated_at_ms`'e bakıyor; imleç ise sunucunun `server_time_ms`'i. Saati geride kalan bir cihazın push ettiği kayıtlar, diğer cihazın imlecinin gerisinde kalır ve **hiç pull edilmez**. Çözüm: sunucu her kabul ettiği satıra kendi saatiyle `received_at_ms` yazar; pull bu kolona göre filtreler. İstemci zamanı (`updated_at_ms`) yalnızca LWW çakışma çözümünde kullanılmaya devam eder.

### ADIM 2.1 — Kolon + backfill
`init_db()` içindeki migrasyon listesine ekle (mevcut try/except deseniyle):
```
ALTER TABLE positions          ADD COLUMN received_at_ms INTEGER
ALTER TABLE annotations        ADD COLUMN received_at_ms INTEGER
ALTER TABLE pdf_favorites      ADD COLUMN received_at_ms INTEGER
ALTER TABLE pdf_recent         ADD COLUMN received_at_ms INTEGER
ALTER TABLE reading_goals      ADD COLUMN received_at_ms INTEGER
ALTER TABLE bookmarks          ADD COLUMN received_at_ms INTEGER
ALTER TABLE pomodoro_sessions  ADD COLUMN received_at_ms INTEGER
```
Backfill (idempotent, migrasyonların hemen ardından):
```sql
UPDATE positions         SET received_at_ms = updated_at_ms WHERE received_at_ms IS NULL;
UPDATE annotations       SET received_at_ms = updated_at_ms WHERE received_at_ms IS NULL;
UPDATE pdf_favorites     SET received_at_ms = updated_at_ms WHERE received_at_ms IS NULL;
UPDATE pdf_recent        SET received_at_ms = opened_at_ms  WHERE received_at_ms IS NULL;
UPDATE reading_goals     SET received_at_ms = updated_at_ms WHERE received_at_ms IS NULL;
UPDATE bookmarks         SET received_at_ms = updated_at_ms WHERE received_at_ms IS NULL;
UPDATE pomodoro_sessions SET received_at_ms = updated_at_ms WHERE received_at_ms IS NULL;
```

### ADIM 2.2 — Yazan her yer `received_at_ms` doldursun
**Önemli:** Bu tablolara yalnızca `/sync/push` yazmıyor. `main.py`'de bu 7 tabloya `INSERT`/`UPDATE`/`REPLACE` yapan **tüm** yerleri bul (`grep "INSERT OR REPLACE INTO positions"` vb.) ve her birine `received_at_ms = <sunucu now_ms>` ekle. Bilinen yazıcılar: `/sync/push`, `PUT /position/{doc_id}`, `PUT /favorites/{doc_id}`, `POST /recent/{doc_id}`, `DELETE /recent/{doc_id}`, `PUT /reading-goal/{doc_id}`, `POST /annotations/{doc_id}`, `DELETE /annotations/{stroke_id}`, bookmark endpoint'leri, pomodoro endpoint'leri. Listeye güvenme — grep ile doğrula.

### ADIM 2.3 — `sync_pull` filtresini değiştir
- Handler'ın **en başında** `cursor_ms = int(time.time() * 1000)` al (sorgulardan ÖNCE; sorgu sırasında yazılan satır bir sonraki pull'da yakalansın).
- Tüm filtreleri `COALESCE(received_at_ms, updated_at_ms) > ?` biçimine çevir (pdf_recent için `COALESCE(received_at_ms, opened_at_ms)`).
- `deleted_docs` filtresi olduğu gibi kalır (`deleted_at_ms` zaten sunucu saatiyle yazılıyor).
- Yanıttaki `"server_time_ms"` artık `cursor_ms` (başta alınan değer) olsun.
- İstemcide değişiklik GEREKMEZ (`_lastPullMs` semantiği aynı; pull tarafındaki `updated_at_ms` LWW karşılaştırmaları aynen kalır).

### ADIM 2.4 — Regresyon testleri (bu bölümün en değerli çıktısı)
`server/test/test_sync.py` ekle; her test taze geçici DB ile (TestClient + geçici profil). Senaryolar:
1. **Saat kayması (asıl hata):** Cihaz A `since_ms=T` ile pull etmiş olsun. Cihaz B saati 1 saat geride, `updated_at_ms = T - 3600000` olan pozisyon push eder. A tekrar `since_ms=T` ile pull ettiğinde **kayıt gelmeli** (düzeltme öncesi gelmiyordu — önce testin kırmızı olduğunu görmek istersen filtreyi geçici eski haline getirip bak).
2. **LWW:** Aynı `doc_id` için önce yeni `updated_at_ms`, sonra eski push → eski reddedilir (accepted sayacı ve DB içeriğiyle doğrula).
3. **Eşit zaman damgası:** `updated_by_device` alfabetik büyük olan kazanır (mevcut kural).
4. **Tombstone reddi:** `deleted_docs`'ta olan doc için `updated_at_ms < deleted_at_ms` push → reddedilir.
5. **Pull imleci ilerleyişi:** push → pull (kayıt gelir) → dönen `server_time_ms` ile ikinci pull (kayıt gelmez).

### DOĞRULAMA
- [ ] Yeni testler dahil pytest yeşil.
- [ ] Gerçek kurulumda: telefonda sayfa çevir → PC 2 dk içinde aynı sayfaya geliyor (regresyon yok).
- [ ] Commit: `Faz 20.2: sync pull imleci sunucu saatine (received_at_ms) tasindi`

---

## BÖLÜM 3 — İstemci sync timeout'ları

### Sorun
`app/lib/sync_service.dart` içinde `_pushDirty`'deki `http.post` ve `_pull`'daki `http.get` timeout'suz. Bağlantı kopmasında sync süresiz askıda kalabilir; `_syncing == true` kaldığı sürece sonraki otomatik sync'ler sessizce atlanır.

### ADIM 3.1
- `_pushDirty` POST'una `.timeout(const Duration(seconds: 30))`.
- `_pull` GET'ine `.timeout(const Duration(seconds: 30))`.
- `api.dart`'ı da tara: `.timeout` olmayan istek var mı? (PDF/APK indirme hariç — onlar akışlı ve chunk-arası timeout'lu, dokunma.) Varsa 15–30 sn ekle.

### DOĞRULAMA
- [ ] `flutter analyze` temiz, `flutter test` yeşil.
- [ ] Uygulama açıkken sunucuyu durdur → sync durumu birkaç saniyede `offline/error`'a düşüyor, uygulama donmuyor; sunucu açılınca kendine geliyor.
- [ ] Commit: `Faz 20.3: sync push/pull timeout`

---

## BÖLÜM 4 — PDF cache tazeliği

### Sorun
`api.dart` → `downloadPdf`: cache isabeti yalnızca `file.lengthSync() == doc.size` ile. Sunucuda PDF aynı boyutta değişirse istemci eski dosyayı gösterir.

### ADIM 4.1
`PdfDoc.modified` zaten var; `LocalStore`'daki `pdf_docs` tablosunda da `modified` kolonu var. `downloadPdf`'te:
1. Cache isabeti kontrolüne `modified` ekle: yerel kayıttaki `modified` (LocalStore'dan oku ya da `markPdfCached`'e parametre ekleyip sakla) `doc.modified` ile eşit DEĞİLSE yeniden indir.
2. `markPdfCached` çağrısında güncel `doc.modified` kaydedilsin (gerekirse `LocalStore.markPdfCached` imzasına ekle; `pdf_docs.modified` upsert'i zaten liste senkronunda güncelleniyorsa onu kullan — önce kodu oku, çift yazma yapma).

### DOĞRULAMA
- [ ] Senaryo: PDF'i indir-aç → sunucuda dosyayı aynı boyutta farklı içerikle değiştir (metaveri `modified` değişir) → `/reindex` → uygulamada tekrar aç → **yeni içerik** geliyor.
- [ ] `flutter test` yeşil. Commit: `Faz 20.4: pdf cache modified karsilastirmasi`

---

## BÖLÜM 5 — Tombstone temizliği

### ADIM 5.1
Sunucu açılışında (lifespan içinde, her profil için `use_profile` ile) 90 günden eski tombstone'ları sil:
```sql
DELETE FROM deleted_docs WHERE deleted_at_ms < :now_ms - 90*24*60*60*1000;
DELETE FROM bookmarks          WHERE deleted_at_ms IS NOT NULL AND deleted_at_ms < :esik;
DELETE FROM pomodoro_sessions  WHERE deleted_at_ms IS NOT NULL AND deleted_at_ms < :esik;
DELETE FROM annotations        WHERE deleted_at_ms IS NOT NULL AND deleted_at_ms < :esik;
```
> Bilinen ödün: 90+ gün offline kalan bir cihaz silinmiş kaydı "diriltebilir". Tek kullanıcı + 2 dk'lık sync aralığı için kabul edilebilir; yorum olarak koda yaz.

### DOĞRULAMA
- [ ] Test: eski tarihli tombstone ekle → init/cleanup çağır → silinmiş; yeni tarihli duruyor.
- [ ] Commit: `Faz 20.5: 90 gunluk tombstone temizligi`

---

## BÖLÜM 6 — CI + run-tests.ps1

### ADIM 6.1 — `.github/workflows/ci.yml`
İki job:
- **flutter:** `subosito/flutter-action@v2` (yereldeki sürümü pinle: önce `flutter --version` çıktısına bak), `working-directory: app` ile `flutter pub get`, `flutter analyze`, `flutter test`.
- **server:** `actions/setup-python@v5` (yerel Python sürümünü pinle), `pip install -r server/requirements.txt pytest`, `server/` içinde `python -m pytest -q`.
- Tetikleyici: `push` + `pull_request` (master/main).
- Testlerden herhangi biri `ffprobe/ffmpeg` istiyorsa: o testlere `@pytest.mark.skipif(shutil.which("ffprobe") is None, ...)` ekle (CI'a ffmpeg kurma).

### ADIM 6.2 — `run-tests.ps1` yolu
Sabit `C:\src\flutter\bin\flutter.bat` yerine önce `Get-Command flutter`'ı dene, bulunamazsa mevcut sabit yola düş.

### DOĞRULAMA
- [ ] Push sonrası GitHub Actions'ta iki job da yeşil (repo GitHub'da değilse workflow dosyası commit'lenir, doğrulama ilk push'a kalır — bunu commit mesajında not et).
- [ ] Commit: `Faz 20.6: GitHub Actions CI + run-tests esnek flutter yolu`

---

## BÖLÜM 7 — `main.py`'yi modüllere bölme

### Hedef yapı
```
server/
├── main.py          <- app kurulumu, include_router, GERİYE UYUM re-export'ları
├── core.py          <- config yükleme, Profile, contextvar, db(), init_db, migrasyonlar,
│                       safe_folder_name/safe_library_path, doc_id_for, check_auth, sabitler
├── indexing.py      <- FTS/pdf metin indeksleme, PyMuPDF, ffmpeg/ffprobe yardımcıları
└── routers/
    ├── library.py   <- /library, /pdfs listesi, /search, klasör işlemleri
    ├── documents.py <- /pdfs/{id}/* (file, upload, move, copy, delete), /notes/*
    ├── videos.py    <- /videos*, /video-library
    ├── sync.py      <- /sync/*, /position, /annotations, /favorites, /recent,
    │                   /reading-goal, bookmark/pomodoro endpoint'leri
    ├── tasks.py     <- /tasks*
    └── misc.py      <- /health, /profile, /backup, /reindex, /app/version, /app/apk
```

### Kurallar
1. **Davranış ve URL'ler birebir aynı kalır.** Kod taşınır, değiştirilmez (import düzeltmeleri hariç).
2. Testler `import main` yapıyor ve `main.app`, `main.PROFILES`, `main.doc_id_for`, `main._fts_query` kullanıyor → `main.py` bunları `core`/`indexing`'ten **re-export** etsin; testlere dokunmak gerekmesin (dokunursan da minimal tut).
3. `uvicorn main:app` ve `belgelik-sunucu-arkaplan.vbs` çalışmaya devam etmeli.
4. Döngüsel import çıkarsa: router'lar yalnızca `core`/`indexing`'ten import eder, tersi asla.
5. Bölme sonrası `main.py` ~100 satırın altına inmeli.

### DOĞRULAMA
- [ ] pytest tamamı yeşil (mevcut testler değişmeden ya da minimal değişiklikle).
- [ ] Sunucuyu gerçek başlat, uygulamadan kütüphane/sync/video hızlı duman testi.
- [ ] Commit: `Faz 20.7: sunucu router modullerine bolundu`

---

## BÖLÜM 8 — Sunucu migrasyonları: `PRAGMA user_version`

### Sorun
Şema evrimi "ALTER dene, `OperationalError` yut" deseniyle; hangi sürümde olunduğu belirsiz, her açılışta tüm ALTER'lar denenir.

### ADIM 8.1
`core.py`'de numaralı migrasyon listesi:
```python
MIGRATIONS: list[Callable[[sqlite3.Connection], None]] = [
    _migration_1_legacy_consolidation,  # aşağıya bak
    # _migration_2_...  (bundan sonraki her şema değişikliği yeni fonksiyon)
]

def run_migrations(conn):
    current = conn.execute("PRAGMA user_version").fetchone()[0]
    for i, mig in enumerate(MIGRATIONS[current:], start=current + 1):
        mig(conn)
        conn.execute(f"PRAGMA user_version = {i}")
```
- `_migration_1_legacy_consolidation`: bugünkü `init_db` içeriğinin TAMAMI (CREATE IF NOT EXISTS + try/except ALTER blokları + backfill'ler + Bölüm 2'nin `received_at_ms`'i). Mevcut DB'ler `user_version=0` göründüğü için ilk açılışta bu çalışır — içerik zaten idempotent olduğundan güvenli; yeni kurulumda da tam şemayı kurar.
- Bundan SONRAKİ her şema değişikliği: yeni `_migration_N` fonksiyonu; try/except ALTER deseni artık **yasak** (migrasyon bir kez çalışır, çıplak ALTER yeterli).
- Bu kuralı `core.py`'de yorumla belgele.

### DOĞRULAMA
- [ ] Mevcut dolu DB kopyasıyla sunucu açılıyor, veri duruyor, `user_version=1`.
- [ ] Boş dizinle açılışta tam şema kuruluyor.
- [ ] Test: geçici DB'de `run_migrations` iki kez çağrılınca ikinci çağrı no-op.
- [ ] Commit: `Faz 20.8: numarali migrasyonlar (PRAGMA user_version)`

---

## BÖLÜM 9 — Jenerik sync protokolü v2 (BÜYÜK — dikkatli)

### Sorun
7 varlık tipi (position, annotation, favorite, recent, reading_goal, bookmark, pomodoro) için istemcide 7 payload builder + 7 dirty-clear döngüsü, sunucuda 7 kopya LWW bloğu var. Yeni varlık eklemek 6-7 dosyaya dokunmak demek.

### Tasarım (buna sadık kal)
- **Veri modeli DEĞİŞMEZ:** sunucuda ve istemcide varlık tabloları aynen kalır (UI ve mevcut GET endpoint'leri onlardan besleniyor). Jenerikleşen yalnızca **protokol ve kod**.
- **Sunucu:** `routers/sync.py`'de kayıt (registry) sözlüğü:
  ```python
  SYNC_ENTITIES = {
      "position":  SyncEntity(table="positions", pk=["doc_id"], ts_col="updated_at_ms",
                              cols=[...], legacy_cols={"updated_at": lambda d: d["updated_at_ms"] // 1000}),
      "annotation": SyncEntity(table="annotations", pk=["stroke_uuid"], ...),
      "favorite": ..., "recent": SyncEntity(..., ts_col="opened_at_ms", post_hook=_trim_recent_20),
      "reading_goal": SyncEntity(table="reading_goals", pk=["doc_id", "date"], ...),
      "bookmark": ..., "pomodoro": ...,
  }
  ```
  Tek jenerik `upsert_lww(conn, entity, data, now_ms)`: mevcut LWW kuralının birebir aynısı (ts büyükse kabul; eşitse `updated_by_device` alfabetik büyük kazanır; `deleted_docs` reddi `doc_id` içeren varlıklar için).
- **Yeni endpoint'ler:** `POST /sync/v2/push` gövde `{device_id, ops: [{entity, data{...}}]}` ve `GET /sync/v2/pull?since_ms=` yanıt `{ops: [{entity, data}], deleted_docs: [...], server_time_ms}`. Pull filtresi Bölüm 2'deki `received_at_ms` üzerinden, registry'den üretilen sorgularla.
- **v1 endpoint'leri KALIR** ve içeride aynı `upsert_lww`/registry'yi çağırır (kopya kod silinir). Böylece eski APK'lı cihaz bozulmaz. Tüm cihazlar güncellendikten bir sürüm sonra v1 kaldırılabilir (ayrı iş, şimdi değil).
- **İstemci:** `sync_service.dart`'ta varlık tanım listesi:
  ```dart
  class SyncEntityDef {
    final String name;              // 'position'
    final Future<List<Map<String, dynamic>>> Function() getDirty;
    final Future<void> Function(String key) clearDirty;
    final Map<String, dynamic> Function(Map<String, dynamic> row) toPayload;
    final Future<void> Function(Map<String, dynamic> data) applyRemote;
    final String Function(Map<String, dynamic> row) keyOf;
  }
  ```
  `_pushDirty`/`_pull` bu liste üzerinde tek döngü olur; 7'şer kopya blok silinir. `LocalStore`'daki `applyRemote*` fonksiyonları aynen kullanılır (imzaları uyacak şekilde sarmala).

### Adımlar
1. Önce **sunucu** registry + `upsert_lww` + v2 endpoint'leri; v1'i registry'ye delege et. Bölüm 2'deki tüm sync testleri hem v1 hem v2 için parametrize edilerek koşsun (aynı senaryolar iki protokolde de aynı sonucu vermeli).
2. Sonra **istemci** varlık listesi refaktörü + `/sync/v2`'ye geçiş.
3. Gerçek iki cihazla (veya PC + emülatör) uçtan uca duman testi: pozisyon, çizim, favori, yer imi, pomodoro sync'i.

### DOĞRULAMA
- [ ] pytest (v1+v2 parametrize) yeşil; `flutter analyze`/`flutter test` yeşil.
- [ ] `sync_service.dart` ve sunucu sync kodu belirgin şekilde kısaldı (kabaca yarıya inmeli).
- [ ] İki cihaz duman testi geçti. Commit: `Faz 20.9: jenerik sync protokolu v2`

---

## BÖLÜM 10 — Flutter DI: statiklerden kurtulma (kademeli)

### Sorun
`Api`, `LocalStore`, `SyncService`, `AppConfig` tamamen statik → widget testinde sahte (fake) verilemiyor; test kapsamı bu yüzden dar.

### Yaklaşım (pragmatik, tek seferde değil)
Ağır DI çatısı YOK (Riverpod vb. ekleme). Basit kompozisyon kökü:
```dart
class AppServices {
  final ApiClient api;
  final LocalStore store;
  final SyncService sync;
  AppServices({required this.api, required this.store, required this.sync});
  static late AppServices instance;   // main() kurar; testler fake ile kurar
}
```
Aşamalar (her biri ayrı commit olabilir):
1. **`Api` → `ApiClient` sınıfı:** statik metotları instance metoduna çevir; `baseUrl`/`token`'ı `AppConfig`'ten okumaya devam edebilir. Ekranlardaki `Api.x()` çağrıları `AppServices.instance.api.x()` olur. Sahte için `abstract class ApiClient` + `HttpApiClient` ayrımı yap.
2. **`SyncService` instance'a çevir** (`status` notifier'ı ile birlikte), `ApiClient`'ı ctor'dan alsın.
3. **`LocalStore` instance'a çevir** (en yayılmışı — en sona bırak; gerekirse bu adımı ayrı faza ertele ve bunu doc'a not düş).
4. **Kanıt testi:** `FakeApiClient` ile bir widget testi ekle — kütüphane ekranı sahte PDF listesini gösteriyor (`app/test/library_screen_test.dart`). Bu test, refaktörün amacına ulaştığının kanıtıdır; yazılamıyorsa refaktör eksik demektir.

### DOĞRULAMA
- [ ] `flutter analyze` temiz; TÜM eski testler + yeni fake'li widget testi yeşil.
- [ ] Uygulama davranışı değişmedi (okuyucu/sync/pomodoro duman testi).
- [ ] Commit(ler): `Faz 20.10a/b/c: ApiClient/SyncService/LocalStore DI`

---

## BÖLÜM 11 — (Opsiyonel) Token'ı güvenli depoya taşıma

`shared_preferences`'taki düz metin token'ı `flutter_secure_storage`'a taşı:
- Paketi ekle; `AppConfig.load()` önce secure storage'a bakar, yoksa prefs'ten okuyup secure'a taşır ve prefs'teki anahtarı siler (tek yönlü migrasyon).
- Windows/Android/iOS destekli; Linux'ta sorun çıkarsa prefs'e sessiz geri düşüş bırak.
- DOĞRULAMA: mevcut kurulumda güncelleme sonrası token kaybolmadan çalışmaya devam ediyor. Commit: `Faz 20.11: token flutter_secure_storage`

---

## BÖLÜM 12 — (Opsiyonel) Sözleşme testleri; drift/OpenAPI kararı

### ADIM 12.1 — Sözleşme (contract) fixture'ları — ÖNERİLEN
Sunucu ile istemci JSON modellerinin sessizce ayrışmasına karşı hafif çözüm (tam OpenAPI codegen yerine):
1. `contract/` klasörü: her sync varlığı + `PdfDoc`/`VideoDoc` için örnek JSON dosyaları (`position.json`, `pdf_doc.json`, ...). İçerik: tüm alanlar dolu gerçekçi örnek.
2. **Sunucu testi:** endpoint yanıtındaki alan kümesinin fixture'la eşleştiğini doğrular (fazla/eksik alan → kırmızı).
3. **Dart testi:** aynı fixture'ları `fromJson` ile parse eder (`app/test/contract_test.dart`); alan silinir/tip değişirse kırmızı.
4. CI ikisini de zaten koşuyor → sözleşme kayması PR'da yakalanır.

### ADIM 12.2 — drift ve OpenAPI codegen: KARAR NOTU
Bunları **şimdi YAPMA**; değerlendirme notu olarak buraya kaydediyorum:
- **drift (yerel DB):** Tip güvenliği iyi olurdu ama `local_store.dart` çalışıyor ve test edilebilirlik Bölüm 10 ile çözülüyor. Mevcut şemayı drift'e devralmak (schema adoption) riskli ve getirisi düşük. Yalnızca `local_store.dart` ciddi büyümeye devam ederse yeniden değerlendir.
- **OpenAPI → Dart codegen:** FastAPI şeması hazır ama üreteçler `dio` bağımlılığı ve üretilmiş kod yükü getirir; tek kullanıcılı projede sözleşme testleri (ADIM 12.1) aynı riski çok daha ucuza kapatır.

### DOĞRULAMA
- [ ] Fixture'lar + iki taraflı testler yeşil; kasıtlı bir alan bozunca iki tarafta da kırmızı (deneyip geri al).
- [ ] Commit: `Faz 20.12: sozlesme testleri (contract fixtures)`

---

## BİTİŞ — genel doğrulama

- [ ] `run-tests.ps1` → `HEPSI YESIL`.
- [ ] Gerçek kullanım duman testi: PDF aç/oku/çiz, sayfa sync (iki cihaz), pomodoro, program, video, not editörü, arama, `/backup`.
- [ ] `ROADMAP.md` faz tablosuna satır ekle: `| 20 | Sağlamlaştırma + refaktör | backup fix, sync imleci, CI, router bölme, sync v2, DI | docs/FAZ-20-... |`
- [ ] Sürüm: `pubspec.yaml` sürümünü artır (mevcut gelenek: minor +1, build +1).

## Ajan kuralları
1. Bölüm sırası zorunlu: 1→2→…; her bölüm ayrı commit; DOĞRULAMA geçmeden ilerleme.
2. Bölüm 2 ve 9 veri bütünlüğüne dokunur: değişiklik ÖNCESİ `python backup.py --pdfs` çalıştır (Bölüm 1 bittiği için artık doğru yedek alır).
3. Davranış değişikliği yalnızca ilgili bölümün amacı kadar; "hazır elim değmişken" düzeltmesi yapma.
4. `KEEP_COUNT = 1` bilinçli karar — değiştirme.
5. Büyük bölümlerde (7, 9, 10) kırılma/riskli belirsizlik görürsen durup sor; varsayımla ilerleme.
