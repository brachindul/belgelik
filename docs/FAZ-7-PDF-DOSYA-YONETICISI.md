# FAZ 7 - Mobil PDF Dosya Yoneticisi

> **Ajana not:** Once `ROADMAP.md` dosyasini oku. Bu faz mevcut calisan uygulamaya eklenir. Amac: Android telefondan PDF'leri klasorlere ayirmak, klasorleri yonetmek, PDF tasima/kopyalama/silme islemlerini yapmak. Kod uygularken belirsizlikte DUR ve raporla; uydurma cozum yazma. Her alt fazin dogrulamalari basarili olmadan sonraki alt faza gecme. OS: Windows, PowerShell.
>
> **Kesin kararlar:** Tek kullanici. Uyelik/Play Store/coklu kullanici yok. PDF okuyucu `pdfrx` kalacak. Isaretleme sistemi rasterize edilmeyecek. Tum dokumani bellekte rasterize eden paket eklenmeyecek. `doc_id = sha1(relative_path)[:16]` davranisi korunacak.
>
> **Bu fazin kapsami:** Klasor bazli dosya organizasyonu. Etiket sistemi, coklu secim, cop kutusu, surukle-birak, arama ve siralama bu fazda YOK.

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
- Okuyucu, isaretleme, pomodoro, program ve tema davranislarini gereksiz yere degistirme.

---

## Ortak kurallar

### Dosya kimligi

Mevcut kimlik mantigi korunacak:

```python
def doc_id_for(relative_path: str) -> str:
    return hashlib.sha1(relative_path.encode("utf-8")).hexdigest()[:16]
```

PDF tasininca `relative_path` degisecegi icin `doc_id` de degisir. Bu nedenle tasima/kopyalama endpoint'leri yeni `id` ve `relative_path` dondurmelidir.

### Not ve pozisyon aktarimi

- **Tasima:** Ayni dokuman kabul edilir. `positions.doc_id` ve `annotations.doc_id` yeni `doc_id` degerine guncellenir.
- **Kopyalama:** Yeni dokuman kopyasi olusur. Varsa pozisyon kaydi yeni `doc_id` ile kopyalanir. Tum isaretleme satirlari yeni `doc_id` ile yeni satirlar olarak kopyalanir.
- **Silme:** PDF silinince ilgili `positions` ve `annotations` kayitlari silinir.
- **Klasor silme:** Klasor icindeki tum PDF'lerin ilgili `positions` ve `annotations` kayitlari silinir.

### Ayni ad cakismasi

Upload, tasima ve kopyalama islemlerinde hedefte ayni PDF adi varsa otomatik benzersiz ad uret:

- `ornek.pdf`
- `ornek(1).pdf`
- `ornek(2).pdf`

Kullaniciya uzerine yazma secenegi verme. Uzerine yazma bu fazda YOK.

### Path guvenligi

Sunucu tarafinda tum klasor ve dosya yolu girdileri guvenli hale getirilecek.

Reddedilecek girdiler:

- Mutlak yollar: `C:\...`, `/...`
- Ust dizine cikma: `..`
- Ters slash kacisi: `\`
- PDF kok klasoru disina cikan resolve sonucu
- Bos klasor adi
- `/`, `\`, kontrol karakterleri iceren klasor adi
- PDF olmayan dosya uzantisi

Onemli: `Path(name).name` tek basina yeterli degildir. Klasor path'leri icin mutlaka `PDF_DIR` altinda kalindigi `resolve()` ile kontrol edilmelidir.

Ornek helper beklentisi:

```python
def safe_library_path(relative: str | None = None) -> Path:
    # relative bos ise PDF_DIR dondur.
    # PDF_DIR disina cikarsa HTTP 400 firlat.
    ...


def safe_folder_name(name: str) -> str:
    # Tek klasor adi kabul et. Slash/backslash/control char reddet.
    ...
```

Bu kod blogu birebir zorunlu degildir; ayni guvenlik davranisini saglayan daha temiz implementasyon kabul edilir.

---

## FAZ 7.1 - Sunucu klasor ve listeleme altyapisi

### Amac

Sunucuda `pdf-kutuphane/` altini klasor gezintisine uygun listelemek ve klasor CRUD islemlerini eklemek.

### Dokunulacak dosya

- `server/main.py`

### Eklenecek modeller

`pydantic` modellerini diger input modellerinin yanina ekle:

```python
class FolderCreateIn(BaseModel):
    path: str = ""
    name: str


class FolderRenameIn(BaseModel):
    path: str
    new_name: str
```

### Eklenecek endpoint: `GET /library`

Imza:

```python
@app.get("/library", dependencies=[Depends(check_auth)])
def list_library(path: str = ""):
    ...
```

Davranis:

- `path` bos ise kok klasoru listeler.
- `path` dolu ise ilgili alt klasoru listeler.
- Klasor yoksa 404 doner.
- Klasorler ada gore siralanir.
- PDF'ler ada gore siralanir.
- Yalnizca `.pdf` dosyalari listelenir.

Donus formati:

```json
{
  "path": "Medeni Hukuk",
  "parent": "",
  "folders": [
    {"name": "Alt Klasor", "path": "Medeni Hukuk/Alt Klasor"}
  ],
  "pdfs": [
    {
      "id": "abc123",
      "name": "Kaynak",
      "relative_path": "Medeni Hukuk/Kaynak.pdf",
      "size": 12345,
      "modified": 1710000000
    }
  ]
}
```

Not: `name` PDF icin mevcut davranistaki gibi `path.stem` olmali.

### Eklenecek endpoint: `POST /folders`

Imza:

```python
@app.post("/folders", dependencies=[Depends(check_auth)])
def create_folder(body: FolderCreateIn):
    ...
```

Davranis:

- `body.path` altinda `body.name` klasoru olusturur.
- Ayni klasor zaten varsa hata vermeden `{"ok": true}` donmek kabul edilir.
- Gecersiz path/name icin 400 doner.
- Hedef parent yoksa 404 doner.

### Eklenecek endpoint: `PUT /folders/rename`

Imza:

```python
@app.put("/folders/rename", dependencies=[Depends(check_auth)])
def rename_folder(body: FolderRenameIn):
    ...
```

Davranis:

- `body.path` klasorunu ayni parent altinda `body.new_name` olarak yeniden adlandirir.
- Kok klasor yeniden adlandirilamaz.
- Hedef ad varsa 409 doner.
- Klasor yoksa 404 doner.
- Yeniden adlandirma sonrasi, klasor altindaki PDF'lerin `doc_id` degerleri degisecegi icin ilgili `positions` ve `annotations` kayitlari yeni id'lere aktarilmalidir.
- Aktarim icin rename oncesi klasor altindaki PDF relative path listesi alin; rename sonrasi her eski relative path icin yeni relative path hesapla.

### Eklenecek endpoint: `DELETE /folders`

Imza:

```python
@app.delete("/folders", dependencies=[Depends(check_auth)])
def delete_folder(path: str):
    ...
```

Davranis:

- Kok klasor silinemez.
- Klasor yoksa 404 doner.
- Klasor ve tum icerigi silinir.
- Silmeden once klasor altindaki PDF'lerin `doc_id` listesi hesaplanir.
- Silme sonrasi ilgili `positions` ve `annotations` kayitlari silinir.

### 7.1 dogrulama

Sunucuyu calistir:

```powershell
cd <PROJE>\server
.\.venv\Scripts\Activate.ps1
uvicorn main:app --host 0.0.0.0 --port 8000
```

Baska PowerShell penceresinde `<TOKEN>` degerini `server\data\config.json` icinden al.

```powershell
curl "http://localhost:8000/library" -H "X-Auth-Token: <TOKEN>"
curl -X POST "http://localhost:8000/folders" -H "X-Auth-Token: <TOKEN>" -H "Content-Type: application/json" -d "{\"path\":\"\",\"name\":\"Medeni Hukuk\"}"
curl "http://localhost:8000/library?path=Medeni%20Hukuk" -H "X-Auth-Token: <TOKEN>"
curl -X PUT "http://localhost:8000/folders/rename" -H "X-Auth-Token: <TOKEN>" -H "Content-Type: application/json" -d "{\"path\":\"Medeni Hukuk\",\"new_name\":\"Medeni\"}"
curl -X DELETE "http://localhost:8000/folders?path=Medeni" -H "X-Auth-Token: <TOKEN>"
```

Beklenen:

- Tum gecerli islemler 200 doner.
- `GET /library` kok listeyi dondurur.
- Path traversal denemeleri 400 doner:

```powershell
curl "http://localhost:8000/library?path=.." -H "X-Auth-Token: <TOKEN>"
curl -X POST "http://localhost:8000/folders" -H "X-Auth-Token: <TOKEN>" -H "Content-Type: application/json" -d "{\"path\":\"..\",\"name\":\"X\"}"
```

Basarisizsa DUR ve raporla.

---

## FAZ 7.2 - Sunucu PDF tasima, kopyalama, silme

### Amac

PDF dosya islemlerini sunucuya eklemek ve okuma konumu/isaretleme aktarimini dogru yapmak.

### Dokunulacak dosya

- `server/main.py`

### Eklenecek modeller

```python
class PdfMoveCopyIn(BaseModel):
    target_folder: str = ""
```

### `POST /pdfs/upload` guncellemesi

Mevcut endpoint korunacak, sadece opsiyonel `folder` query parametresi eklenecek:

```python
@app.post("/pdfs/upload", dependencies=[Depends(check_auth)])
async def upload_new_pdf(name: str, request: Request, folder: str = ""):
    ...
```

Davranis:

- `folder` bos ise mevcut davranisla kok klasore yukler.
- `folder` dolu ise ilgili guvenli klasore yukler.
- Hedef klasor yoksa 404 doner.
- Ayni ad varsa `ad(1).pdf` biciminde benzersiz ad uretir.
- Donus formati mevcut alanlari korumali; en az `id`, `name`, `relative_path` donmeli.

### Eklenecek endpoint: `POST /pdfs/{doc_id}/move`

Imza:

```python
@app.post("/pdfs/{doc_id}/move", dependencies=[Depends(check_auth)])
def move_pdf(doc_id: str, body: PdfMoveCopyIn):
    ...
```

Davranis:

- `doc_id` ile PDF bulunamazsa 404.
- `target_folder` guvenli degilse 400.
- Hedef klasor yoksa 404.
- PDF hedef klasore tasinir.
- Hedefte ayni ad varsa benzersiz ad uretir.
- Yeni `relative_path` ve yeni `doc_id` hesaplanir.
- SQLite icinde `positions` ve `annotations` eski `doc_id`den yeni `doc_id`ye guncellenir.
- Donus:

```json
{
  "ok": true,
  "item": {
    "id": "newid",
    "name": "Kaynak",
    "relative_path": "Hedef/Kaynak.pdf",
    "size": 12345,
    "modified": 1710000000
  }
}
```

### Eklenecek endpoint: `POST /pdfs/{doc_id}/copy`

Imza:

```python
@app.post("/pdfs/{doc_id}/copy", dependencies=[Depends(check_auth)])
def copy_pdf(doc_id: str, body: PdfMoveCopyIn):
    ...
```

Davranis:

- Kaynak PDF bulunamazsa 404.
- Hedef klasor yoksa 404.
- PDF hedefe kopyalanir.
- Ayni ad varsa benzersiz ad uretir.
- Yeni `doc_id` hesaplanir.
- Varsa `positions` satiri yeni `doc_id` ile kopyalanir.
- Tum `annotations` satirlari yeni `doc_id` ile yeni satirlar olarak kopyalanir.
- Donus formati `move` ile ayni.

### Eklenecek endpoint: `DELETE /pdfs/{doc_id}`

Imza:

```python
@app.delete("/pdfs/{doc_id}", dependencies=[Depends(check_auth)])
def delete_pdf(doc_id: str):
    ...
```

Davranis:

- PDF bulunamazsa 404.
- PDF dosyasini siler.
- Ilgili `positions` ve `annotations` kayitlarini siler.
- Donus: `{"ok": true}`.

### 7.2 dogrulama

Bir test PDF'i hazirla ve yukle:

```powershell
curl -X POST "http://localhost:8000/folders" -H "X-Auth-Token: <TOKEN>" -H "Content-Type: application/json" -d "{\"path\":\"\",\"name\":\"Ceza\"}"
curl -X POST "http://localhost:8000/folders" -H "X-Auth-Token: <TOKEN>" -H "Content-Type: application/json" -d "{\"path\":\"\",\"name\":\"Medeni\"}"
curl -X POST "http://localhost:8000/pdfs/upload?name=deneme.pdf&folder=Ceza" -H "X-Auth-Token: <TOKEN>" -H "Content-Type: application/pdf" --data-binary "@C:\path\to\herhangi.pdf"
curl "http://localhost:8000/library?path=Ceza" -H "X-Auth-Token: <TOKEN>"
```

Listeden donen id'yi `<DOC_ID>` olarak kullan.

Tasima:

```powershell
curl -X POST "http://localhost:8000/pdfs/<DOC_ID>/move" -H "X-Auth-Token: <TOKEN>" -H "Content-Type: application/json" -d "{\"target_folder\":\"Medeni\"}"
curl "http://localhost:8000/library?path=Medeni" -H "X-Auth-Token: <TOKEN>"
```

Kopyalama:

```powershell
curl -X POST "http://localhost:8000/pdfs/<NEW_DOC_ID>/copy" -H "X-Auth-Token: <TOKEN>" -H "Content-Type: application/json" -d "{\"target_folder\":\"Ceza\"}"
curl "http://localhost:8000/library?path=Ceza" -H "X-Auth-Token: <TOKEN>"
```

Silme:

```powershell
curl -X DELETE "http://localhost:8000/pdfs/<COPY_DOC_ID>" -H "X-Auth-Token: <TOKEN>"
```

Ek manuel dogrulama:

- Tasima/kopyalama oncesi test PDF icin bir pozisyon ve en az bir annotation kaydi olusturulabiliyorsa olustur.
- Tasima sonrasi `/position/<NEW_DOC_ID>` ve `/annotations/<NEW_DOC_ID>` kayitlari korunmus olmali.
- Kopyalama sonrasi kopyada da pozisyon ve annotation kayitlari bulunmali.

Basarisizsa DUR ve raporla.

---

## FAZ 7.3 - Flutter klasor gezintisi ve klasore yukleme

### Amac

Kutuphaneyi klasor gezintili hale getirmek. Bu alt fazda PDF tasima/kopyalama/silme UI'i henuz eklenmez.

### Dokunulacak dosyalar

- `app/lib/models.dart`
- `app/lib/api.dart`
- `app/lib/screens/library_screen.dart`

Okuyucu dosyasina sadece derleme zorunlu kilarsa dokun; aksi halde `reader_screen.dart` degismemeli.

### Modellere eklenecek yapilar

`models.dart` icine ekle:

```dart
class LibraryFolder {
  final String name;
  final String path;

  LibraryFolder({required this.name, required this.path});

  factory LibraryFolder.fromJson(Map<String, dynamic> json) => LibraryFolder(
        name: json['name'] as String,
        path: json['path'] as String,
      );
}

class LibraryListing {
  final String path;
  final String? parent;
  final List<LibraryFolder> folders;
  final List<PdfDoc> pdfs;

  LibraryListing({
    required this.path,
    required this.parent,
    required this.folders,
    required this.pdfs,
  });

  factory LibraryListing.fromJson(Map<String, dynamic> json) => LibraryListing(
        path: json['path'] as String,
        parent: json['parent'] as String?,
        folders: (json['folders'] as List)
            .map((e) => LibraryFolder.fromJson(e as Map<String, dynamic>))
            .toList(),
        pdfs: (json['pdfs'] as List)
            .map((e) => PdfDoc.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
```

Bu kod blogu birebir kullanilabilir. Alan adlari sunucu donusuyle uyumlu olmalidir.

### API metodlari

`Api` sinifina ekle:

- `static Future<LibraryListing> getLibrary(String path)`
- `static Future<void> createFolder(String path, String name)`
- `static Future<void> renameFolder(String path, String newName)`
- `static Future<void> deleteFolder(String path)`
- `static Future<void> uploadNewPdf(String fileName, List<int> bytes, {String folder = ''})`

Mevcut `uploadNewPdf(String fileName, List<int> bytes)` cagrilari bozulmasin. Bunun icin parametre opsiyonel olmali:

```dart
static Future<void> uploadNewPdf(
  String fileName,
  List<int> bytes, {
  String folder = '',
}) async {
  ...
}
```

Query parametrelerini elle string birlestirme yerine `Uri` ile guvenli kurmak tercih edilir. Elle kurarsan `Uri.encodeQueryComponent` kullan.

### `LibraryScreen` davranisi

Mevcut ekran su hale getir:

- State:
  - `String _path = '';`
  - `late Future<LibraryListing> _future;`
- `_refresh()` mevcut `_path` icin `Api.getLibrary(_path)` cagirir.
- Klasor satirlari PDF satirlarindan once gosterilir.
- Klasore tiklaninca `_path = folder.path` yapilir ve liste yenilenir.
- AppBar:
  - Baslik kokte `Kutuphane`, alt klasorde klasor adi veya path.
  - Kokte degilken geri/yukari butonu gorunur; parent'a doner.
  - Ayarlar butonu korunur.
- FAB veya app bar menusu:
  - PDF yukle.
  - Klasor olustur.
- PDF yukleme mevcut acik klasore yapilir: `Api.uploadNewPdf(f.name, bytes, folder: _path)`.
- Bos klasor icin anlasilir bos durum metni goster.

Klasor islemleri:

- Klasor olustur: ad isteyen dialog.
- Klasor yeniden adlandir: mevcut adi gosteren dialog.
- Klasor sil: onay dialog'u. Metin, klasor iceriginin de silinecegini acik soylesin.

Klasor satiri UI:

- Leading icon: `Icons.folder`
- Title: klasor adi
- Trailing popup menu: yeniden adlandir, sil

PDF satiri UI:

- Mevcut dokununca okuyucu acma davranisi korunur.
- Bu alt fazda PDF popup menu eklemek zorunlu degil; 7.4'te eklenecek.

### 7.3 dogrulama

```powershell
cd <PROJE>\app
C:\src\flutter\bin\flutter.bat analyze
```

Manuel Android test:

```powershell
cd <PROJE>\app
C:\src\flutter\bin\flutter.bat run
```

Beklenen:

- Kutuphanede kok klasor listelenir.
- Klasor olusturulabilir.
- Klasore girilip geri cikilabilir.
- PDF acik klasore yuklenir.
- Yuklenen PDF listede gorunur ve acilabilir.
- Klasor yeniden adlandirma ve silme calisir.

Basarisizsa DUR ve raporla.

---

## FAZ 7.4 - Flutter PDF islem menusu

### Amac

Mobil UI'da PDF tasima, kopyalama ve silme islemlerini eklemek.

### Dokunulacak dosyalar

- `app/lib/api.dart`
- `app/lib/screens/library_screen.dart`
- Gerekirse yeni bir ekran dosyasi: `app/lib/screens/folder_picker_screen.dart`

Yeni ekran eklemek kabul edilir. Eger `folder_picker_screen.dart` eklersen sadece hedef klasor secimi icin sade tut.

### API metodlari

`Api` sinifina ekle:

- `static Future<PdfDoc> movePdf(String docId, String targetFolder)`
- `static Future<PdfDoc> copyPdf(String docId, String targetFolder)`
- `static Future<void> deletePdf(String docId)`

Sunucu donusundeki `item` alanindan `PdfDoc.fromJson` ile model uret.

### Hedef klasor secimi

Taşı/Kopyala islemi icin kullanici hedef klasor secebilmeli.

Beklenen davranis:

- Kok klasor secilebilir.
- Alt klasorlere girilebilir.
- Geri/yukari navigasyon vardir.
- Kullanici bir klasoru hedef olarak onaylayabilir.
- Secim iptal edilebilir.

Implementasyon secimi:

- Tercih edilen: `FolderPickerScreen`.
- Alternatif: `showModalBottomSheet` icinde klasor gezintisi.

Hangi yolu secersen sec, karar verme ihtiyaci birakma:

- Ekran cok karmasik olmasin.
- PDF dosyalari hedef secicide gosterilmeyebilir; sadece klasorler yeterlidir.
- Hedef secici `Api.getLibrary(path)` kullanir.

### PDF satir menusu

PDF satirina trailing popup menu ekle:

- `Tasi`
- `Kopyala`
- `Sil`

Davranis:

- `Tasi`: hedef klasor sec, `Api.movePdf(doc.id, target)` cagir, mevcut listeyi yenile.
- `Kopyala`: hedef klasor sec, `Api.copyPdf(doc.id, target)` cagir, mevcut listeyi yenile.
- `Sil`: onay dialog'u goster, `Api.deletePdf(doc.id)` cagir, mevcut listeyi yenile.
- Islem basarili olunca kisa SnackBar goster.
- Islem hata verirse SnackBar'da `Hata: ...` goster.
- Tasinan/kopyalanan PDF otomatik acilmaz.

### 7.4 dogrulama

```powershell
cd <PROJE>\app
C:\src\flutter\bin\flutter.bat analyze
```

Manuel Android test:

- Bir PDF'i baska klasore tasi.
- Liste yenilenince eski klasorde kaybolmali, hedef klasorde gorunmeli.
- Tasinan PDF acilmali.
- Tasinan PDF'te daha onceki sayfa konumu ve isaretlemeler korunmali.
- Bir PDF'i kopyala.
- Kopya hedef klasorde gorunmeli.
- Kopyada da sayfa konumu ve isaretlemeler korunmali.
- Bir PDF'i sil.
- Onay dialog'u cikmali.
- Silme sonrasi PDF listeden kalkmali.

Basarisizsa DUR ve raporla.

---

## FAZ 7.5 - Cila, regresyon ve kabul testi

### Amac

Ozelligi gunluk kullanim icin guvenilir hale getirmek ve regresyonlari yakalamak.

### Dokunulacak dosyalar

Bu alt fazda yeni ozellik ekleme. Sadece hata duzeltmeleri, metin tasmasi duzeltmeleri ve dogrulama icin gereken kucuk temizlikler yap.

### UI cila kurallari

- Uzun klasor/PDF adlari mobilde tasma yapmamali.
- SnackBar metinleri Turkce ve anlasilir olmali.
- Bos klasor gorunumu sade olmali.
- Gereksiz aciklama panelleri ekleme.
- Klasor ve PDF satirlari taranabilir olmali.
- Ayarlar butonu korunmali.
- Reader ekranina gecis eskisi gibi calismali.

### Regresyon kontrolu

Asagidaki dosyalarda gereksiz degisiklik olmamali:

- `app/lib/screens/reader_screen.dart`
- `app/lib/screens/pomodoro_screen.dart`
- `app/lib/screens/schedule_screen.dart`
- `app/lib/screens/settings_screen.dart`
- `app/lib/main.dart`
- `app/lib/config.dart`

Zorunlu degisiklik yapildiysa sebebini raporla.

### Zorunlu komutlar

```powershell
cd <PROJE>\app
C:\src\flutter\bin\flutter.bat analyze
```

Sunucu manuel kontrol:

```powershell
cd <PROJE>\server
.\.venv\Scripts\Activate.ps1
uvicorn main:app --host 0.0.0.0 --port 8000
```

Ayri PowerShell penceresinde:

```powershell
curl "http://localhost:8000/health"
curl "http://localhost:8000/library" -H "X-Auth-Token: <TOKEN>"
curl "http://localhost:8000/pdfs" -H "X-Auth-Token: <TOKEN>"
```

### Uctan uca kabul testi

Android cihazda:

1. Kutuphane sekmesini ac.
2. `Ceza` klasoru olustur.
3. `Medeni` klasoru olustur.
4. `Ceza` klasorune gir.
5. Telefonda bir PDF secip yukle.
6. PDF'i ac, bir sayfaya git, bir isaretleme yap.
7. Kutuphaneye don.
8. PDF'i `Medeni` klasorune tasi.
9. `Medeni` klasorune gir, PDF'i ac.
10. Sayfa konumu ve isaretlemenin korundugunu kontrol et.
11. PDF'i `Ceza` klasorune kopyala.
12. `Ceza` klasorune gir, kopyayi ac.
13. Kopyada da sayfa konumu ve isaretlemenin korundugunu kontrol et.
14. Kopyayi sil; onay dialog'u cikmali.
15. Bos veya test klasorlerini sil.

### Bitis raporu

Tum fazlar bittiginde raporda sunlari yaz:

- Hangi dosyalar degisti.
- Hangi endpoint'ler eklendi.
- `flutter analyze` sonucu.
- Sunucu manuel test sonucu.
- Android manuel test sonucu.
- Varsa bilinen eksik veya risk.

Basarisiz herhangi bir adim varsa commit atma; DUR ve raporla.

---

## Son kontrol listesi

- [ ] 7.1 sunucu klasor/listeleme tamam ve dogrulandi.
- [ ] 7.2 sunucu PDF tasima/kopyalama/silme tamam ve dogrulandi.
- [ ] 7.3 Flutter klasor gezintisi/yukleme tamam ve dogrulandi.
- [ ] 7.4 Flutter PDF islem menusu tamam ve dogrulandi.
- [ ] 7.5 cila ve kabul testi tamam.
- [ ] Path traversal kontrolleri manuel denendi.
- [ ] Tasima pozisyon/isaretleme koruyor.
- [ ] Kopyalama pozisyon/isaretleme koruyor.
- [ ] Silme ilgili SQLite kayitlarini temizliyor.
- [ ] Okuyucu/isaretleme/pomodoro/program/tema regresyonsuz.

Hepsi yesilse:

```powershell
cd <PROJE>
git add .
git commit -m "Faz 7: mobil PDF dosya yoneticisi"
```

