# Windows Masaüstü Okuyucu — Tasarım Belgesi

**Tarih:** 2026-06-24
**Durum:** Onaylandı, uygulama bekliyor
**Kapsam:** Mevcut Flutter uygulamasının Windows masaüstünde çalışır hale getirilmesi; PC için optimize edilmiş tam deneyim

---

## 1. Amaç ve Kararlar

Belgelik çalışma uygulaması şu an Android'de (ve Windows iskeleti mevcut ama UI mobil odaklı).
Bu tasarım, **aynı kod tabanını** Windows masaüstünde çalıştırıp fare/klavye ve geniş ekran için optimize edilmiş bir deneyim sağlar. Telefon davranışı korunur.

### Onaylanmış kararlar

| Karar | Seçim |
|-------|-------|
| Deneyim kapsamı | PC için optimize edilmiş **tam app** (Kütüphane + Program + Pomodoro + Okuyucu) |
| Pencere düzeni | **Yan panel + okuyucu** (tek pencere, sol kütüphane/okuyucu paneli + sağda büyük okuyucu) |
| Sekme kapsamı | **Üçü de kalsın** (Kütüphane / Program / Pomodoro) |
| Sayfa görünümü | **Auto** (mevcut `viewMode: 'auto'`; kullanıcı araç çubuğundan değiştirir) |
| Pencere yönetimi | **Standart + hatırla** (boyutlandırılabilir, tam ekran; boyut/konum/maximize hatırlanır) |
| UI stratejisi | **A: Platform'a göre shell değiştir** (tek kod tabanı, responsive ekranlar) |
| Sol NavigationRail | **Gizlenebilir** (durumu hatırlanır) |

---

## 2. Mimari

### Tek kod tabanı, platform'a göre shell

```
main.dart (değişiklik yok — HomeShell'e gider)
   │
   ▼
HomeShell  ── platform'a göre shell seçer:
   ├── Platform.isWindows/isMacOS/isLinux → DesktopShell (sol rail)
   └── mobil (Android/iOS)               → MobileShell (alt bar) — mevcut davranış
```

**Platform-bağımsız katmanlar (DOKUNULMAZ):**
`AppConfig`, `Api`, `SyncService`, `LocalStore`, `PomodoroService`, `Notifications`, `models.dart`, `study_program.dart`, `update_service.dart` — hepsi olduğu gibi kalır.

**Tek Platform kontrolü bugün:** `update_service.dart` (`if (!Platform.isAndroid) return null`) — Windows'ta sessizce atlanır, sorun yok.

---

## 3. Dosya Yapısı

```
app/lib/
├── main.dart                    (değişiklik: windowManager + sqflite_ffi init)
├── platform_adaptive.dart       (YENİ — isDesktop, breakpoint sabitleri)
├── screens/
│   ├── home_shell.dart          (yeniden düzenlenir: platform'a göre shell seçer)
│   ├── mobile_shell.dart        (YENİ — mevcut alt-bar mantığı taşınır)
│   ├── desktop_shell.dart       (YENİ — sol rail + gizle + durum çubuğu)
│   ├── desktop_window.dart      (YENİ — window_manager: boyut/konum hatırla)
│   └── (mevcut ekranlar: library/reader/schedule/pomodoro/settings)
│        ↑ her birine LayoutBuilder + breakpoint dallanması eklenir
```

### home_shell.dart sadeleşir

```dart
class HomeShell extends StatelessWidget {
  Widget build(context) {
    if (PlatformAdaptive.isDesktop) return const DesktopShell();
    return const MobileShell();
  }
}
```

Mevcut `IndexedStack` + `NavigationBar` mantığı aynen `mobile_shell.dart`'a taşınır.
`HomeShell.tabRequest` notifier (derin ekrandan sekme değiştirme) her iki shell'de de çalışır.

---

## 4. DesktopShell & Pencere Yönetimi

### Shell yerleşimi

```
┌──────────────────────────────────────────────┐
│  (başlık çubuğu — Windows native)            │
├────┬─────────────────────────────────────────┤
│ L  │                                         │
│ i  │      İçerik alanı (seçili sekme)        │
│ b  │      - Kütüphane: dosya listesi         │
│ r  │      - Okuyucu açıksa: yan panel + PDF  │
│ a  │      - Program: haftalık plan           │
│ r  │      - Pomodoro: sayaç                  │
│ y  │                                         │
│    │                                         │
│ Pr │                                         │
│ Po │                                         │
│ ⚙  │                                         │
├────┴─────────────────────────────────────────┤
│ ( Durum çubuğu: sync durumu, sunucu, sayaç )  │
└──────────────────────────────────────────────┘
```

### NavigationRail

- 3 sekme: Kütüphane (`library_books`), Program (`calendar_today`), Pomodoro (`timer`)
- Altta ayarlar (gear) + sync durumu göstergesi
- Üstte **gizle/daralt** düğmesi (chevron). Gizlenince okuyucu tüm genişliği kaplar.
- Gizleme durumu `shared_preferences`'a yazılır, açılışta geri yüklenir.

### Pencere yönetimi (Standart + hatırla)

- Windows native pencere: boyutlandırılabilir, tam ekran, simge durumuna küçültülebilir.
- Açılış: **1280×800**, ekranı ortalanmış. Kaydedilmiş boyut/konum varsa onu kullanır.
- **Minimum boyut 900×640** — UI'ın bozulmaması için.
- Kapatma yakalanır → mevcut boyut, konum, maximize durumu `shared_preferences`'a kaydedilir.
- `window_manager` paketi ile uygulanır.

### Okuma modu (yan panel + okuyucu)

Kütüphane sekmesindeyken bir PDF açıldığında, içerik alanı ikiye bölünür:

```
┌────┬───────────┬─────────────────────┐
│ R  │ 📁 Anayasa│                     │
│ a  │ 📕 1982  ●│     PDF OKUYUCU     │
│ i  │ 📕 madde  │       (büyük)       │
│ l  │ 📁 İdare  │                     │
│    │ 📕 ...    │   ◀ ❒  7/240  ✏ ✕  │
└────┴───────────┴─────────────────────┘
  rail   kütüphane     okuyucu
       listesi (dar)
```

- Açık PDF'in ikinci bir panelde (dar, kaydırılabilir) listesi kalır; başka PDF'e tek tıkla geçilir.
- Okuyucu widget'ı (`ReaderScreen`) paylaşılır — sadece taşınır, yeniden yazılmaz.

---

## 5. Responsive Ekranlar & Paylaşım

**Yaklaşım:** Ekranlar tek widget, yerleşim `LayoutBuilder`/breakpoint'e göre değişir.
**Breakpoint:** genişlik ≥ 900px → masaüstü yerleşimi, < 900px → mobil yerleşimi.

### Ekran bazında adaptasyonlar

| Ekran | Mobil (mevcut) | Masaüstü değişikliği |
|-------|----------------|---------------------|
| Kütüphane | Tek sütun liste, klasör/PDF | Dosya listesi daha sıkı; sağ tık bağlam menüsü (taşı/kopyala/sil/favori/indir) |
| Okuyucu | Tam ekran, mobil araç çubuğu | Kendi panelinde büyük gösterim; klavye kısayolları; araç çubuğu üstte yatay |
| Program | Kart listesi | Hafta grid'i / tablo daha geniş; aynı veri |
| Pomodoro | Büyük sayaç, mobil butonlar | Sayaç ortalanmış, klavye kısayolu destekli (Space başlat/duraklat) |
| Ayarlar | Liste push navigasyon | İçerikte açılır (ayrı pencere YAGNI) |

### Klavye kısayolları (masaüstüne özgü)

- `←` / `→` — önceki / sonraki sayfa (okuyucu)
- `Ctrl+F` — içerik arama (mevcut `content_search_screen`)
- `Esc` — okuyucuyu kapat
- `Space` — başlat/duraklat (Pomodoro)

### Sağ tık menüsü

Flutter'da `GestureDetector.onSecondaryTap`. Kütüphanede PDF'e sağ tık → taşı/kopyala/sil/favori/indir.
Mobilde görünmez.

### Dosya açma (Windows'a özgü)

Windows'ta klasik dosya açma diyaloğu (`file_picker` — zaten pubspec'te) ile yerel PDF kütüphaneye eklenebilir.
Mevcut `uploadNewPdf` API'si kullanılır.

### Paylaşım prensibi

Her ekranın **iş mantığı değişmez** — aynı `Api`, `LocalStore`, `SyncService` çağrıları.
Widget ağacı `LayoutBuilder` içinde `if (width >= 900)` ile dallanır.
Mobil widget'lar korunduğu için telefon davranışı %100 aynı kalır.

---

## 6. Bağımlılıklar

### Yeni (pubspec.yaml)

- `window_manager` — Windows pencere boyut/konum/maximize kontrolü ve hatırlama
- `sqflite_common_ffi` — `sqflite` Windows'ta FFI backend gerektirir

### Mevcut (zaten Windows destekli — doğrulandı)

- `pdfrx` ✅ Windows
- `http`, `shared_preferences`, `path_provider`, `file_picker`, `package_info_plus`, `google_fonts` ✅ hepsi Windows

---

## 7. Teknik Notlar

### sqflite Windows'ta

Mobilde `sqflite` doğrudan çalışır ama Windows'ta `sqflite_common_ffi` gerekir.
`LocalStore._initDb()` içinde değil, `main.dart`'ta platform kontrolüyle `databaseFactory = databaseFactoryFfi` atanır.
`LocalStore` mantığı değişmez. Tek satırlık init.

### window_manager yaşam döngüsü (`desktop_window.dart`)

1. `main()` öncesi `windowManager.ensureInitialized()`
2. Açılışta: kayıtlı boyut/konum varsa uygula, yoksa 1280×800 ortalanmış
3. `minWindowSize(900, 640)` ayarla
4. Kapatma yakalanır (`onWindowClose`) → mevcut boyut/konum/maximize kaydet
5. `shared_preferences`'a yazılır (mevcut altyapı)

### Update Service

Mevcut `UpdateService` sadece `Platform.isAndroid`'de çalışır (APK). Windows'ta `return null` — sessizce atlanır.
Windows güncellemesi bu tasarımın dışında (kullanıcı elle build alır).

---

## 8. Test Stratejisi

- **Mobil regresyon:** Mevcut testler korunur; `flutter test` çalışmalı.
  `mobile_shell.dart`'ın mevcut `home_shell` davranışını birebir taşıdığını doğrulayacak widget testi.
- **Masaüstü birim testi:** `PlatformAdaptive.isDesktop` ve breakpoint mantığı test edilir.
- **Manuel (`flutter run -d windows`):**
  - Pencere boyutlandırma, hatırlama
  - Rail gizle/göster
  - 3 sekme + okuyucu bölünmüş panel
  - Klavye kısayolları
  - PDF açma/senkon (aynı sunucuya bağlanıp telefonda kaldığı sayfadan devam)
- **`flutter analyze`** temiz olmalı.

---

## 9. Kapsam Dışı (YAGNI)

- iOS/iPad (ROADMAP'e göre sonraya bırakılmış)
- Web
- Çoklu pencere / split-view (B yaklaşımı, seçilmedi)
- Windows otomatik güncelleme (APK güncelleme mobil-only kalır)
