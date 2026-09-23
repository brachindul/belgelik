# belgelik

Belgelik Flutter istemcisi. Genel bakış için kök dizindeki README'ye bakın.

## Platformlar

- **Android** — telefon/tablet (alt NavigationBar)
- **Windows** — masaüstü (sol NavigationRail + gömülü reader, klavye kısayolları)

## Geliştirme

```bash
cd app
flutter pub get
flutter run             # varsayılan cihaz
flutter run -d windows  # Windows masaüstü
```

## Windows Build

Gereksinimler: **Visual Studio** (Community yeterli) + "Desktop development with C++" iş yükü.

```bash
cd app
flutter build windows --release
# Çıktı: build/windows/x64/runner/Release/belgelik.exe
```

Pencere yönetimi (`window_manager`): boyut/konum otomatik hatırlanır, min 900×640.

## Test

```bash
cd app
flutter test
flutter analyze
```

## Masaüstü kısayolları

- **Okuyucu:** `←` / `→` sayfa, `Ctrl+F` ara, `Esc` kapat
- **Pomodoro:** `Space` başlat/duraklat
- **Kütüphane:** PDF'e sağ tık → taşı/kopyala/sil/favori
