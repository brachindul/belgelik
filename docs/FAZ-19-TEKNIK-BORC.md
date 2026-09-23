# FAZ 19 — Teknik Borç Temizliği

> **Ajana not:** Önce `ROADMAP-V2.md` FAZ 19'u oku. Davranışı DEĞİŞTİRMEDEN kod sağlığını iyileştir. Her adımdan sonra `flutter analyze` temiz kalmalı. DOĞRULAMA başarısızsa dur.

## Amaç
Kullanılmayan kodları temizle, DB migration yolunu sağlamlaştır, satır-sonu uyarılarını sustur, format/analyze temiz.

---

## ADIM 1 — Kullanılmayan S Pen modu ayarını kaldır
S Pen modu toggle'ı kaldırılmıştı; `AppConfig`'teki kalıntıları sil.
`app/lib/config.dart`'tan KALDIR:
- `static const _kStylusDraw = 'stylus_draw';`
- `static bool stylusDrawMode = true;` (ve üstündeki yorum satırı)
- `load()` içindeki `stylusDrawMode = prefs.getBool(_kStylusDraw) ?? true;`
- `setStylusDrawMode` metodunun tamamı

Sonra tüm projede `stylusDrawMode` / `setStylusDrawMode` referansı kalmadığını doğrula:
```powershell
cd <PROJE>\app
Select-String -Path lib\**\*.dart -Pattern "stylusDrawMode" 
```
Çıktı boş olmalı. (Boş değilse o referansları da temizle.)

## ADIM 2 — DB migration yolunu doğrula/sağlamlaştır
`local_store.dart` şu an `version: 2`, `_onCreate` tüm tabloları (local_bookmarks dahil) kuruyor, `_onUpgrade` v1→v2'de local_bookmarks ekliyor. Kontrol:
- [ ] `_onCreate`'te ve `_onUpgrade` v2 bloğunda `local_bookmarks` şeması **birebir aynı**.
- [ ] İleride yeni tablo eklenince: `version`'ı 3 yap + `_onUpgrade`'e `if (oldVersion < 3) {...}` ekle deseni yorumla belgelensin.
Migration yorumunu güncelle (yanlış "Su an v1" notunu düzelt):
```dart
  // Sema surumu: 2. Yeni tablo/kolon eklerken version'i artir ve _onUpgrade'e
  // ilgili 'if (oldVersion < N)' blogunu ekle. _onCreate her zaman EN GUNCEL
  // semayi kurmalidir (yeni kurulumlar icin).
```

## ADIM 3 — Sabitleri toparla (opsiyonel ama önerilir)
`app/lib/constants.dart` oluştur ve dağınık sabitleri taşı (yalnızca tek yerde kullanılmayanları):
- Sunucu varsayılan adresi (`baseUrl` varsayılanı), sync aralığı, kalem/fosforlu palet ve genişlikleri (reader_screen'deki `kPenPalette` vb. burada toplanabilir).
> Riski düşük tut: yalnızca **birden çok dosyada** tekrarlanan sabitleri taşı; tek dosyada kalanları yerinde bırak. Taşırsan importları güncelle, analyze temiz kalsın.

## ADIM 4 — Satır sonu (CRLF/LF) uyarıları
Depo köküne `.gitattributes` oluştur:
```
* text=auto eol=lf
*.bat text eol=crlf
*.ps1 text eol=crlf
*.vbs text eol=crlf
```
> Bu, git'in "LF will be replaced by CRLF" uyarılarını standarda bağlar. Windows betikleri CRLF kalır.

## ADIM 5 — Format + analyze + kullanılmayan import taraması
```powershell
cd <PROJE>\app
dart format lib
& "C:\src\flutter\bin\flutter.bat" analyze
```
- `dart format` değişiklik yapabilir (normal).
- `analyze` **No issues found** olmalı. Uyarı varsa (unused_import, dead_code) gider.

## ADIM 6 — Hızlı tutarlılık kontrolü
- Hata/durum mesajlarında dil tutarlılığı (Türkçe, kısa).
- `print`/debug artığı yok (`Select-String -Path lib\**\*.dart -Pattern "print\("` → boş veya kasıtlı).

## DOĞRULAMA / BİTİŞ
- [ ] `stylusDrawMode` referansı kalmadı, uygulama derleniyor/çalışıyor
- [ ] DB migration notu güncel, şemalar tutarlı
- [ ] `.gitattributes` eklendi, CRLF uyarıları azaldı
- [ ] `dart format` uygulandı, `flutter analyze` temiz
- [ ] Davranış değişmedi (okuyucu/sync/pomodoro/program/arama regresyonsuz)

```powershell
cd <PROJE> && git add -A && git commit -m "Faz 19: teknik borc temizligi (kullanilmayan ayar, migration notu, gitattributes, format)"
```

## Ajan kuralları
1. Davranışı değiştirme; yalnızca temizlik/sağlamlaştırma.
2. `stylusDrawMode` kaldırınca tüm referansların gittiğini doğrula (derleme kırılmasın).
3. Sabit taşımada aşırıya kaçma; sadece çoklu-kullanım sabitleri.
4. Her adımdan sonra `flutter analyze` temiz kalsın.
