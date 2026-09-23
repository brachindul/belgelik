# FAZ 14 — Gece Okuma Filtresi

> **Ajana not:** Önce `ROADMAP-V2.md` FAZ 14'ü oku. Tamamen istemci tarafı (reader + config). Sunucu YOK. DOĞRULAMA başarısızsa dur.

## Amaç
PDF'e okuma filtresi: **Kapalı / Karart (dim) / Sepya / Negatif (invert)** + karart yoğunluğu. Kalıcı (AppConfig).

---

## ADIM 1 — `app/lib/config.dart`
Anahtarlar:
```dart
  static const _kNightMode = 'night_mode';
  static const _kDimLevel = 'dim_level';
```
Alanlar:
```dart
  static String nightMode = 'off'; // off | dim | sepia | invert
  static double dimLevel = 0.35;   // 0.1 - 0.7
```
`load()` sonuna:
```dart
    nightMode = prefs.getString(_kNightMode) ?? 'off';
    dimLevel = prefs.getDouble(_kDimLevel) ?? 0.35;
```
Metotlar:
```dart
  static Future<void> setNightMode(String m) async {
    nightMode = m;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kNightMode, m);
  }

  static Future<void> setDimLevel(double v) async {
    dimLevel = v.clamp(0.1, 0.7);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kDimLevel, dimLevel);
  }
```

---

## ADIM 2 — `reader_screen.dart` state + filtre sarmalama
State:
```dart
  String _nightMode = AppConfig.nightMode;
  double _dimLevel = AppConfig.dimLevel;
```
Filtre matrisleri (dosya düzeyinde sabit veya metot):
```dart
  static const _invertMatrix = <double>[
    -1, 0, 0, 0, 255,
    0, -1, 0, 0, 255,
    0, 0, -1, 0, 255,
    0, 0, 0, 1, 0,
  ];
  static const _sepiaMatrix = <double>[
    0.393, 0.769, 0.189, 0, 0,
    0.349, 0.686, 0.168, 0, 0,
    0.272, 0.534, 0.131, 0, 0,
    0, 0, 0, 1, 0,
  ];
```
Build içinde, `PdfViewer.file(...)` döndüren ifadeyi bir değişkene al (`Widget viewer = PdfViewer.file(...);`) ve filtreye göre sarmala. `body`'de döndürülen `viewer` yerine:
```dart
          Widget content = viewer;
          if (_nightMode == 'invert') {
            content = ColorFiltered(
              colorFilter: const ColorFilter.matrix(_invertMatrix),
              child: content,
            );
          } else if (_nightMode == 'sepia') {
            content = ColorFiltered(
              colorFilter: const ColorFilter.matrix(_sepiaMatrix),
              child: content,
            );
          } else if (_nightMode == 'dim') {
            content = Stack(
              children: [
                Positioned.fill(child: content),
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(color: Colors.black.withValues(alpha: _dimLevel)),
                  ),
                ),
              ],
            );
          }
          return content;
```
> `withValues(alpha: ...)` yeni Flutter API'sidir; derlenmezse `Colors.black.withOpacity(_dimLevel)` kullan.
> NOT: `ColorFiltered` tüm görüntüleyiciyi (işaretleme katmanı dahil) etkiler. Negatif modda kalem/fosforlu renkleri de ters döner — bu beklenen davranıştır; rahatsız ederse ileride işaretleme katmanı filtre dışına alınabilir.

---

## ADIM 3 — Kontrol (⋮ menüsü)
`_readerMenu` itemBuilder'ına EKLE:
```dart
        const PopupMenuDivider(),
        CheckedPopupMenuItem(value: 'night_off', checked: _nightMode == 'off', child: const Text('Filtre: Kapalı')),
        CheckedPopupMenuItem(value: 'night_dim', checked: _nightMode == 'dim', child: const Text('Filtre: Karart')),
        CheckedPopupMenuItem(value: 'night_sepia', checked: _nightMode == 'sepia', child: const Text('Filtre: Sepya')),
        CheckedPopupMenuItem(value: 'night_invert', checked: _nightMode == 'invert', child: const Text('Filtre: Negatif')),
        const PopupMenuItem(value: 'dim_level', child: Text('Karart yoğunluğu…')),
```
onSelected switch'e EKLE:
```dart
          case 'night_off':
            setState(() => _nightMode = 'off');
            AppConfig.setNightMode('off');
          case 'night_dim':
            setState(() => _nightMode = 'dim');
            AppConfig.setNightMode('dim');
          case 'night_sepia':
            setState(() => _nightMode = 'sepia');
            AppConfig.setNightMode('sepia');
          case 'night_invert':
            setState(() => _nightMode = 'invert');
            AppConfig.setNightMode('invert');
          case 'dim_level':
            _showDimDialog();
```
Yoğunluk dialogu:
```dart
  Future<void> _showDimDialog() async {
    double v = _dimLevel;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Karart yoğunluğu'),
        content: StatefulBuilder(
          builder: (ctx, setSt) => Slider(
            value: v,
            min: 0.1,
            max: 0.7,
            onChanged: (x) => setSt(() => v = x),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Kapat')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _dimLevel = v);
              AppConfig.setDimLevel(v);
              if (_nightMode != 'dim') {
                setState(() => _nightMode = 'dim');
                AppConfig.setNightMode('dim');
              }
            },
            child: const Text('Uygula'),
          ),
        ],
      ),
    );
  }
```

## TEST
1. ⋮ > Filtre: Negatif → sayfa siyah-beyaz tersine döner, metin okunur.
2. Sepya → sıcak tonlama.
3. Karart → koyulaşır; "Karart yoğunluğu" ile ayarlanır.
4. Kapalı → normale döner.
5. Seçim kalıcı (uygulama yeniden açılınca duruyor).

## DOĞRULAMA
- [ ] Dört mod da çalışır ve kalıcı
- [ ] Karart yoğunluğu ayarlanır
- [ ] Çizim/sayfa-sync/gezinme regresyonsuz

```powershell
cd <PROJE> && git add -A && git commit -m "Faz 14: gece okuma filtresi (karart/sepya/negatif)"
```
