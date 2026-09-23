# FAZ 18 — Testler + CI

> **Ajana not:** Önce `ROADMAP-V2.md` FAZ 18'i oku. Hedef: kritik mantığı (sync merge, model JSON, layout) testle güvenceye almak. Üretim kodunu mümkünse değiştirme; gerekirse minik testability dokunuşları. DOĞRULAMA başarısızsa dur.

## Amaç
`flutter test` (Dart) + `pytest` (sunucu) yeşil; sync/merge ve modeller kapsanır.

---

## BÖLÜM A — DART TESTLERİ (saf mantık, DB gerektirmez)

### A1. `app/test/models_test.dart`
```dart
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:belgelik/models.dart';

void main() {
  test('Stroke JSON round-trip', () {
    final s = Stroke(
      page: 3,
      kind: 'pen',
      color: 0xFFE53935,
      width: 0.004,
      points: [const Offset(0.1, 0.2), const Offset(0.3, 0.4)],
    );
    final json = s.toJson();
    expect(json['page'], 3);
    expect(json['kind'], 'pen');
    expect((json['points'] as List).length, 2);
  });

  test('PdfDoc.fromJson', () {
    final d = PdfDoc.fromJson({
      'id': 'abc',
      'name': 'Test',
      'relative_path': 'x/Test.pdf',
      'size': 100,
      'modified': 123,
    });
    expect(d.id, 'abc');
    expect(d.relativePath, 'x/Test.pdf');
  });

  test('SearchHit.toPdfDoc', () {
    final h = SearchHit(
      docId: 'id1',
      page: 5,
      snippet: '...',
      name: 'Ders',
      relativePath: 'a/Ders.pdf',
      size: 10,
      modified: 1,
    );
    final d = h.toPdfDoc();
    expect(d.id, 'id1');
    expect(d.name, 'Ders');
  });
}
```
> `package:belgelik/...` import yolu pubspec `name: belgelik` ile uyumlu. Model alan adları kodla birebir olmalı (gerekirse uyarlat).

### A2. `app/test/layout_test.dart`
```dart
import 'package:flutter_test/flutter_test.dart';
// buildPageLayout reader_screen.dart icinde top-level. Erisim icin import:
import 'package:belgelik/screens/reader_screen.dart';
// NOT: buildPageLayout ve ViewMode su an reader_screen.dart'ta. Eger 'private'
// degil top-level public iseler import yeterli. Degillerse FAZ 19'da
// lib/pdf_layout.dart'a tasinabilir.

void main() {
  // buildPageLayout PdfPage listesi ister; PdfPage'i mock'lamak zor oldugu icin
  // bu test ancak buildPageLayout saf bir 'sayfa boyutlari listesi' alacak sekilde
  // refaktor edilirse anlamli. Aksi halde ATLA ve raporla.
  test('placeholder', () {
    expect(1 + 1, 2);
  });
}
```
> **Not:** `buildPageLayout` `List<PdfPage>` alıyor; PdfPage'i test ortamında üretmek zor. Anlamlı layout testi için (opsiyonel) `buildPageLayout`'u `List<Size>` alacak saf bir çekirdeğe ayır (FAZ 19 ile). Şimdilik bu dosyayı atlayabilirsin; zorlama.

### A3. Çalıştır
```powershell
cd <PROJE>\app
flutter test
```
DOĞRULAMA: model testleri yeşil.

### A4. (Opsiyonel) LocalStore merge testleri — sqflite_common_ffi
DB testleri için cihaz gerekmeyen ffi:
```powershell
flutter pub add --dev sqflite_common_ffi
```
Test başında:
```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// setUpAll:
sqfliteFfiInit();
databaseFactory = databaseFactoryFfi;
```
**Ancak** `LocalStore` veritabanı yolunu `getDatabasesPath()` ile sabit açıyor; test izolasyonu için `LocalStore`'a test amaçlı bir `overrideDbPath`/factory enjeksiyonu gerekir. Bu küçük testability dokunuşunu yapabilirsen `applyRemoteAnnotation`'ın dirty/yeni kaydı ezmediğini ve `pendingCount`'u test et. Refaktor istemiyorsan bu adımı **atla ve raporla** (zorlama; üretim kodunu kırma).

---

## BÖLÜM B — SUNUCU TESTLERİ (pytest)

### B1. Bağımlılık
```powershell
cd <PROJE>\server
.\.venv\Scripts\Activate.ps1
pip install pytest httpx
```
(`requirements.txt`'e `pytest` ve `httpx` eklemek istersen ekle — opsiyonel, dev.)

### B2. `server/test_main.py`
```python
from fastapi.testclient import TestClient
import main

client = TestClient(main.app)
TOKEN = main.TOKEN

def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"

def test_auth_required():
    r = client.get("/pdfs")  # token yok
    assert r.status_code == 401

def test_auth_ok():
    r = client.get("/pdfs", headers={"X-Auth-Token": TOKEN})
    assert r.status_code == 200
    assert "items" in r.json()

def test_doc_id_stable():
    a = main.doc_id_for("x/Test.pdf")
    b = main.doc_id_for("x/Test.pdf")
    assert a == b and len(a) == 16

def test_fts_query():
    assert main._fts_query("idare hukuku") == '"idare"* "hukuku"*'
    assert main._fts_query("   ") == ""
```
> `_fts_query` FAZ 15'te eklendi; yoksa o testi çıkar. Testler gerçek `data/`'ya dokunabilir (örn. pozisyon yazımı). Yan etki istemiyorsan yalnızca okuma/health/auth/saf-fonksiyon testlerinde kal; yazma endpoint testleri için ayrı bir geçici DATA_DIR fixture'ı gerekir (opsiyonel, raporla).

### B3. Çalıştır
```powershell
cd <PROJE>\server
.\.venv\Scripts\Activate.ps1
pytest -q
```
DOĞRULAMA: testler yeşil.

---

## BÖLÜM C — (Opsiyonel) CI / yerel koşucu
Repo uzakta (GitHub) ise `.github/workflows/ci.yml`; değilse yerel `run-tests.ps1`:
```powershell
# run-tests.ps1
Write-Host "== Flutter testleri =="
Push-Location app; & "C:\src\flutter\bin\flutter.bat" test; $f = $LASTEXITCODE; Pop-Location
Write-Host "== Sunucu testleri =="
Push-Location server; & ".\.venv\Scripts\python.exe" -m pytest -q; $s = $LASTEXITCODE; Pop-Location
if ($f -ne 0 -or $s -ne 0) { Write-Host "BASARISIZ"; exit 1 } else { Write-Host "HEPSI YESIL" }
```

## DOĞRULAMA / BİTİŞ
- [ ] `flutter test` model testleri yeşil
- [ ] `pytest` health/auth/saf-fonksiyon testleri yeşil
- [ ] (Varsa) LocalStore merge testi yeşil
- [ ] run-tests.ps1 / CI çalışıyor

```powershell
cd <PROJE> && git add -A && git commit -m "Faz 18: testler (flutter test + pytest) ve yerel kosucu"
```

## Ajan kuralları
1. Test için üretim kodunu KIRMA; testability gerektiren testleri (LocalStore ffi, layout) zorlama, gerekirse atla ve raporla.
2. Model alan adlarını gerçek koda uyarlat (uydurma alan kullanma).
3. Yazma endpoint testlerinde yan etki riskini gözet; şüphede okuma/saf testlerde kal.
