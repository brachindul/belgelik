# Mevzuat Okuyucu + Aralıklı Tekrar Modülleri — Yol Haritası (Faz 21–28)

> Bu dosya, belgelik'e eklenecek iki yeni modülün **referans anayasasıdır**:
> **A) Offline Mevzuat Okuyucu** ve **B) Aralıklı Tekrar (Spaced Repetition)**.
> Kod yazan ajan, çalışmaya başlamadan önce bu dosyayı ve kök `ROADMAP.md`'yi okumalıdır.
> Ana yol haritası Faz 20'de tamamlandığı için bu modüller Faz 21'den devam eder.

---

## 0. Amaç ve Kapsam

- **Tek kullanıcı.** Play Store yok, üyelik yok, çoklu kullanıcı yok. Sadelik > özellik bolluğu.
- **A modülü:** Seçili kanunların tam metnini PC'den çekip yapılandırılmış (madde bazlı)
  halde tablete indiren, tamamen **offline** okunabilen, aranabilir, notlanabilir mevzuat okuyucu.
- **B modülü:** SM-2 tabanlı flashcard tekrar sistemi; kartlar elle veya PC'de AI ile üretilir,
  AI kartları **onay kuyruğundan** geçmeden tekrar döngüsüne giremez.
- İki modülün ortak temeli **kanonik madde referansı**dır (bkz. Bölüm 2). Bu yüzden faz sırası
  **21 → 22 → 25 → 26 → 27 → 23 → 24 → 28** şeklinde de yürütülebilir; tek katı kural:
  21 ve 22, 28'den önce bitmelidir; 25–27 ise 21–22'ye bağımlı değildir (PDF kaynaklı kartlarla çalışır).

### Kapsam dışı (yapılmayacak)
- İçtihat/karar arama (bunun için Emsal-mcp + AgentBridge cowork zaten var).
- Mevzuat metninin uygulama İÇİNDEN internetten çekilmesi (tablet yalnızca sunucudan bundle indirir).
- FSRS algoritması (ilk sürümde SM-2; `review_log` ham tutulduğu için sonradan geçiş mümkün).
- Kart paylaşımı, deck import/export (Anki uyumluluğu vb.).

---

## 1. Mevcut Altyapı (DEĞİŞTİRİLMEYECEK — üzerine inşa edilecek)

| Bileşen | Yer | Bu planda kullanımı |
|---|---|---|
| FastAPI sunucu | `server/main.py` + `server/routers/` | Yeni router'lar: `legislation.py`, `cards.py` |
| Jenerik sync v2 | `server/routers/sync.py` → `SyncSpec` registry | Yeni varlıklar SyncSpec olarak eklenir; LWW + tombstone + `received_at_ms` davranışı birebir korunur |
| Contract şemaları | `contract/*.json` | Yeni: `legislation_doc.json`, `madde_note.json`, `card.json`, `review_state.json`, `review_log.json` |
| Offline-first sync | Faz 9 (`docs/FAZ-9-OFFLINE-FIRST-SYNC.md`) | Yeni varlıklar aynı kuyruğa biner |
| Numaralı migrasyonlar | Faz 20 düzeni | Her yeni tablo numaralı migration ile gelir |
| Flutter istemci | `app/lib/` | Yeni ekranlar mevcut navigasyon/tema düzenine uyar |
| Kimlik doğrulama | `X-Auth-Token` header, Tailscale ağı | Aynen |
| Emsal-mcp | `<EMSAL-MCP-KLASORU>` (v5.x) | PC tarafı mevzuat ingest'inin TEK veri kaynağı |

> **Ajan talimatı:** SyncSpec eklerken `server/routers/sync.py` içindeki mevcut
> `positions` / `annotations` örneklerini birebir şablon al. `pull_where` her zaman
> `COALESCE(received_at_ms, updated_at_ms, ...)` desenini korur. Yeni alan adları
> `updated_at_ms`, `updated_by_device`, `deleted_at_ms`, `received_at_ms` kalıbından sapmaz.

---

## 2. Kanonik Madde Referansı (ortak temel — ÖNCE BU KARARLAŞTIRILDI)

Her madde tek bir string ID ile anılır. Bu ID mevzuat okuyucuda navigasyon anahtarı,
tekrar modülünde kart-kaynak bağıdır; notlar ve kartlar bu ID üzerinden maddeye bağlanır.

```
Biçim:  <mevzuat_no>/m.<madde_no>[/f.<fıkra_no>]
Örnek:  6098/m.49        → TBK madde 49
        6100/m.341/f.2   → HMK m.341 fıkra 2
        2709/m.36        → Anayasa m.36 (Anayasa'nın mevzuat no'su 2709)
Özel maddeler:
        6098/m.gecici-1  → geçici madde 1
        6098/m.ek-3      → ek madde 3
        6098/m.mulga-50  → mülga madde (metin korunur, "mülga" bayrağıyla)
```

Kurallar:
1. ID **hiçbir zaman** yeniden numaralanmaz; kanun değişse de aynı maddenin ID'si sabittir.
2. Fıkra düzeyi opsiyoneldir; not/kart en az madde düzeyine bağlanır.
3. Parse edilemeyen referanslar (ör. mükerrer maddeler) `m.mukerrer-<no>` olarak ele alınır;
   ilk gerçek örnekte format bu dosyaya işlenerek genişletilir.

---

## 3. MODÜL A — Offline Mevzuat Okuyucu

### [x] Faz 21 — Mevzuat Ingest ve Parser (yalnız PC / sunucu tarafı)

**Amaç:** Emsal-mcp'den çekilen ham kanun metnini, madde bazlı yapılandırılmış ve
versiyonlanmış olarak sunucu SQLite'ına yazmak. Bu fazda Flutter'a DOKUNULMAZ.

**Yapılacaklar:**
1. `server/mevzuat_ingest.py` script'i:
   - Girdi: mevzuat no listesi (başlangıç seti: **2709 Anayasa, 4721 TMK, 6098 TBK,
     6102 TTK, 6100 HMK, 5237 TCK, 5271 CMK, 2577 İYUK, 2004 İİK**).
   - Kaynak: Emsal-mcp'nin mevzuat araçları (`get_legislation` MCP aracı veya CLI karşılığı).
     Komut arayüzünü `Emsal-mcp/docs/` ve `emsal-mcp --help` üzerinden DOĞRULA; varsayma.
   - Emsal-mcp kırmızı çizgisi geçerlidir: tam metni olmayan mevzuat ingest EDİLMEZ, uydurulmaz.
2. Parser (`server/mevzuat_parser.py`, saf Python, ağ erişimi yok):
   - Ham metin → `kanun → kısım/bölüm başlıkları → madde → fıkra` ağacı.
   - Madde başlığı, numarası (geçici/ek/mükerrer/mülga dahil), fıkra ayrımı.
   - Değişiklik notlarını (`(Değişik: 22/7/2020-7251/1 md.)`, `(Mülga: ...)` kalıpları)
     metinden ayırıp madde metadata'sına koy; metni bozma.
3. Yeni tablolar (numaralı migration ile):
   - `legislation(mevzuat_no PK, ad, kisa_ad, tur, snapshot_version, ingested_at_ms, raw_hash)`
   - `legislation_article(id PK = kanonik madde ID, mevzuat_no, sira, baslik, madde_no_raw,
     metin, metadata_json, snapshot_version)`
   - `legislation_snapshot(mevzuat_no, snapshot_version, raw_text, created_at_ms)` — diff için ham metin saklanır.
4. **Snapshot testleri:** her kanun için `server/test/` altına parser round-trip testi:
   madde sayısı, ilk/son madde, bilinen 3–5 örnek maddenin tam metni sabitlenir (golden file).
   Parser değişince fark bilinçli onaylanır.

**Başarı kriteri:** 9 kanunun tamamı hatasız parse edilir; her biri için madde sayısı
resmi metinle elle karşılaştırılıp golden file'a işlenir; `pytest` yeşil.

**Riskler:** mevzuat.gov.tr metin formatı düzensizdir — bu fazın %80'i parser'dır.
Ajan, parse edemediği kalıbı SESSİZCE atlamaz; hata listeler ve testte görünür kılar.

---

### [x] Faz 22 — Sunucu API + Bundle Sync + Flutter Okuyucu (MVP sınırı)

**Amaç:** Tabletin kanun paketlerini indirip tamamen offline okuyabilmesi ve arayabilmesi.

**Yapılacaklar:**
1. `server/routers/legislation.py`:
   - `GET /legislation` → kanun listesi (ad, madde sayısı, snapshot_version, boyut).
   - `GET /legislation/{mevzuat_no}/bundle` → tek JSON bundle (madde ağacı + metadata).
     PDF indirme akışındaki (Faz 1/9) cache/versiyon desenini kopyala:
     istemci `snapshot_version` değişmedikçe yeniden indirmez.
2. Flutter tarafı:
   - Kütüphane ekranına "Mevzuat" sekmesi/bölümü; kanun indir/güncelle/sil.
   - Bundle → cihazda `sqflite` tablolarına açılır; **FTS5** sanal tablosu ile
     tüm indirilen kanunlarda offline tam metin arama (madde bazlı sonuç listesi).
   - Okuyucu ekranı: içindekiler ağacı (kısım/bölüm) → madde listesi → madde görünümü
     (fıkra numaralı; değişiklik notları katlanabilir dipnot).
   - Madde görünümünden kanonik ID kopyalanabilir (uzun bas → "6098/m.49 kopyalandı").
3. Son kalınan madde pozisyonu `position` desenine benzer şekilde sync'lenir
   (yeni SyncSpec: `legislation_position`, pk = mevzuat_no).

**Başarı kriteri:** Uçak modundaki tablette TBK açılır, "sebepsiz zenginleşme" aranır,
m.77'ye gidilir; PC kapalıyken hiçbir işlev bozulmaz. **MVP = Faz 21 + 22.**

---

### [x] Faz 23 — Madde Notları, Yer İmleri, Vurgu

**Amaç:** PDF tarafındaki işaretleme deneyiminin madde bazlı karşılığı.

**Yapılacaklar:**
1. Contract: `madde_note.json` — alanlar `annotation.json` kalıbını izler:
   `note_uuid, madde_ref, kind(highlight|note|bookmark), renk, secili_metin_araligi,
   text, updated_at_ms, updated_by_device, deleted_at_ms`.
2. SyncSpec kaydı (`madde_notes` tablosu, tombstone'lu) + numaralı migration.
3. Flutter: madde görünümünde metin seçimi → vurgu/not; kanun bazlı not listesi ekranı;
   yer imi verilen maddeler içindekiler ağacında işaretli.

**Başarı kriteri:** Tablette alınan not Windows istemcide görünür (LWW ile);
silinen not tombstone ile diğer cihazdan da düşer.

---

### [x] Faz 24 — Atıf Linkleme + Değişiklik Takibi

**Amaç:** Okuyucuyu "PDF'den iyi" yapan iki özellik.

**Yapılacaklar:**
1. **Atıf linkleme (istemci tarafı, render sırasında):**
   - Regex kalıpları: `bu Kanunun 12 nci maddesi`, `6100 sayılı Kanunun 353 üncü maddesi`,
     `aynı maddenin ikinci fıkrası` (bu sonuncusu v1'de kapsam dışı bırakılabilir — işaretle).
   - Eşleşen ifade tıklanabilir olur → kanonik ID'ye çözülür → madde görünümüne zıplar.
     Hedef kanun cihazda indirilmemişse "indir" önerisi gösterilir.
   - Yanlış pozitif riskine karşı: link üretimi yalnız görüntülemede, metni asla değiştirmez.
2. **Resmî Gazete izleyici (PC tarafı):**
   - `server/mevzuat_watch.py`: izlenen kanunlar için Emsal-mcp RG kaynağını tarar
     (haftalık; Windows Görev Zamanlayıcı girdisi `server/RESTORE.md`'ye eklenir).
   - Değişiklik saptanırsa: yeniden ingest → `snapshot_version++` → değişen maddelerin
     diff'i `legislation_change(madde_ref, old_version, new_version, degisiklik_ozeti)` tablosuna.
3. Flutter: "Değişen maddeler" listesi; değişen maddeye bağlı not/kart varsa üzerine
   **"güncelliğini yitirmiş olabilir"** rozeti (kart tarafı Faz 28'de tamamlanır).
   Madde görünümünde "önceki sürümle karşılaştır" (satır bazlı basit diff yeterli).

**Başarı kriteri:** Elle tetiklenen sahte bir değişiklik senaryosunda (test fixture)
diff üretilir, rozet görünür, karşılaştırma ekranı iki sürümü gösterir.

---

## 4. MODÜL B — Aralıklı Tekrar (Spaced Repetition)

> **MODÜL B SÖKÜLDÜ (2026-07-24).** Faz 25-28 uygulandı, cihazda çalıştı, sonra
> kullanıcı kararıyla tamamen kaldırıldı: AI üretimi kartların pratik katkısı
> hedeflenen seviyede değildi ve müessir PDF'leri zaten çıkmış soruların tamamını
> (çözümleriyle) içeriyor — doğal çalışma döngüsü PDF okuyucuda. Kod sökümü ileri
> migration'larla yapıldı (server migration 7, app DB v13: tablolar DROP).
> Modül A (Faz 21-24, mevzuat okuyucu) yerinde duruyor.


### [İPTAL] Faz 25 — Veri Modeli + Sync + Manuel Kart CRUD

**Amaç:** Kart altyapısını uçtan uca kurmak; AI olmadan, elle kartla çalışır hale getirmek.

**Yapılacaklar:**
1. Contract dosyaları:
   - `card.json`: `card_uuid, tip(qa|cloze|madde), on_yuz, arka_yuz, cloze_metin,
     etiketler[], kaynak_tipi(pdf|madde|manuel), kaynak_ref(doc_id+page | madde_ref | null),
     durum(taslak|onayli|askida), uretim(manuel|ai), updated_at_ms, updated_by_device, deleted_at_ms`
   - `review_state.json`: `card_uuid, due_at_ms, interval_gun, ease, tekrar_sayisi,
     lapse_sayisi, updated_at_ms, updated_by_device`
   - `review_log.json` (append-only): `log_uuid, card_uuid, cevap(1-4), cevap_suresi_ms,
     reviewed_at_ms, device` — **asla güncellenmez/silinmez**, çakışma sorunu yoktur.
2. Tablolar + numaralı migration + üç SyncSpec kaydı
   (`review_log` için tombstone yok, LWW yok — yalnız append/pull).
3. Flutter: kart listesi ekranı (etiket filtreli), manuel kart ekleme/düzenleme formu,
   üç kart tipinin önizlemesi. Cloze editörü: metinde seçim → "boşluk yap".

**Başarı kriteri:** İki cihazda kart oluştur/düzenle/sil senkron çalışır;
contract testleri (Faz 20 düzeninde) üç şemayı doğrular.

---

### [İPTAL] Faz 26 — SM-2 Zamanlayıcı + Tekrar Döngüsü + İstatistik

**Amaç:** Günlük tekrar akışının kendisi.

**Yapılacaklar:**
1. `app/lib/` altında **saf Dart** SM-2 modülü (`sm2.dart`): girdi (mevcut state, cevap 1–4)
   → çıktı (yeni interval/ease/due). UI'sız, birim testli (bilinen SM-2 tablolarıyla golden test).
   Cevap ölçeği: 1=Tekrar, 2=Zor, 3=İyi, 4=Kolay.
2. Günlük kuyruk: vadesi gelenler + günlük yeni kart limiti (ayarlar ekranından, varsayılan 15).
   Yalnız `durum=onayli` kartlar kuyruğa girer.
3. Tekrar ekranı: ön yüz → dokun → arka yüz → 4 cevap düğmesi. Cloze kartta boşluk maskeli
   gösterilir. Kart arkasında **"kaynağa git"**: `pdf` ise mevcut okuyucuda o sayfa,
   `madde` ise mevzuat okuyucuda o madde (Faz 22 yoksa düğme gizli).
4. İstatistik: günlük tekrar sayısı grafiği, olgunluk dağılımı, ders programı ekranına
   "bugün N kart" rozeti. Pomodoro entegrasyonu YOK (kapsam dışı; sadece rozet).

**Başarı kriteri:** 20 kartlık örnek destede 3 günlük simülasyon (test) doğru due tarihleri
üretir; cihazlar arası review_state tutarlı kalır.

---

### [İPTAL] Faz 27 — AI Kart Üretimi + Onay Kuyruğu (PC tarafı + tablet onayı)

**Amaç:** Kart üretim maliyetini sıfıra indirmek; kaliteyi onay kapısıyla korumak.

**Yapılacaklar:**
1. PC script'i `server/kart_uret.py` (veya `scripts/`):
   - Girdi: bir PDF bölümü (`pdf-kutuphane` yolundan sayfa aralığı) VEYA madde aralığı
     (Faz 21 DB'sinden, ör. `6098 m.1-100`).
   - Claude'a şemalı üretim yaptırır (JSON çıktı: tip, ön/arka yüz, cloze maskesi,
     etiket önerisi, kaynak_ref). Model çağrısı için mevcut makinedeki Claude Code CLI
     `-p` modu veya Anthropic API kullanılabilir — hangisi seçilirse `docs/`e not düşülür.
   - Üretim şablonları (madde kartları için): "madde no → hüküm özü", "hüküm → hangi madde",
     "fıkradaki süre/sayı cloze" (ör. "istinaf süresi ___ haftadır").
   - Çıktı kartlar sunucuya `durum=taslak` olarak yazılır; **doğrudan onaylı üretmek YASAK.**
   - Aynı kaynak+ön yüz kombinasyonu için tekrar üretimde dedup (hash) uygulanır.
2. Flutter onay ekranı: taslak kuyruğu → kartı gör → düzelt → onayla / at / askıya al.
   Toplu onay düğmesi YOK (bilinçli sürtünme; onay = ilk çalışma turu).
3. (Opsiyonel, ayrı iş) AgentBridge cowork'ten tetikleme: bridge'e
   `POST /belgelik/kart-uret` benzeri bir proxy eklemek bu repo'nun DIŞINDADIR;
   yapılacaksa agtest tarafında ayrı görev olarak planlanır.

**Başarı kriteri:** Bir PDF bölümünden üretilen ~30 kart taslak kuyruğuna düşer,
tablette onaylanan kartlar ertesi gün kuyrukta görünür; onaysız kart kuyruğa asla girmez.

---

### [İPTAL] Faz 28 — Madde Kartları Entegrasyonu + Bayat Kart Bayrağı

**Önkoşul:** Faz 21, 22 (madde DB'si ve okuyucu) + Faz 24'ün change tablosu.

**Yapılacaklar:**
1. Mevzuat okuyucusundan kart üretimi: madde görünümünde "bu maddeden kart oluştur" →
   manuel form kaynak_ref dolu açılır; veya seçili fıkradan tek dokunuşla cloze taslağı.
2. `legislation_change` kayıtları ile `kaynak_tipi=madde` kartlar eşlenir:
   değişen maddeye bağlı kartlara **"kaynak maddesi değişti"** rozeti; rozet karta
   dokununca eski/yeni madde diff'ini gösterir; kullanıcı kartı güncelleyip rozeti temizler
   veya kartı askıya alır.
3. Etiket köprüsü: madde kartlarının etiketi otomatik `kanun_kisa_ad` içerir
   (ör. `TBK`, `HMK`) — istatistik ekranında ders bazlı kırılım bedavaya gelir.

**Başarı kriteri:** Faz 24 test senaryosundaki sahte değişiklik, ilgili kartta rozet
oluşturur; kart güncellenince rozet kalkar ve review geçmişi korunur.

---

## 5. Bağımlılık Grafiği

```
Faz 21 ──► Faz 22 ──► Faz 23
              │  └───► Faz 24 ──┐
              │                 ├──► Faz 28
Faz 25 ──► Faz 26 ──► Faz 27 ───┘
```
- 25–27, 21–24'ten bağımsız yürütülebilir (kartlar PDF kaynaklı çalışır).
- 28 her iki hattın da bitmesini bekler.

## 6. Çalışma Yöntemi (uygulayan ajan için bağlayıcı kurallar)

1. Her faz **çalışır ve test edilmiş** bitirilir; faz atlanmaz, birleştirilmez.
2. Faza başlamadan: bu dosya + kök `ROADMAP.md` + `docs/FAZ-20-SAGLAMLASTIRMA-VE-REFAKTOR.md` okunur;
   sync'e dokunan işlerde `server/routers/sync.py`'deki mevcut SyncSpec'ler şablon alınır.
3. Teknoloji kararları kök ROADMAP'tekiyle aynıdır ve değiştirilmez:
   Flutter/Dart istemci, FastAPI+SQLite sunucu, Tailscale + `X-Auth-Token`, LWW sync.
4. Her yeni tablo numaralı migration ile gelir; mevcut tablolara kolon eklenmez
   (gerekiyorsa yeni tablo + join).
5. Belirsizlikte varsayım yapılmaz; soru bu dosyaya "AÇIK SORU" bloğu olarak işlenir ve sorulur.
6. Her faz sonunda `CHANGELOG` girdisi + bu dosyada fazın başına `[x]` işareti.
7. Emsal-mcp'ye HTTP ile değil, kendi CLI/MCP arayüzüyle erişilir; mevzuat kaynağına
   doğrudan scraper yazılmaz (rate-limit ve format sorumluluğu Emsal-mcp'dedir).
8. Testler: sunucu `pytest` (`run-tests.ps1` düzenine eklenir), Flutter `flutter test`;
   parser golden dosyaları `server/test/fixtures/mevzuat/` altında tutulur.

## 7. Bilinen Riskler

| Risk | Etki | Önlem |
|---|---|---|
| Mevzuat metin formatı düzensiz (Faz 21 parser) | Yanlış madde bölme → her şey kirlenir | Golden/snapshot testler, sessiz atlama yasağı, kanun kanun ilerleme |
| AI kart kalitesi | Yanlış ezber | Zorunlu onay kuyruğu, toplu onay yok |
| Atıf regex yanlış pozitifleri | Yanlış maddeye zıplama | Yalnız görüntülemede link; muhafazakâr kalıplar; testte örnek korpus |
| RG izleyicide kaçan değişiklik | Bayat metin | Haftalık tarama + manuel "yeniden ingest" düğmesi; snapshot_version görünür |
| review_log büyümesi | Sync yavaşlar | Append-only + imleçli pull (`received_at_ms`), Faz 20 deseni |
