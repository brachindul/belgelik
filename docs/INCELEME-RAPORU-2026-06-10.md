# İnceleme Raporu ve Düzeltme Talimatları — 10.06.2026

> Bu dosya, projenin tam incelemesi sonucu bulunan hataların ve geliştirme önerilerinin
> **uygulayıcı ajan (Codex) için talimat** formatında dökümüdür.
> Çalışma yöntemi: ROADMAP.md kurallarına uy; her maddeyi ayrı, test edilmiş bir değişiklik
> olarak yap; belirsizlikte sor. Sunucu testleri `server/test_main.py` içinde, `run-tests.ps1` ile koşulur.
> Öncelik sırası: A → B → C → D.

---

## A. KRİTİK HATALAR (veri kaybı / yanlış davranış)

### A1. S Pen tuşu: geçici silgi sonrası istenmeyen kalem↔fosforlu geçişi

**Dosya:** `app/lib/screens/reader_screen.dart` (yaklaşık satır 1498–1655, `Listener` bloğu)

**İstenen davranış:**
- S Pen tuşuna **basılı tutup ekrana temas** edilirse → temas süresince **geçici silgi** (bu çalışıyor).
- S Pen tuşuna **havadayken bas-çek** yapılırsa (ekrana hiç temas etmeden) → kalem ↔ fosforlu kalem **mod değişimi**.
- Geçici silgi kullanımından sonra tuş bırakıldığında **mod DEĞİŞMEMELİ** (mevcut hata: değişiyor).

**Hatanın kök nedeni:**
Mevcut kod tek seferlik `_suppressNextStylusButtonToggle` bayrağı kullanıyor.
Temas sırasında hover olayları gelmez; Samsung/Android'de kalem ekrandan kalktıktan
hemen sonraki ilk hover paketlerinde `buttons` alanı tuş hâlâ basılıyken **anlık olarak 0**
raporlanabiliyor. Bu sahte "bırakıldı" geçişi suppress bayrağını tüketiyor; sonraki hover
paketi tuşu yine "basılı" gösteriyor ve kullanıcı tuşu gerçekten bıraktığında bu yeni bir
bas-çek sanılıp `onStylusButtonTap()` (mod değişimi) tetikleniyor.

**Çözüm — tek seferlik bayrak yerine "tuş basma seansı" takibi + zaman koruması:**

`_AnnotationLayerState` içinde şu alanları tut:

```dart
bool _stylusButtonHoverDown = false;   // mevcut alan kalsın
bool _buttonEpisodeHadContact = false; // bu basma seansında ekrana temas oldu mu?
int _lastStylusUpMs = 0;               // son pointerUp/Cancel zamanı (ms)
```

`_suppressNextStylusButtonToggle` alanını **kaldır**.

Mantık:

1. `onPointerHover` içinde (`_isStylus(e)` kontrolünden sonra):
   - `pressed = _hasStylusButton(e)` hesapla.
   - **Basma başlangıcı** (`!_stylusButtonHoverDown && pressed`):
     `_stylusButtonHoverDown = true; _buttonEpisodeHadContact = false;`
   - **Bırakma** (`_stylusButtonHoverDown && !pressed`):
     - `final now = DateTime.now().millisecondsSinceEpoch;`
     - Eğer `now - _lastStylusUpMs < 300` ise: bu, temas sonrası sahte/erken geçiş olabilir →
       **toggle yapma**, ayrıca `_stylusButtonHoverDown`'ı `false` yapma (sahte 0 paketini tamamen yok say; bir sonraki hover gerçeği gösterecek).
     - Aksi halde: `_stylusButtonHoverDown = false;` ve **yalnızca**
       `!_buttonEpisodeHadContact` ise `widget.onStylusButtonTap();` çağır.
2. `onPointerDown` içinde: `_hasStylusButton(e)` ise
   `_buttonEpisodeHadContact = true; _stylusButtonHoverDown = true;`
   (suppress bayrağı satırlarını bu ikisiyle değiştir; silgi/çizim dallanması aynı kalsın).
3. `onPointerUp` ve `onPointerCancel` içinde:
   `_lastStylusUpMs = DateTime.now().millisecondsSinceEpoch;` ekle (mevcut işlevler aynı kalsın).

**Test (manuel, Android cihazda):**
- Tuşu basılı tutup birden çok silme vuruşu yap, tuşu bırak → mod DEĞİŞMEMELİ.
- Havada bas-çek (temassız) → mod değişmeli (pen ↔ highlight).
- Silgi modundayken tuşla silme → davranış bozulmamalı.

---

### A2. Sunucu: `bookmarks` tablosu taşıma/kopyalama/silme/yeniden adlandırmada unutulmuş

**Dosya:** `server/main.py`

`move_pdf`, `rename_folder`, `delete_pdf`, `copy_pdf` fonksiyonları
`positions, annotations, pdf_favorites, pdf_recent, reading_goals` tablolarında `doc_id`
güncelliyor/siliyor ama **`bookmarks` tablosuna hiç dokunmuyor**. Sonuç: PDF taşınınca veya
klasör yeniden adlandırılınca o PDF'in tüm yer imleri kayboluyor (eski doc_id'de yetim kalıyor).

**Çözüm:**
1. Modül seviyesinde tek bir liste tanımla:
   ```python
   DOC_ID_TABLES = ["positions", "annotations", "pdf_favorites", "pdf_recent", "reading_goals", "bookmarks"]
   ```
2. `move_pdf`, `rename_folder`, `delete_pdf` ve `delete_folder` içindeki elle yazılmış
   UPDATE/DELETE bloklarını bu liste üzerinde döngüyle değiştir:
   ```python
   for table in DOC_ID_TABLES:
       conn.execute(f"UPDATE {table} SET doc_id = ? WHERE doc_id = ?", (new_id, old_id))
   ```
   (silme uçlarında `DELETE FROM {table} WHERE doc_id = ?`).
3. `copy_pdf` için: bookmarks kopyalanacaksa yeni `bookmark_uuid` üretilmeli
   (`secrets.token_hex` vb.) — PRIMARY KEY çakışmasın. Kopyalamada bookmark taşımak
   zorunlu değil; en azından mevcut beş tablo + bilinçli bir karar dokümante edilsin.

**Test:** `test_main.py`'a ekle: bookmark oluştur (sync/push ile) → PDF'i taşı →
`sync/pull` sonucunda bookmark'ın **yeni** doc_id ile gelmesini doğrula. Aynısını
klasör yeniden adlandırma için.

---

### A3. Sunucu: taşıma/yeniden adlandırma FTS arama indeksini güncellemiyor

**Dosya:** `server/main.py`

`move_pdf` ve `rename_folder` sonrası `pdf_text` ve `pdf_index_meta` tabloları eski
`doc_id` ve eski `relative_path` ile kalıyor. İçerik araması (`/search`) taşınan dosya
için artık 404 veren eski doc_id döndürüyor. `delete_pdf`/`delete_folder` da indeks
kayıtlarını silmiyor.

**Çözüm:** Dosya içeriği değişmediği için yeniden indekslemeye gerek yok; meta güncelle:
- `move_pdf` ve `rename_folder` içinde, doc_id transferi yapılan yerde ek olarak:
  ```python
  conn.execute("UPDATE pdf_text SET doc_id = ? WHERE doc_id = ?", (new_id, old_id))
  conn.execute(
      "UPDATE pdf_index_meta SET doc_id = ?, relative_path = ?, name = ? WHERE doc_id = ?",
      (new_id, new_rel, new_name, old_id),
  )
  ```
  (`pdf_text` FTS5 tablosunda doc_id UNINDEXED sütun olduğu için UPDATE çalışır.)
- `delete_pdf` ve `delete_folder` içinde `pdf_text` ve `pdf_index_meta` satırlarını da sil.

**Test:** PDF indeksle → taşı → `/search` sonucunun yeni doc_id + yeni relative_path
döndürdüğünü doğrula.

---

### A4. İstemci: sync pull hataları sessizce yutuluyor + `last_pull_ms` erken ilerletiliyor

**Dosya:** `app/lib/sync_service.dart` (`_pull`, satır ~214–267)

İki sorun:
1. `_pull` içindeki `catch (_) {}` her hatayı gizliyor; `syncNow` pull patlasa bile
   durumu `idle` gösteriyor.
2. Kayıtlar tek tek yerel DB'ye yazılırken ortada bir hata olursa `catch` bloğuna düşülüyor
   ama o ana kadar `_lastPullMs` ilerletilmemiş olsa da, kısmi yazım + sonraki başarılı pull'da
   `server_time_ms`'e atlama nedeniyle aradaki kayıtlar **bir daha hiç çekilmez** (kalıcı kayıp riski).

**Çözüm:**
- `_pull`'ı `Future<bool>` yap; HTTP ≠ 200 veya exception'da `false` döndür ve
  exception'ı `rethrow` etme ama yutma da — `debugPrint` ile logla.
- `_lastPullMs` ve `setSyncState('last_pull_ms', ...)` satırları **yalnızca tüm uygulama
  döngüleri hatasız bittiyse** çalışsın (zaten fonksiyon sonunda; kritik olan exception
  durumunda çalışmaması — mevcut yapıda doğru, koru).
- `syncNow` içinde `_pushDirty()` ve `_pull()` dönüş değerlerini kontrol et; herhangi biri
  `false` ise `_refreshStatus(SyncPhase.error)` çağır, `idle` değil.

**Test:** Sunucuyu kapatıp `syncNow` çağır → status `offline`; sunucu 500 döndürürken →
status `error` olmalı.

---

## B. SAĞLAMLIK / GÜVENLİK PÜRÜZLERİ

### B1. Sunucu: `find_pdf_by_id` her çağrıda tüm diski tarıyor

**Dosya:** `server/main.py:246`

Her çağrı `PDF_DIR.rglob("*.pdf")` ile tüm kütüphaneyi gezip her dosya için SHA1 hesaplıyor.
`/favorites` ve `/recent` bunu **döngü içinde** çağırıyor (N kayıt × tam disk taraması).

**Çözüm:** Önce `pdf_index_meta`'dan bak:
```python
def find_pdf_by_id(doc_id: str) -> Path | None:
    with db() as conn:
        row = conn.execute(
            "SELECT relative_path FROM pdf_index_meta WHERE doc_id = ?", (doc_id,)
        ).fetchone()
    if row:
        p = PDF_DIR / row["relative_path"]
        if p.exists():
            return p
    # indeks bayatsa eski yönteme düş (yedek yol)
    for path in PDF_DIR.rglob("*.pdf"):
        ...
```
Ek olarak `/favorites` ve `/recent`'ta doc_id → path eşlemesini tek sorguyla toplu çek.

### B2. Sunucu: SQLite bağlantıları kapatılmıyor + WAL kapalı

`with db() as conn` SQLite'ta yalnızca transaction'ı commit eder, bağlantıyı **kapatmaz**.
Her istekte yeni bağlantı açılıp GC'ye bırakılıyor (dosya tanıtıcısı sızıntısı).

**Çözüm:**
- `db()` fonksiyonunu `contextlib.contextmanager` yap: `yield conn` → `finally: conn.close()`
  (commit için `with conn:` iç blok veya `conn.commit()`); **veya** tüm çağrı yerlerini
  `with closing(db()) as conn, conn:` kalıbına çevir. Mevcut `with db() as conn` kullanım
  şekli korunarak en az dokunuşlu çözüm contextmanager'dır.
- Bağlantı açılışında bir kez `conn.execute("PRAGMA journal_mode=WAL")` ve
  `PRAGMA busy_timeout=5000` ayarla.

### B3. Sunucu: yüklemede boyut sınırı ve PDF doğrulaması yok

`upload_new_pdf` ve `upload_pdf_file` tüm gövdeyi RAM'e alıyor ve içerik kontrolü yapmıyor.

**Çözüm:** Gövde okunduktan sonra:
- `len(data) > 500 * 1024 * 1024` ise 413 döndür (sınır makul seçilebilir).
- `not data.startswith(b"%PDF")` ise 400 "Gecersiz PDF" döndür.

### B4. Sunucu: `/sync/push` `recent` kayıtlarında LWW kontrolü ve 20 kayıt budaması yok

Diğer beş veri türünde "son yazan kazanır" karşılaştırması var; `recent`'ta koşulsuz
`INSERT OR REPLACE` yapılıyor ve `mark_recent`'taki "son 20" budaması uygulanmıyor → tablo sınırsız büyür.

**Çözüm:** `recent` döngüsüne `opened_at_ms` karşılaştırması ekle (eski kayıt yeniyse atla)
ve döngü sonunda `mark_recent`'taki budama SQL'ini bir kez çalıştır.

### B5. Sunucu: silinen PDF için tombstone yok

`delete_pdf` ilgili satırları hard-delete ediyor. Diğer cihaz offline'dayken o PDF'e not
aldıysa, sync'te notlar sunucuya geri itilir (hayalet kayıt).

**Çözüm (basit):** `deleted_docs (doc_id TEXT PRIMARY KEY, deleted_at_ms INTEGER)` tablosu
ekle; `delete_pdf`/`delete_folder` buraya yazsın; `/sync/push`'ta gelen kayıtların doc_id'si
bu tablodaysa ve `updated_at_ms < deleted_at_ms` ise reddet; `/sync/pull` yanıtına
`deleted_docs` listesi ekle, istemci bu doc_id'lerin yerel kayıtlarını temizlesin.
(İstemci tarafı: `local_store.dart`'a karşılık gelen temizlik fonksiyonu.)

### B6. İstemci: `deviceId` üretimi çakışabilir

**Dosya:** `app/lib/config.dart:41` — `'cihaz-${timestamp % 100000}'`.
İki cihaz aynı değeri üretebilir; LWW eşitlik kırıcısı cihaz adına dayandığı için sync sessizce bozulur.

**Çözüm:** Rastgele üret: `'cihaz-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0xFFFFFF).toRadixString(16)}'`
veya `uuid` paketi. Mevcut kayıtlı deviceId'ler korunur (sadece boşsa üretiliyor).

### B7. Sunucu: token karşılaştırması sabit zamanlı değil

`check_auth` içinde `x_auth_token != TOKEN` yerine
`not secrets.compare_digest(x_auth_token, TOKEN)`. Tailscale arkasında pratik risk düşük; tek satır.

---

## C. PERFORMANS / KULLANILABİLİRLİK GELİŞTİRMELERİ

### C1. Açılışta otomatik arama indeksi tazeleme
`main.py`'da uygulama startup'ında (`@app.on_event("startup")` veya lifespan) `reindex_all`'ı
arka plan thread'inde çalıştır. Şu an yeni kopyalanan PDF'ler manuel `/reindex` çağrılana
kadar aramada görünmüyor.

### C2. Sync'i olay tetiklemeli yap
`sync_service.dart` 30 sn sabit `Timer.periodic` kullanıyor. Buna ek/yerine:
sayfa değişiminde (position kaydında) debounce'lu `syncNow`, uygulama öne gelince
(`AppLifecycleState.resumed`) bir kez `syncNow`. Periyodik aralık 30 sn → 2-5 dk'ya çıkarılabilir
(pil tasarrufu).

### C3. `reader_screen.dart`'ı bölmek (56 KB tek dosya)
Davranış değiştirmeden parçala: `annotation_layer.dart` (Listener + painter sınıfları),
`reader_toolbar.dart`, `night_filter.dart`. ROADMAP-V2 teknik borç fazına uygun.

### C4. `updated_at` / `updated_at_ms` ikiliğini temizlemek
Sunucuda her tabloda iki zaman sütunu ve her sorguda `COALESCE`/`or` mantığı taşınıyor.
Tek seferlik migration: `updated_at_ms IS NULL` satırları `updated_at * 1000` ile doldur,
sonra kod yollarında yalnızca `_ms` kullan. (Eski sütunlar şemada kalabilir, kod sadeleşir.)

### C5. Yedeklemeyi zamanlamak
`backup.py` yalnızca `/backup` endpoint'iyle elle tetikleniyor. Windows Görev Zamanlayıcı'ya
günlük görev ekle (örn. her gece 03:00, `python backup.py --pdfs`) ve `RESTORE.md`'ye not düş.

---

## D. TEST GEREKSİNİMLERİ

Her A ve B maddesi için `server/test_main.py`'a regresyon testi eklenmeli (S Pen hariç —
o manuel cihaz testi gerektirir, test adımları A1'de yazılı). Özellikle:
- A2: taşıma/yeniden adlandırma sonrası bookmark'ların yeni doc_id'de olması.
- A3: taşıma sonrası `/search` sonuçlarının güncel olması.
- B4: `recent` push'ta eski zaman damgasının yeniyi ezmemesi + 20 kayıt sınırı.
- B5: silinen doc'a ait push'un reddedilmesi.

Tüm değişikliklerden sonra: `cd server; ..\run-tests.ps1` yeşil olmalı ve
`flutter analyze` (app klasöründe) hatasız geçmeli.
