# Belgelik — Yol Haritası

> Kişiye özel (tek kullanıcılı) çalışma uygulaması. PDF okuma + çoklu cihaz senkronizasyonu + pomodoro + ders programı.
> Bu dosya projenin **referans anayasasıdır**. Kod yazan herhangi bir kişi/ajan, çalışmaya başlamadan önce bunu okumalıdır.

---

## 1. Amaç

Hukuk mesleki sınavlarına ve mevzuat çalışmasına hazırlanırken kullanılacak, **yalnızca tek bir kullanıcıya** (proje sahibine) özel bir uygulama. Play Store / App Store yayını, çoklu kullanıcı, kayıt-üyelik sistemi **YOKTUR ve İSTENMEZ**. Sadelik > özellik bolluğu.

## 2. Ana Özellikler

1. **PDF okuyucu + depolama** — PC'de tutulan PDF kaynaklarını uygulamada açıp okuma.
2. **Çoklu cihaz senkronizasyonu** — Bir cihazda kalınan sayfa/scroll pozisyonu, diğer cihazda kaldığı yerden devam edecek şekilde senkronize edilir.
3. **Pomodoro sayacı** — Ayarlanabilir çalış/mola döngüleri, arka planda da çalışır.
4. **Ders programı** — "Bugün X dersi Y saat" tipi günlük/haftalık plan.

## 3. Mimari

```
   FLUTTER UYGULAMASI  (Android / Windows / ileride iPad)
   ├── PDF Okuyucu        (pdfrx paketi)
   ├── Pomodoro Sayacı    (foreground service + bildirim)
   ├── Ders Programı      (yerel SQLite + sunucu sync)
   ├── Yerel Cache        (PDF indir, offline oku)
   └── Sync İstemcisi     ──┐
                            │  Tailscale özel ağı (100.x.x.x)
   PC SUNUCUSU (Python/FastAPI)  ◄─┘  HTTP/JSON
   ├── PDF dosya deposu    (yerel klasör)
   ├── SQLite veritabanı   (pozisyonlar, programlar, pomodoro logları)
   └── REST API
```

### Teknoloji kararları (DEĞİŞTİRİLMEYECEK — gerekçesi netleşmeden)
- **İstemci:** Flutter (Dart). Tek kod tabanı ile Android + Windows + (ileride) iOS/iPadOS.
- **PDF render:** `pdfrx` paketi (hem masaüstü hem mobil destekler, metin seçme var, ücretsiz).
- **Sunucu:** Python + **FastAPI** + **Uvicorn**.
- **Sunucu DB:** SQLite (tek dosya, kurulum gerektirmez).
- **Ağ:** Tailscale. Sunucu PC'nin sabit `100.x.x.x` adresi üzerinden erişim.
- **Kimlik doğrulama:** Tek bir paylaşılan gizli token (HTTP header `X-Auth-Token`). Tailscale zaten ağ erişimini kısıtladığı için bu yeterlidir.

### Çakışma kuralı
Tek kullanıcı olduğu için senkronizasyon çakışması çözümü basittir: **en son yazan kazanır** (last-write-wins), her kayıtta `updated_at` zaman damgası tutulur.

## 4. Dizin Yapısı (hedef)

```
belgelik/
├── ROADMAP.md              <- bu dosya
├── docs/                   <- faz talimatları, notlar
│   └── FAZ-0-KURULUM.md
├── server/                 <- Python FastAPI sunucusu (PC'de çalışır)
│   ├── main.py
│   ├── requirements.txt
│   ├── data/               <- SQLite db + ayarlar (git'e girmez)
│   └── pdf-kutuphane/      <- PDF dosyaları burada durur (git'e girmez)
└── app/                    <- Flutter uygulaması
    └── (flutter create çıktısı)
```

## 5. Fazlar

| Faz | Başlık | İçerik | Çıktı |
|-----|--------|--------|-------|
| **0** | Ortam kurulumu | Flutter SDK, Android Studio, Python, Tailscale, boş proje iskeletleri | Açılan boş app + cevap veren boş sunucu |
| **1** | PDF okuyucu | Sunucuda PDF listeleme/indirme API; app'te kütüphane + okuyucu; yerel cache | PC'deki PDF'leri telefonda okuyabilme |
| **2** | Senkronizasyon | Pozisyon tablosu + yaz/oku API; açılışta kaldığı yere zıplama | Cihazlar arası kaldığın yerden devam |
| **3** | Pomodoro | Ayarlanabilir sayaç, foreground service, bildirim, (ops.) loglama | Arka planda çalışan pomodoro |
| **4** | Ders programı | Günlük/haftalık plan, tamamlandı işareti, sync | Günün çalışma planı ekranı |
| **5** | Cila (opsiyonel) | Karanlık tema, PDF not/işaretleme, istatistik, sınav geri sayımı | Motive edici eklentiler |
| **6** | PDF yükleme | Telefondan kütüphaneye PDF ekleme (file_picker + sunucu upload endpoint) | Cihazdan PDF eklenebiliyor |
| **7-9** | Kategorilendirme + offline-first + S Pen | Klasör/favori/son açılanlar, offline-first sync, S Pen çizim, görünüm modları | Tamamlandı |
| **20** | Sağlamlaştırma + refaktör | backup çoklu profil, sync imleci (received_at_ms), timeout'lar, cache tazeliği, tombstone temizliği, CI, router bölme, numaralı migrasyonlar, jenerik sync v2, ApiClient DI, secure token, contract testleri | `docs/FAZ-20-SAGLAMLASTIRMA-VE-REFAKTOR.md` |

> **Sonraki geliştirmeler:** bkz. `docs/ROADMAP-V2.md` (Faz 10+: sınav geri sayımı, yer imleri, gezinme, işaretleme cilası, gece filtresi, kütüphane araması, sync sağlamlığı, yedekleme, testler, teknik borç).

**MVP sınırı:** Faz 0 + 1 + 2.

## 6. Bilinen riskler / kısıtlar
- Sync ve yeni PDF indirme için **PC açık ve Tailscale'e bağlı** olmalı (indirilmiş PDF offline okunur).
- iOS/iPad **derlemesi için Mac gerekir** (Apple kuralı). Android+Windows Windows'tan yapılır; iOS sonraya bırakılır.
- Android'de pomodoro'nun ekran kapalıyken durmaması için **foreground service + pil optimizasyonu muafiyeti** gerekir.

## 7. Çalışma yöntemi
- Her faz **çalışır ve test edilmiş** halde bitirilir, sonra bir sonrakine geçilir.
- Kod yazan ajan, ilgili fazın `docs/FAZ-N-*.md` talimat dosyasını birebir takip eder; varsayım yapmaz, belirsizlikte sorar.
