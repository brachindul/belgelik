# Değişiklik Günlüğü

## 1.14.11+52 — Ders programına kanun bağlantısı + yeni kanunlar

- Ders ekranında "Kanunlar" bölümü: derse ait kanun tek dokunuşla açılıyor, indirilmemişse indirip açıyor (Anayasa→2709, Medeni→TMK, İş→4857, Milletlerarası→MÖHUK vb.).
- Mevzuat kütüphanesine 4857 İş Kanunu (135 madde) ve 5718 MÖHUK (66 madde) eklendi.
- Madde okuyucuda fıkra numaraları ve bent harfleri kalın gösteriliyor.
- Parser: "Geçici / Madde N / -" üç satıra bölünmüş başlıklar birleştiriliyor.

## 1.14.9+50 — Anasayfa üst barı toparlandı

- Kütüphane ekranı AppBar'ı sadeleştirildi: 5 dağınık tuş → 3 (Mevzuat, Ara, ⋯).
- Senkron durumu, Ayarlar, Favoriler, Son açılanlar, İçerikte ara tek taşma menüsünde mantıksal gruplara ayrıldı.
- Senkron durumu (çevrimdışı/hata/bekleyen değişiklik) taşma menüsü ikonuna rozet olarak yansıyor.
- Başlık alanı genişletildi (titleSpacing=0) ve Tooltip eklendi; "Kütüphane" truncate sorunu giderildi.

## Faz 24 — Atıf linkleme ve değişiklik takibi

- Article-level `legislation_change` diff tablosu ve değişiklik API’leri eklendi.
- Yeniden ingest sırasında değişen/kaldırılan maddeler eski-yeni metinleriyle kaydediliyor.
- Madde okuyucuda kanun/madde atıfları tıklanabilir hale getirildi.
- Değişen maddeler rozet, sürüm karşılaştırma ekranı ve offline saklama desteği kazandı.
- `mevzuat_watch.py` Emsal-mcp tabanlı haftalık yenileme komutunu sağlıyor.

## Faz 23 — Madde notları, yer imleri ve vurgu

- `madde_notes` migration/contract ve tombstone'lu LWW sync desteği eklendi.
- Madde metninde seçim yaparak vurgu veya açıklama notu oluşturma eklendi.
- Madde bazlı yer imi ve kanun notları listesi eklendi.
- Notlar cihazlar arasında mevcut v2 sync kuyruğu üzerinden senkronlanıyor.

## Faz 22 — Sunucu API + Bundle Sync + Flutter okuyucu

- Mevzuat listeleme ve sürümlü bundle endpoint'leri eklendi.
- Flutter cihazında mevzuat tabloları ve FTS5 offline arama eklendi.
- Kanun indirme/güncelleme/silme, madde listesi ve madde okuyucu ekranları eklendi.
- Kanonik madde ID'si uzun basma ile panoya kopyalanabilir hale getirildi.
- `legislation_position` için server/client sync desteği eklendi.

## Faz 21 — Mevzuat ingest ve parser

- Emsal-mcp üzerinden tam metin mevzuat ingest akışı eklendi; tam metin olmayan kaynaklar reddediliyor.
- Kanonik madde ayrıştırıcısı, fıkra ayrımı, değişiklik notu metadata'sı ve sessiz atlamayı engelleyen hata raporu eklendi.
- `legislation`, `legislation_article`, `legislation_snapshot` tabloları migration 2 ile eklendi.
- Başlangıçtaki 9 mevzuat numarası için parser golden fixture/testleri eklendi.
