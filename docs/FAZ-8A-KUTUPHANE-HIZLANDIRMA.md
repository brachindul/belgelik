# FAZ 8A - Kutuphane Hizlandirma: Arama, Favoriler, Son Acilanlar

> **Ajana not:** Once `ROADMAP.md` ve `docs/FAZ-7-PDF-DOSYA-YONETICISI.md` dosyalarini oku. Bu faz DeepSeek/opencode tarafindan uygulanacak. Amac: PDF kutuphanesinde gunluk kullanimi hizlandirmak. Kod uygularken belirsizlikte DUR ve raporla; uydurma cozum yazma. Her bolumun dogrulamasi basarili olmadan sonraki bolume gecme. OS: Windows, PowerShell.
>
> **Kesin kararlar:** Tek kullanici. Uyelik/coklu kullanici yok. PDF okuyucu `pdfrx` kalacak. PDF icinde metin arama bu fazda YOK; Faz 8B olarak daha sonra ayri yapilacak. Program/pomodoro entegrasyonu bu fazda YOK.
>
> **Bu fazin kapsami:** Klasor/PDF adi arama, favorilere ekleme/cikarma, son acilanlar ve kaldigin yerden devam et.

---

## 0. Mevcut durumu dogrula

Calismaya baslamadan once:

```powershell
cd <PROJE>
git status --short
```

- Beklenmeyen degisiklik varsa DUR ve raporla.
- Mevcut kodu oku:
  - `server/main.py`
  - `app/lib/models.dart`
  - `app/lib/api.dart`
  - `app/lib/screens/library_screen.dart`
  - `app/lib/screens/reader_screen.dart`
  - `app/lib/screens/folder_picker_screen.dart`
- Okuyucu, isaretleme, pomodoro, program ve tema davranislarini gereksiz yere degistirme.
- Faz 7 coklu secim/klasor/PDF tasima-kopyalama-silme davranisini bozma.

---

## Ortak kurallar

### Dosya kimligi

Mevcut kimlik mantigi korunacak:

```python
def doc_id_for(relative_path: str) -> str:
    return hashlib.sha1(relative_path.encode("utf-8")).hexdigest()[:16]
```

Favoriler ve son acilanlar `doc_id` ile tutulacak. PDF tasininca `doc_id` degistigi icin Faz 7'deki tasima/klasor rename aktarimlarina bu yeni tablolar da dahil edilecek.

### UI dili ve stil

- Yeni metinlerde ASCII Turkce kullan: `Kutuphane`, `Klasor`, `Tasi`, `Favori`, `Son acilanlar`.
- Mojibake/bozuk encoding (`KlasÃ¶r`, `TaÅŸÄ±`) ekleme.
- Uzun PDF/klasor adlari tasma yapmamali; `maxLines: 1` ve `TextOverflow.ellipsis` kullan.
- Coklu secim modu korunacak. Arama/favori UI'i coklu secimi bozmayacak.

### Faz 8B disi

Bu fazda PDF dosyasinin iceriginde metin arama yapma. `pdfrx` arama API'si arastirma, indexleme, OCR, metin cikarma veya yeni PDF paketi ekleme YOK.

---

## FAZ 8A.1 - Sunucu metadata altyapisi

### Amac

Favoriler ve son acilanlar icin SQLite tablolari ve endpoint'leri eklemek.

### Dokunulacak dosya

- `server/main.py`

### Veritabani tablolari

`init_db()` icine `annotations` tablosundan sonra ekle:

```python
conn.execute(
    """
    CREATE TABLE IF NOT EXISTS pdf_favorites (
        doc_id     TEXT PRIMARY KEY,
        updated_at INTEGER NOT NULL
    )
    """
)
conn.execute(
    """
    CREATE TABLE IF NOT EXISTS pdf_recent (
        doc_id     TEXT PRIMARY KEY,
        opened_at  INTEGER NOT NULL
    )
    """
)
```

### Helper beklentisi

Sunucuda PDF item sozlugune metadata eklemek icin yardimci kullan:

```python
def _pdf_item_with_meta(path: Path, favorite_ids: set[str] | None = None) -> dict:
    item = _pdf_to_dict(path)
    item["favorite"] = item["id"] in (favorite_ids or set())
    return item
```

Bu kod birebir zorunlu degil; ama API donuslerinde PDF item'lari `favorite` alanini tasimali.

### `PdfDoc` wire shape guncellemesi

Sunucudan donen PDF item alanlari:

```json
{
  "id": "...",
  "name": "...",
  "relative_path": "Klasor/Dosya.pdf",
  "size": 12345,
  "modified": 1710000000,
  "favorite": true
}
```

Geriye uyumluluk icin istemci `favorite` yoksa `false` kabul etmeli.

### Endpoint: favori listele

```python
@app.get("/favorites", dependencies=[Depends(check_auth)])
def list_favorites():
    ...
```

Davranis:

- `pdf_favorites` tablosundaki id'leri al.
- Gercekte var olan PDF'leri `updated_at DESC` sirasi ile dondur.
- Artik dosyasi olmayan eski kayitlari sessizce atlayabilir; istersen temizleyebilirsin.
- Donus:

```json
{"items": [PDF_ITEM_WITH_FAVORITE]}
```

### Endpoint: favori ata/cikar

```python
class FavoriteIn(BaseModel):
    favorite: bool


@app.put("/favorites/{doc_id}", dependencies=[Depends(check_auth)])
def set_favorite(doc_id: str, body: FavoriteIn):
    ...
```

Davranis:

- `doc_id` bulunamazsa 404.
- `favorite=true` ise upsert yap.
- `favorite=false` ise kaydi sil.
- Donus: `{"ok": true}`.

### Endpoint: son acilanlari listele

```python
@app.get("/recent", dependencies=[Depends(check_auth)])
def list_recent(limit: int = 5):
    ...
```

Davranis:

- Varsayilan limit 5.
- Limit 1-20 araliginda olmali; disinda 400 veya clamp kabul edilir, ama davranisi net tut.
- Gercekte var olan PDF'leri `opened_at DESC` sirasi ile dondur.
- Donus:

```json
{"items": [PDF_ITEM_WITH_FAVORITE]}
```

### Endpoint: PDF acildi olarak isaretle

```python
@app.post("/recent/{doc_id}", dependencies=[Depends(check_auth)])
def mark_recent(doc_id: str):
    ...
```

Davranis:

- `doc_id` bulunamazsa 404.
- `pdf_recent` icine `opened_at = now` ile upsert yap.
- Tabloyu sonsuz buyutmemek icin en yeni 20 kayit disindakileri temizle.
- Donus: `{"ok": true}`.

### Faz 7 aktarimlarini guncelle

Asagidaki islemlerde yeni tablolar da korunacak:

- `move_pdf`: `pdf_favorites.doc_id` ve `pdf_recent.doc_id` eski id'den yeni id'ye guncellenir.
- `copy_pdf`: kopya favori olmasin; ama son acilan olarak da eklenmesin. Kopyada sadece `positions` ve `annotations` korunmaya devam etsin.
- `delete_pdf`: ilgili `pdf_favorites` ve `pdf_recent` kayitlari silinir.
- `rename_folder`: klasor altindaki PDF'ler icin `pdf_favorites` ve `pdf_recent` id'leri yeni id'lere aktarilir.
- `delete_folder`: klasor altindaki PDF'lerin `pdf_favorites` ve `pdf_recent` kayitlari silinir.

### 8A.1 dogrulama

Sunucuyu calistir:

```powershell
cd <PROJE>\server
.\.venv\Scripts\Activate.ps1
uvicorn main:app --host 0.0.0.0 --port 8000
```

Baska PowerShell penceresinde `<TOKEN>` degerini `server\data\config.json` icinden al.

```powershell
curl "http://localhost:8000/favorites" -H "X-Auth-Token: <TOKEN>"
curl "http://localhost:8000/recent" -H "X-Auth-Token: <TOKEN>"
curl -X PUT "http://localhost:8000/favorites/<DOC_ID>" -H "X-Auth-Token: <TOKEN>" -H "Content-Type: application/json" -d "{\"favorite\":true}"
curl -X POST "http://localhost:8000/recent/<DOC_ID>" -H "X-Auth-Token: <TOKEN>"
```

Beklenen:

- Favori atanan PDF `/favorites` icinde gorunur.
- Son acilan isaretlenen PDF `/recent` icinde gorunur.
- Var olmayan `<DOC_ID>` icin 404 doner.
- PDF tasima/klasor rename sonrasi favori ve recent kayitlari yeni id ile korunur.

Basarisizsa DUR ve raporla.

---

## FAZ 8A.2 - Flutter modelleri ve API

### Amac

Istemcinin favori ve son acilan endpoint'lerini kullanabilmesi.

### Dokunulacak dosyalar

- `app/lib/models.dart`
- `app/lib/api.dart`

### `PdfDoc` modeli

`PdfDoc` icine `favorite` alani ekle:

```dart
final bool favorite;
```

Constructor'a `required this.favorite` ekle. `fromJson` icinde:

```dart
favorite: (json['favorite'] as bool?) ?? false,
```

Mevcut endpoint'ler `favorite` donmese bile uygulama kirilmamali.

### API metodlari

`Api` sinifina ekle:

- `static Future<List<PdfDoc>> getFavorites()`
- `static Future<void> setFavorite(String docId, bool favorite)`
- `static Future<List<PdfDoc>> getRecent({int limit = 5})`
- `static Future<void> markRecent(String docId)`

Beklenen URL'ler:

- `GET /favorites`
- `PUT /favorites/{docId}` body: `{"favorite": true/false}`
- `GET /recent?limit=5`
- `POST /recent/{docId}`

Hata mesajlari:

- Favoriler alinamazsa: `Favoriler alinamadi`
- Favori guncellenemezse: `Favori guncellenemedi`
- Son acilanlar alinamazsa: `Son acilanlar alinamadi`
- Son acilan isaretlenemezse: `Son acilan guncellenemedi`

### 8A.2 dogrulama

```powershell
cd <PROJE>\app
C:\src\flutter\bin\flutter.bat analyze
```

Basarisizsa DUR ve raporla.

---

## FAZ 8A.3 - Kutuphane arama

### Amac

Kutuphanede acik klasor icindeki klasor ve PDF adlarini hizli filtrelemek.

### Dokunulacak dosya

- `app/lib/screens/library_screen.dart`

### UI davranisi

- Normal modda AppBar actions icine arama ikonu ekle.
- Arama ikonuna basinca AppBar title yerine `TextField` gorunsun.
- Arama metni bos degilken:
  - Acik klasordeki klasorler `folder.name` ile filtrelenir.
  - Acik klasordeki PDF'ler `doc.name` ve `doc.relativePath` ile filtrelenir.
  - Filtreleme buyuk/kucuk harf duyarsiz olur.
- Arama sadece mevcut klasor listesini filtreler; sunucuda global arama endpoint'i bu fazda YOK.
- Arama modunda:
  - Kapat/temizle ikonu arama metnini temizler ve normal basliga doner.
  - Coklu secim modu baslatilirsa arama modu kapanir.
- Refresh mevcut `_path` icin calismaya devam eder.

### Bos sonuc

Arama sonucunda hic oge yoksa:

```dart
const Center(child: Text('Sonuc yok'))
```

Normal bos klasor metni korunur:

```dart
const Center(child: Text('Bu klasor bos'))
```

### 8A.3 dogrulama

```powershell
cd <PROJE>\app
C:\src\flutter\bin\flutter.bat analyze
```

Manuel Android test:

- Kokte arama acilir.
- Klasor adina gore filtreler.
- PDF adina gore filtreler.
- Alt klasorde arama calisir.
- Arama temizlenince tam liste geri gelir.
- Uzun basarak coklu secim baslatinca arama UI'i bozulmaz.

Basarisizsa DUR ve raporla.

---

## FAZ 8A.4 - Favoriler UI

### Amac

PDF'leri favorilere ekleyip cikarmak ve favori listesini kolay ulasilir yapmak.

### Dokunulacak dosya

- `app/lib/screens/library_screen.dart`

### PDF satiri davranisi

- PDF satirinda normal modda favori durumu gorunmeli:
  - Favori ise dolu yildiz: `Icons.star`
  - Degilse bos yildiz: `Icons.star_border`
- Yildiza basinca PDF favoriye eklenir/cikarilir.
- Popup menu icinde de favori islemi bulunabilir; ama yildiz butonu yeterlidir.
- Coklu secim modunda yildiz gizlenir, checkbox gorunur.

### Favoriler gorunumu

AppBar actions icine normal modda favoriler ikonu ekle:

- Ikon: `Icons.star`
- Basinca favoriler gorunumu acilir.
- Favoriler gorunumu yeni ekran olabilir veya `LibraryScreen` icinde mod olabilir.
- Tavsiye: yeni ekran ekle: `app/lib/screens/favorites_screen.dart`

`FavoritesScreen` davranisi:

- `Api.getFavorites()` ile liste alir.
- PDF satirina dokununca:
  - Once `Api.markRecent(doc.id)` cagirir.
  - Sonra `ReaderScreen(doc: doc)` acar.
- Satirda favoriden cikar yildizi olur.
- Liste bos ise `Favori PDF yok` gosterir.
- RefreshIndicator destekler.

### 8A.4 dogrulama

```powershell
cd <PROJE>\app
C:\src\flutter\bin\flutter.bat analyze
```

Manuel Android test:

- Bir PDF yildizlanir.
- Favoriler ekraninda gorunur.
- Favoriden cikarinca listeden kalkar.
- Favori PDF acilinca okuyucu normal calisir.
- PDF tasininca favori yeni yerde korunur.
- PDF silinince favorilerden kalkar.

Basarisizsa DUR ve raporla.

---

## FAZ 8A.5 - Son acilanlar ve kaldigin yerden devam et

### Amac

Kutuphanede son acilan PDF'lere hizli erisim ve kaldigin yerden devam akisi eklemek.

### Dokunulacak dosyalar

- `app/lib/screens/library_screen.dart`
- Gerekirse yeni ekran: `app/lib/screens/recent_screen.dart`

### PDF acma davranisi

Kutuphanede, favorilerde ve son acilanlarda PDF acarken:

1. `await Api.markRecent(doc.id)` cagir.
2. Sonra `ReaderScreen(doc: doc)` ac.

Eger `markRecent` hata verirse PDF acilisi engellenmesin. Hata sessiz gecilebilir veya SnackBar gosterilebilir; ama kullanici PDF'i acabilmeli.

Tavsiye helper:

```dart
Future<void> _openPdf(PdfDoc doc) async {
  try {
    await Api.markRecent(doc.id);
  } catch (_) {
    // PDF acilisini engelleme.
  }
  if (!mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => ReaderScreen(doc: doc)),
  );
  if (mounted) _refresh();
}
```

### Kutuphane ust bolumu

`LibraryScreen` kok klasordeyken ve normal moddayken listenin ustunde `Son acilanlar` bolumu goster:

- En fazla 5 PDF.
- Yatay liste veya kompakt dikey liste kabul edilir.
- Her oge PDF adi ve klasor yolunu gosterir.
- Dokununca PDF acilir.
- Liste bos ise bu bolumu hic gosterme.

Onemli:

- Bu bolum sadece kokte (`_path == ''`) gosterilsin.
- Arama modunda ve coklu secim modunda gosterilmesin.
- Refresh ile yenilensin.

Implementasyon secimi:

- Basit tutmak icin `LibraryScreen` icinde ikinci bir Future kullanma.
- `_future` yanina `late Future<List<PdfDoc>> _recentFuture;` eklenebilir.
- `_refresh()` ikisini de yeniler.

### Son acilanlar tam ekran

AppBar actions icine normal modda recent ikonu ekle:

- Ikon: `Icons.history`
- Basinca `RecentScreen` acilir.
- `RecentScreen`, `Api.getRecent(limit: 20)` ile liste alir.
- PDF'e dokununca `markRecent` ve `ReaderScreen` acilir.
- Bos ise `Son acilan PDF yok` gosterir.

Bu ekran opsiyoneldir ama onerilir. Eger eklenirse `favorites_screen.dart` ile benzer sade yapida olsun.

### 8A.5 dogrulama

```powershell
cd <PROJE>\app
C:\src\flutter\bin\flutter.bat analyze
C:\src\flutter\bin\flutter.bat test
```

Manuel Android test:

- Bir PDF ac.
- Kutuphaneye don.
- Kok kutuphane ustunde son acilanlarda gorunmeli.
- Baska PDF ac; son acilanlar sirasi guncellenmeli.
- Son acilanlardan PDF acilabilmeli.
- PDF tasininca son acilanlar kaydi yeni id ile korunmali.
- PDF silinince son acilanlardan kalkmali.

Basarisizsa DUR ve raporla.

---

## FAZ 8A.6 - Son cila ve regresyon

### Zorunlu komutlar

```powershell
cd <PROJE>\app
C:\src\flutter\bin\flutter.bat analyze
C:\src\flutter\bin\flutter.bat test
```

Sunucu derleme kontrolu:

```powershell
cd <PROJE>
python -m py_compile server\main.py
```

### Manuel kabul testi

Android cihazda:

1. Kutuphane acilir.
2. Arama ile PDF ve klasor filtrelenir.
3. Arama temizlenir.
4. Bir PDF favoriye eklenir.
5. Favoriler ekranindan PDF acilir.
6. PDF son acilanlara duser.
7. Kok kutuphane ustunde son acilanlar gorunur.
8. PDF tasinir; favori ve son acilan kayitlari korunur.
9. PDF silinir; favori ve son acilanlardan kalkar.
10. Coklu secim, coklu tasima ve coklu silme hala calisir.

### Bitis raporu

Is bitince raporda sunlari yaz:

- Degisen dosyalar.
- Eklenen endpoint'ler.
- Eklenen ekranlar.
- `flutter analyze` sonucu.
- `flutter test` sonucu.
- `python -m py_compile server\main.py` sonucu.
- Manuel Android test sonucu.
- Varsa bilinen eksik/risk.

Basarisiz herhangi bir adim varsa commit atma; DUR ve raporla.

---

## Son kontrol listesi

- [ ] Favoriler tablosu ve endpoint'leri calisiyor.
- [ ] Son acilanlar tablosu ve endpoint'leri calisiyor.
- [ ] PDF tasima/rename/silme favori ve recent kayitlarini koruyor/temizliyor.
- [ ] `PdfDoc.favorite` geriye uyumlu.
- [ ] Kutuphane arama calisiyor.
- [ ] Favori yildizi calisiyor.
- [ ] Favoriler ekrani calisiyor.
- [ ] PDF acilinca recent kaydi olusuyor.
- [ ] Kok kutuphanede son acilanlar bolumu gorunuyor.
- [ ] Coklu secim/tasima/silme regresyonsuz.
- [ ] `flutter analyze` temiz.
- [ ] `flutter test` temiz.
- [ ] `python -m py_compile server\main.py` temiz.

Hepsi yesilse:

```powershell
cd <PROJE>
git add .
git commit -m "Faz 8A: kutuphane hizlandirma"
```

