# FAZ 10 — Sınav Geri Sayımı

> **Ajana not:** Önce `ROADMAP-V2.md` FAZ 10'u oku. Tamamen istemci tarafı; sunucu değişikliği YOK. Kod bloklarını birebir uygula. DOKUNMA: okuyucu/sync/pomodoro/program. DOĞRULAMA başarısızsa dur.

## Amaç
"Sınava X gün kaldı" sayacı. Kütüphane üstünde ince banner + Ayarlar'dan sınav adı/tarihi düzenlenir. Varsayılan tarih: **2026-12-19**.

---

## ADIM 1 — `app/lib/config.dart`'a sınav ayarları EKLE
Anahtarlar (diğer `_k...` sabitlerinin yanına):
```dart
  static const _kExamName = 'exam_name';
  static const _kExamDate = 'exam_date';
```
Alanlar (diğer `static String/int` alanlarının yanına):
```dart
  static String examName = 'Sınav';
  static String examDate = '2026-12-19'; // ISO yyyy-MM-dd; bos => banner gizli
```
`load()` SONUNA:
```dart
    examName = prefs.getString(_kExamName) ?? examName;
    examDate = prefs.getString(_kExamDate) ?? examDate;
```
Yeni metot EKLE:
```dart
  static Future<void> setExam(String name, String dateIso) async {
    examName = name.trim();
    examDate = dateIso.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kExamName, examName);
    await prefs.setString(_kExamDate, examDate);
  }

  /// Sinava kalan gun (negatif = gecti, null = tarih yok/gecersiz).
  static int? examDaysLeft() {
    if (examDate.isEmpty) return null;
    final d = DateTime.tryParse(examDate);
    if (d == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(d.year, d.month, d.day);
    return target.difference(today).inDays;
  }
```

---

## ADIM 2 — `app/lib/screens/settings_screen.dart`'a sınav alanları EKLE
Mevcut alanların (sunucu/token/tema) yanına sınav adı TextField'i + tarih seçici ekle. `State` içine controller ve seçili tarih ekle; `build`'de göster.

State alanları (mevcut controller'ların yanına):
```dart
  final TextEditingController _examNameCtrl =
      TextEditingController(text: AppConfig.examName);
  DateTime? _examDate = DateTime.tryParse(AppConfig.examDate);
```
`dispose()` varsa `_examNameCtrl.dispose();` ekle (yoksa dispose ekle).

`build` içine, Kaydet butonundan ÖNCE bir bölüm ekle:
```dart
            const SizedBox(height: 24),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Sınav'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _examNameCtrl,
              decoration: const InputDecoration(labelText: 'Sınav adı'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _examDate == null
                        ? 'Tarih seçilmedi'
                        : 'Tarih: ${_examDate!.toIso8601String().substring(0, 10)}',
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _examDate ?? DateTime(now.year, 12, 19),
                      firstDate: DateTime(now.year - 1),
                      lastDate: DateTime(now.year + 5),
                    );
                    if (picked != null) setState(() => _examDate = picked);
                  },
                  child: const Text('Tarih seç'),
                ),
              ],
            ),
```
Kaydet butonunun `onPressed`'ine (mevcut `AppConfig.save(...)` çağrısının yanına) EKLE:
```dart
                await AppConfig.setExam(
                  _examNameCtrl.text,
                  _examDate == null
                      ? ''
                      : _examDate!.toIso8601String().substring(0, 10),
                );
```
> Not: settings_screen mevcut Kaydet mantığını koru; yalnızca bu çağrıyı ekle. `import '../config.dart';` zaten var.

---

## ADIM 3 — `app/lib/screens/library_screen.dart`'a banner EKLE
Banner widget'ı (sınıf içine metot):
```dart
  Widget? _examBanner(BuildContext context) {
    final days = AppConfig.examDaysLeft();
    if (days == null) return null;
    final scheme = Theme.of(context).colorScheme;
    final String text;
    if (days > 0) {
      text = '${AppConfig.examName}\'na $days gün kaldı';
    } else if (days == 0) {
      text = '${AppConfig.examName} bugün!';
    } else {
      text = '${AppConfig.examName} geçti';
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.event, size: 18, color: scheme.onPrimaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
```
Banner'ı liste başına ekle. `ListView`'in `children`'ında, "Son açılanlar" bölümünden ÖNCE (yani `if (_path.isEmpty && !_searching) ...` bloğunun en başına) şunu koy:
```dart
                if (_path.isEmpty && !_searching && _examBanner(context) != null)
                  _examBanner(context)!,
```
> Banner yalnızca kök klasörde ve arama kapalıyken görünür.

---

## TEST
```powershell
cd <PROJE>\app
flutter run
```
1. Ayarlar > Sınav > tarih seç (örn. 19.12.2026), ad gir, Kaydet.
2. Kütüphane kökünde banner: "Sınava N gün kaldı".
3. Tarihi bugüne/geçmişe ayarla → "bugün!"/"geçti" görünür.
4. Adı/tarihi temizleyince (tarih seçilmezse) banner gizli.

## DOĞRULAMA
- [ ] Gün sayısı doğru (yerel tarihe göre)
- [ ] Banner sadece kökte + arama kapalıyken
- [ ] Ayar kalıcı (uygulama yeniden açılınca duruyor)
- [ ] Kütüphane/okuyucu regresyonsuz

```powershell
cd <PROJE> && git add -A && git commit -m "Faz 10: sinav geri sayimi"
```
