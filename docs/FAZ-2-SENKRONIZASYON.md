# FAZ 2 — Senkronizasyon (Kaldığın Sayfadan Devam)

> **Ajana not:** Önce `ROADMAP.md` ve `docs/FAZ-1-PDF-OKUYUCU.md`'yi oku. Bu faz Faz 1 üzerine eklenir. Kod bloklarını birebir uygula; endpoint/alan/paket adı değiştirme. DOĞRULAMA başarısızsa dur ve raporla. OS: Windows, PowerShell. Sunucu: `<SUNUCU-IP>:8000`.

## Faz 2'nin amacı
1. Sunucu, her PDF için **okuma pozisyonunu** (sayfa numarası) SQLite'ta saklar.
2. PDF açılınca uygulama sunucudan son pozisyonu çeker ve **o sayfaya zıplar**.
3. Sayfa değiştikçe (debounce ile) ve okuyucu kapanınca pozisyon sunucuya yazılır.
4. Çakışma kuralı: **last-write-wins** — sunucu her yazımda kendi saatini `updated_at` olarak damgalar.

**Kapsam:** Sadece **sayfa numarası** senkronize edilir. Zoom / sayfa-içi scroll bu fazda YOK (ileride eklenebilir).

---

## BÖLÜM A — SUNUCU

### A1. `server/main.py` dosyasının TAMAMINI şu içerikle değiştir:
> (Faz 1'deki her şey duruyor, üzerine SQLite + pozisyon endpoint'leri eklendi.)

```python
import hashlib
import json
import secrets
import sqlite3
import time
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel

BASE_DIR = Path(__file__).resolve().parent
PDF_DIR = BASE_DIR / "pdf-kutuphane"
DATA_DIR = BASE_DIR / "data"
CONFIG_PATH = DATA_DIR / "config.json"
DB_PATH = DATA_DIR / "app.db"

PDF_DIR.mkdir(exist_ok=True)
DATA_DIR.mkdir(exist_ok=True)


def load_or_create_config() -> dict:
    if CONFIG_PATH.exists():
        return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    config = {"token": secrets.token_urlsafe(24)}
    CONFIG_PATH.write_text(json.dumps(config, indent=2), encoding="utf-8")
    return config


CONFIG = load_or_create_config()
TOKEN = CONFIG["token"]


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    with db() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS positions (
                doc_id     TEXT PRIMARY KEY,
                page       INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                device     TEXT
            )
            """
        )


init_db()

app = FastAPI(title="Belgelik Calisma Sunucusu")


def doc_id_for(relative_path: str) -> str:
    return hashlib.sha1(relative_path.encode("utf-8")).hexdigest()[:16]


def check_auth(x_auth_token: str = Header(default="")):
    if x_auth_token != TOKEN:
        raise HTTPException(status_code=401, detail="Gecersiz token")


def find_pdf_by_id(doc_id: str) -> Path | None:
    for path in PDF_DIR.rglob("*.pdf"):
        rel = path.relative_to(PDF_DIR).as_posix()
        if doc_id_for(rel) == doc_id:
            return path
    return None


class PositionIn(BaseModel):
    page: int
    device: str | None = None


@app.get("/health")
def health():
    return {"status": "ok", "service": "belgelik", "faz": 2}


@app.get("/pdfs", dependencies=[Depends(check_auth)])
def list_pdfs():
    items = []
    for path in sorted(PDF_DIR.rglob("*.pdf")):
        rel = path.relative_to(PDF_DIR).as_posix()
        stat = path.stat()
        items.append({
            "id": doc_id_for(rel),
            "name": path.stem,
            "relative_path": rel,
            "size": stat.st_size,
            "modified": int(stat.st_mtime),
        })
    return {"items": items}


@app.get("/pdfs/{doc_id}/file", dependencies=[Depends(check_auth)])
def get_pdf_file(doc_id: str):
    path = find_pdf_by_id(doc_id)
    if path is None:
        raise HTTPException(status_code=404, detail="PDF bulunamadi")
    return FileResponse(path, media_type="application/pdf", filename=path.name)


@app.get("/position/{doc_id}", dependencies=[Depends(check_auth)])
def get_position(doc_id: str):
    with db() as conn:
        row = conn.execute(
            "SELECT page, updated_at, device FROM positions WHERE doc_id = ?",
            (doc_id,),
        ).fetchone()
    if row is None:
        return {"position": None}
    return {
        "position": {
            "page": row["page"],
            "updated_at": row["updated_at"],
            "device": row["device"],
        }
    }


@app.put("/position/{doc_id}", dependencies=[Depends(check_auth)])
def put_position(doc_id: str, body: PositionIn):
    now = int(time.time())
    with db() as conn:
        conn.execute(
            """
            INSERT INTO positions (doc_id, page, updated_at, device)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(doc_id) DO UPDATE SET
                page = excluded.page,
                updated_at = excluded.updated_at,
                device = excluded.device
            """,
            (doc_id, body.page, now, body.device),
        )
    return {"ok": True, "updated_at": now}
```

### A2. Sunucuyu yeniden başlat
```powershell
cd <PROJE>\server
.\.venv\Scripts\Activate.ps1
uvicorn main:app --host 0.0.0.0 --port 8000
```

### A3. DOĞRULAMA (sunucu) — `<TOKEN>` ve `<ID>` gerçek değerlerle
Önce bir PDF id'si al:
```powershell
curl http://localhost:8000/pdfs -H "X-Auth-Token: <TOKEN>"
```
Pozisyon yaz ve oku:
```powershell
curl -X PUT http://localhost:8000/position/<ID> -H "X-Auth-Token: <TOKEN>" -H "Content-Type: application/json" -d "{\"page\": 42, \"device\": \"test\"}"
curl http://localhost:8000/position/<ID> -H "X-Auth-Token: <TOKEN>"
```
- İkinci komut `{"position":{"page":42,...}}` dönmeli.
- Hiç yazılmamış bir id için `{"position":null}` dönmeli.

---

## BÖLÜM B — FLUTTER UYGULAMASI

### B1. `app/lib/models.dart` dosyasına `ReadingPosition` sınıfını EKLE (mevcut `PdfDoc` kalsın):
```dart
class ReadingPosition {
  final int page;
  final int updatedAt;
  final String? device;

  ReadingPosition({
    required this.page,
    required this.updatedAt,
    this.device,
  });

  factory ReadingPosition.fromJson(Map<String, dynamic> json) => ReadingPosition(
        page: json['page'] as int,
        updatedAt: json['updated_at'] as int,
        device: json['device'] as String?,
      );
}
```

### B2. `app/lib/config.dart` dosyasına cihaz kimliği EKLE
`AppConfig` sınıfının içine şunları ekle (mevcut alanlar/metotlar kalsın):
```dart
  static const _kDeviceId = 'device_id';
  static String deviceId = '';
```
`load()` metodunun SONUNA ekle:
```dart
    deviceId = prefs.getString(_kDeviceId) ?? '';
    if (deviceId.isEmpty) {
      deviceId = 'cihaz-${DateTime.now().millisecondsSinceEpoch % 100000}';
      await prefs.setString(_kDeviceId, deviceId);
    }
```

### B3. `app/lib/api.dart` dosyasına iki metot EKLE
`import` satırlarının altına gerek yok; sadece `Api` sınıfının içine şu iki metodu ekle (mevcut metotlar kalsın). `models.dart` zaten import edilmiş durumda.
```dart
  static Future<ReadingPosition?> getPosition(String docId) async {
    final res = await http.get(
      Uri.parse('${AppConfig.baseUrl}/position/$docId'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw Exception('Pozisyon alinamadi (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final pos = data['position'];
    if (pos == null) return null;
    return ReadingPosition.fromJson(pos as Map<String, dynamic>);
  }

  static Future<void> putPosition(String docId, int page) async {
    await http.put(
      Uri.parse('${AppConfig.baseUrl}/position/$docId'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'page': page, 'device': AppConfig.deviceId}),
    );
  }
```

### B4. `app/lib/screens/reader_screen.dart` dosyasının TAMAMINI şu içerikle değiştir:
> Artık StatefulWidget: dosya + kayıtlı pozisyon paralel yüklenir, viewer hazır olunca o sayfaya zıplar, sayfa değişince (debounce) ve ekran kapanınca pozisyon kaydedilir.

```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../api.dart';
import '../models.dart';

class ReaderScreen extends StatefulWidget {
  final PdfDoc doc;
  const ReaderScreen({super.key, required this.doc});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final PdfViewerController _controller = PdfViewerController();
  late final Future<_ReaderData> _loadFuture;

  int? _savedPage;
  int _currentPage = 1;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadFuture = _load();
  }

  Future<_ReaderData> _load() async {
    final results = await Future.wait([
      Api.downloadPdf(widget.doc),
      Api.getPosition(widget.doc.id),
    ]);
    final file = results[0] as File;
    final pos = results[1] as ReadingPosition?;
    _savedPage = pos?.page;
    return _ReaderData(file: file, savedPage: pos?.page);
  }

  void _onPageChanged(int? page) {
    if (page == null) return;
    _currentPage = page;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), _savePosition);
  }

  void _savePosition() {
    // fire-and-forget; hata olursa sessizce gec (offline olabilir)
    Api.putPosition(widget.doc.id, _currentPage).catchError((_) {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _savePosition(); // ekran kapanirken son sayfayi yaz
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.doc.name)),
      body: FutureBuilder<_ReaderData>(
        future: _loadFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Hata: ${snapshot.error}'));
          }
          final data = snapshot.data!;
          return PdfViewer.file(
            data.file.path,
            controller: _controller,
            params: PdfViewerParams(
              onViewerReady: (document, controller) {
                final target = data.savedPage;
                if (target != null && target > 1) {
                  controller.goToPage(pageNumber: target);
                }
              },
              onPageChanged: _onPageChanged,
            ),
          );
        },
      ),
    );
  }
}

class _ReaderData {
  final File file;
  final int? savedPage;
  _ReaderData({required this.file, this.savedPage});
}
```

### B5. (Opsiyonel ama önerilir) Kütüphanede "kaldığın sayfa" rozeti
Bu adımı atlayabilirsin; çekirdek sync B4'te tamamlanıyor. İstersen kütüphane listesinde son sayfayı gösterebilirsin ama bu faz için zorunlu değil.

---

## BÖLÜM C — TEST

1. Sunucu çalışıyor olmalı.
2. `flutter run` ile uygulamayı aç.
3. Bir PDF aç, birkaç sayfa ilerle (örn. 10. sayfa), **2 saniye bekle** (debounce yazsın), ekrandan çık.
4. Sunucuda doğrula:
```powershell
curl http://localhost:8000/position/<ID> -H "X-Auth-Token: <TOKEN>"
```
   → `page` senin bıraktığın sayfaya yakın olmalı.
5. Aynı PDF'i tekrar aç → **otomatik o sayfaya zıplamalı.**
6. **Asıl test (iki cihaz):** Telefonda 30. sayfaya git, çık. Emülatörde (veya başka cihazda) aynı PDF'i aç → 30. sayfadan açılmalı.

> Tek cihazın varsa: telefonda sayfayı ilerlet → çık → uygulamayı tamamen kapat → tekrar aç → aynı sayfadan açılıyorsa sync çalışıyor demektir.

---

## DOĞRULAMA / BİTİŞ KONTROL LİSTESİ
- [ ] `PUT /position` + `GET /position` curl ile çalışıyor
- [ ] PDF'te ilerleyip çıkınca sunucuda `page` güncelleniyor
- [ ] PDF'i tekrar açınca kaldığın sayfaya zıplıyor
- [ ] (Varsa ikinci cihaz) bir cihazda bırakılan sayfa diğerinde açılıyor
- [ ] Offline (sunucu kapalı) iken PDF yine açılıyor, pozisyon yazımı sessizce başarısız oluyor (uygulama çökmesin)

Hepsi yeşilse **MVP TAMAMLANDI** 🎉 (Faz 0+1+2).

```powershell
cd <PROJE>
git add .
git commit -m "Faz 2: okuma pozisyonu senkronizasyonu (last-write-wins)"
```

Sonraki adım: `docs/FAZ-3-POMODORO.md` (Claude tarafından sağlanacak).

---

## Ajan için kurallar
1. pdfrx API'si bu sürümde farklıysa (`PdfViewerParams`, `onViewerReady`, `onPageChanged`, `goToPage(pageNumber:)` derlenmezse) DUR ve hatayı + `pubspec.lock`'taki pdfrx sürümünü raporla. Uydurma düzeltme yapma.
2. Kod bloklarını birebir uygula.
3. Her DOĞRULAMA başarısızsa sonraki adıma geçme.
