# Belgelik

Hukuk çalışması için kişisel, kendi sunucusunda çalışan bir çalışma ortamı:
PDF ve video kütüphanesi, mevzuat okuyucu, çalışma planlayıcı ve not alma —
birden çok cihaz arasında senkronize, çevrimdışı öncelikli.

Tek kullanıcılı, kişisel kullanım için tasarlandı; mağaza yayını, üyelik
sistemi ya da bulut bağımlılığı yok. Veriler kullanıcının kendi makinesinde
duran sunucuda tutulur, cihazlar ona özel ağ (Tailscale) üzerinden bağlanır.

> Bu repo yalnızca **inceleme ve gösterim** amacıyla açıktır. Bir lisans
> verilmemiştir; tüm hakları saklıdır. Kodun kopyalanması, dağıtılması veya
> başka projelerde kullanılması izne tabidir.

## Özellikler

**Okuma ve kütüphane**
- Sunucudaki PDF kütüphanesini klasör yapısıyla gezme, içerikte tam metin arama
- PDF okuyucu: tek/çift sayfa ve dikey akış düzenleri, içindekiler, yer imleri,
  kalem/vurgulayıcı ile işaretleme (basınca duyarlı çizim), gece filtresi
- Kaldığın sayfa, işaretlemeler ve notlar cihazlar arasında taşınır
- Video kütüphanesi: yükleme, kaldığı yerden devam, arka planda oynatma ve
  bildirim üzerinden medya kontrolü

**Mevzuat**
- Kanun metinlerinin madde, fıkra ve bent düzeyinde ayrıştırılması
  (golden-fixture testli parser)
- Cihazda çevrimdışı saklama ve tam metin arama (SQLite FTS5/FTS4)
- Madde metninde kanun/madde atıflarının tıklanabilir bağlantıya dönüşmesi
- Yeniden içe aktarımda değişen maddelerin tespiti, sürüm karşılaştırma
- Madde bazında not, vurgu ve yer imi

**Çalışma düzeni**
- Ders programı; derse bağlı kaynaklar ve kanunlar tek dokunuşla açılır
- Pomodoro sayacı (arka planda ve bildirimle çalışır), çalışma istatistikleri
- Sınav geri sayımı

## Mimari

```
 Flutter istemcisi                           Sunucu (Python / FastAPI)
 Android · iOS · macOS · Windows · Linux
 ┌──────────────────────────────┐             ┌─────────────────────────────┐
 │ Okuyucu / Mevzuat / Program  │             │ REST API, profil izolasyonu │
 │ Yerel SQLite + FTS önbelleği │  HTTP/JSON  │ SQLite (profil başına)      │
 │ Senkron kuyruğu (offline)    │ ◄─────────► │ PDF / video deposu          │
 │ Token: güvenli depo          │  Tailscale  │ Günlük otomatik yedek       │
 └──────────────────────────────┘             └─────────────────────────────┘
```

- **Çevrimdışı öncelikli senkronizasyon:** Değişiklikler önce yerelde yazılır,
  kuyruktan sunucuya gönderilir. Çakışmalar kayıt düzeyinde *last-write-wins*
  ile çözülür; silmeler tombstone olarak taşınır, istemci sunucunun alış
  zamanına dayalı bir imleçle yalnızca yeni değişiklikleri çeker.
- **Profil izolasyonu:** Her profilin ayrı veritabanı ve kütüphane klasörü
  vardır; tüm uçlar kimlik doğrulamalı ve profil kapsamlıdır.
- **Platforma uyarlanan arayüz:** Mobilde alt gezinme çubuğu, masaüstünde yan
  ray + gömülü okuyucu, bölünmüş görünüm ve klavye kısayolları.
- **Güvenlik:** Erişim token'ı Android Keystore / iOS–macOS Keychain / Windows
  Credential Store'da tutulur; sunucu yalnızca özel ağdan erişilebilir.

## Teknoloji

| Katman | Kullanılan |
|---|---|
| İstemci | Flutter / Dart, `pdfrx`, `sqflite` (+ FFI), `media_kit`, `flutter_secure_storage`, `perfect_freehand` |
| Android yerel | Kotlin (medya oynatma servisi, bildirim kontrolleri) |
| Sunucu | Python, FastAPI, Uvicorn, SQLite |
| Test / CI | `flutter test`, `pytest`, GitHub Actions (analiz + test, her push'ta) |

## Depo yapısı

```
app/        Flutter istemcisi (lib/, platform klasörleri, test/)
server/     FastAPI sunucusu (routers/, mevzuat ayrıştırıcı, yedekleme, test/)
contract/   İstemci–sunucu veri sözleşmesi (JSON şemaları)
docs/       Faz faz geliştirme notları ve tasarım belgeleri
```

## Geliştirme süreci

Proje, her biri ayrı bir tasarım belgesiyle (`docs/FAZ-*.md`) tanımlanan
fazlar halinde geliştirildi: PDF okuyucu → senkronizasyon → pomodoro ve ders
programı → işaretleme → masaüstü arayüzü → senkron sağlamlığı, yedekleme,
testler/CI → mevzuat modülü. Tasarım ve ürün kararları proje sahibine aittir;
uygulama yapay zekâ destekli kodlama araçlarıyla (Claude Code) geliştirilmiştir.
