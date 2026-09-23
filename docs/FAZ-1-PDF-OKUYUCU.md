# FAZ 1 — PDF Okuyucu

> **Ajana not:** Önce `ROADMAP.md`'yi oku. Bu faz, Faz 0'da kurulan iskelet üzerine inşa edilir. Aşağıdaki dosyaları **birebir** oluştur/güncelle. Kod bloklarını "iyileştirme" adına değiştirme (paket sürümü, endpoint adı, alan adı vb.). Her bölümün sonundaki DOĞRULAMA başarısızsa dur ve raporla. OS: Windows, kabuk: PowerShell. Tailscale sunucu IP'si: `<SUNUCU-IP>`, port `8000`.

## Faz 1'in amacı
1. Sunucu, `server/pdf-kutuphane/` klasöründeki PDF'leri listeleyen ve indiren API sunar.
2. Tüm istekler basit bir token (`X-Auth-Token` header) ile korunur.
3. Flutter uygulaması: kütüphane ekranı (PDF listesi) → PDF'e dokun → okuyucu açılır.
4. İndirilen PDF'ler cihazda **cache**'lenir (offline tekrar açılabilir).
5. Sunucu adresi + token, uygulamada bir **Ayarlar** ekranından girilebilir.

**Bu fazda senkronizasyon (kaldığın sayfa) YOK.** O Faz 2. Burada sadece açıp okuyabilmek hedefleniyor.

---

## BÖLÜM A — SUNUCU (Python / FastAPI)

### A1. Klasörleri hazırla
```powershell
cd <PROJE>\server
New-Item -ItemType Directory -Force data
New-Item -ItemType Directory -Force pdf-kutuphane
```
Sonra **test için** `pdf-kutuphane` klasörüne en az 1 adet PDF dosyası koy (kullanıcıdan bir PDF kopyalamasını iste; örn. herhangi bir ders PDF'i). Test bunsuz yapılamaz.

### A2. `server/main.py` dosyasının TAMAMINI şu içerikle değiştir:

```python
import hashlib
import json
import secrets
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import FileResponse

BASE_DIR = Path(__file__).resolve().parent
PDF_DIR = BASE_DIR / "pdf-kutuphane"
DATA_DIR = BASE_DIR / "data"
CONFIG_PATH = DATA_DIR / "config.json"

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


@app.get("/health")
def health():
    return {"status": "ok", "service": "belgelik", "faz": 1}


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
```

### A3. Sunucuyu çalıştır ve token'ı al
```powershell
cd <PROJE>\server
.\.venv\Scripts\Activate.ps1
uvicorn main:app --host 0.0.0.0 --port 8000
```
Sunucu ilk çalıştığında `data/config.json` oluşur. İçindeki **token** değerini oku ve **kullanıcıya bildir** (uygulamaya gireceğiz):
```powershell
Get-Content <PROJE>\server\data\config.json
```

### A4. DOĞRULAMA (sunucu)
Ayrı bir PowerShell penceresinde (`<TOKEN>` yerine gerçek token):
```powershell
curl http://localhost:8000/pdfs -H "X-Auth-Token: <TOKEN>"
```
- Beklenen: `{"items":[{"id":"...","name":"...","relative_path":"...",...}]}` — koyduğun PDF görünmeli.
- Token'ı yanlış verince `401` dönmeli (auth çalışıyor demektir).

---

## BÖLÜM B — FLUTTER UYGULAMASI

`<PROJE>\app` klasöründe çalış.

### B1. Paketleri ekle
```powershell
cd <PROJE>\app
flutter pub add pdfrx http shared_preferences path_provider
```
DOĞRULAMA: `pubspec.yaml` içinde bu 4 paket `dependencies` altında görünmeli, `flutter pub get` hatasız bitmeli.

### B2. `app/lib/models.dart` oluştur:
```dart
class PdfDoc {
  final String id;
  final String name;
  final String relativePath;
  final int size;
  final int modified;

  PdfDoc({
    required this.id,
    required this.name,
    required this.relativePath,
    required this.size,
    required this.modified,
  });

  factory PdfDoc.fromJson(Map<String, dynamic> json) => PdfDoc(
        id: json['id'] as String,
        name: json['name'] as String,
        relativePath: json['relative_path'] as String,
        size: json['size'] as int,
        modified: json['modified'] as int,
      );
}
```

### B3. `app/lib/config.dart` oluştur:
```dart
import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static const _kBaseUrl = 'base_url';
  static const _kToken = 'token';

  // Varsayilan sunucu adresi (Tailscale IP). Ayarlardan degistirilebilir.
  static String baseUrl = 'http://<SUNUCU-IP>:8000';
  static String token = '';

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString(_kBaseUrl) ?? baseUrl;
    token = prefs.getString(_kToken) ?? '';
  }

  static Future<void> save(String newBaseUrl, String newToken) async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = newBaseUrl.trim();
    token = newToken.trim();
    await prefs.setString(_kBaseUrl, baseUrl);
    await prefs.setString(_kToken, token);
  }
}
```

### B4. `app/lib/api.dart` oluştur:
```dart
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'config.dart';
import 'models.dart';

class Api {
  static Map<String, String> get _headers => {'X-Auth-Token': AppConfig.token};

  static Future<List<PdfDoc>> listPdfs() async {
    final res = await http.get(
      Uri.parse('${AppConfig.baseUrl}/pdfs'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw Exception('Liste alinamadi (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final items = (data['items'] as List)
        .map((e) => PdfDoc.fromJson(e as Map<String, dynamic>))
        .toList();
    return items;
  }

  /// PDF'i cache'e indirir; zaten varsa tekrar indirmez. Dosya yolunu doner.
  static Future<File> downloadPdf(PdfDoc doc) async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${dir.path}/pdf_cache');
    if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
    final file = File('${cacheDir.path}/${doc.id}.pdf');

    if (file.existsSync() && file.lengthSync() == doc.size) {
      return file; // cache gecerli
    }

    final res = await http.get(
      Uri.parse('${AppConfig.baseUrl}/pdfs/${doc.id}/file'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw Exception('PDF indirilemedi (HTTP ${res.statusCode})');
    }
    await file.writeAsBytes(res.bodyBytes);
    return file;
  }
}
```

### B5. `app/lib/screens/settings_screen.dart` oluştur:
```dart
import 'package:flutter/material.dart';
import '../config.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _urlCtrl =
      TextEditingController(text: AppConfig.baseUrl);
  late final TextEditingController _tokenCtrl =
      TextEditingController(text: AppConfig.token);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ayarlar')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: 'Sunucu adresi',
                hintText: 'http://<SUNUCU-IP>:8000',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenCtrl,
              decoration: const InputDecoration(labelText: 'Token'),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () async {
                await AppConfig.save(_urlCtrl.text, _tokenCtrl.text);
                if (context.mounted) Navigator.pop(context, true);
              },
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }
}
```

### B6. `app/lib/screens/reader_screen.dart` oluştur:
```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../api.dart';
import '../models.dart';

class ReaderScreen extends StatelessWidget {
  final PdfDoc doc;
  const ReaderScreen({super.key, required this.doc});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(doc.name)),
      body: FutureBuilder<File>(
        future: Api.downloadPdf(doc),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Hata: ${snapshot.error}'));
          }
          return PdfViewer.file(snapshot.data!.path);
        },
      ),
    );
  }
}
```

### B7. `app/lib/screens/library_screen.dart` oluştur:
```dart
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late Future<List<PdfDoc>> _future;

  @override
  void initState() {
    super.initState();
    _future = Api.listPdfs();
  }

  void _refresh() {
    setState(() => _future = Api.listPdfs());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kütüphane'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              final changed = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
              if (changed == true) _refresh();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: FutureBuilder<List<PdfDoc>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return ListView(
                children: [
                  const SizedBox(height: 100),
                  Center(child: Text('Hata: ${snapshot.error}')),
                  const SizedBox(height: 12),
                  const Center(
                      child: Text('Ayarlardan sunucu/token kontrol et')),
                ],
              );
            }
            final items = snapshot.data!;
            if (items.isEmpty) {
              return const Center(child: Text('Hiç PDF yok'));
            }
            return ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final doc = items[i];
                return ListTile(
                  leading: const Icon(Icons.picture_as_pdf),
                  title: Text(doc.name),
                  subtitle: Text('${(doc.size / 1024 / 1024).toStringAsFixed(1)} MB'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => ReaderScreen(doc: doc)),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
```

### B8. `app/lib/main.dart` dosyasının TAMAMINI şu içerikle değiştir:
```dart
import 'package:flutter/material.dart';

import 'config.dart';
import 'screens/library_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.load();
  runApp(const BelgelikApp());
}

class BelgelikApp extends StatelessWidget {
  const BelgelikApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Belgelik',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const LibraryScreen(),
    );
  }
}
```

### B9. Android internet izni
`app/android/app/src/main/AndroidManifest.xml` dosyasında `<application` etiketinden ÖNCE (üst seviyede, `<manifest>` içinde) şu satır olmalı; yoksa ekle:
```xml
<uses-permission android:name="android.permission.INTERNET"/>
```
> Not: Tailscale HTTP (https değil) kullandığımız için cleartext trafiğe izin gerekir. `<application` etiketine `android:usesCleartextTraffic="true"` özniteliğini ekle.

---

## BÖLÜM C — ÇALIŞTIR VE TEST ET

1. Sunucu PC'de çalışır durumda olmalı (Bölüm A3).
2. Emülatör veya telefon bağlı:
```powershell
cd <PROJE>\app
flutter run
```
3. Uygulama açılınca sağ üstteki **Ayarlar** (dişli) ikonuna gir.
4. Sunucu adresi `http://<SUNUCU-IP>:8000` ve A3'te aldığın **token**'ı gir, Kaydet.
5. Kütüphane ekranına dönünce PDF listesi gelmeli.

> **Emülatör uyarısı:** Android emülatörü Tailscale ağında DEĞİLDİR; `<SUNUCU-IP>` adresine erişemeyebilir. Emülatörde test için sunucu adresini `http://10.0.2.2:8000` yap (emülatörün PC'ye eriştiği özel adres). **Gerçek telefonda** Tailscale IP'si (`<SUNUCU-IP>`) kullanılır. Bunu kullanıcıya açıkla.

---

## DOĞRULAMA / BİTİŞ KONTROL LİSTESİ
- [ ] `curl /pdfs` doğru token ile liste dönüyor, yanlış token ile 401 dönüyor
- [ ] Uygulamada kütüphane ekranı PDF'leri listeliyor
- [ ] Bir PDF'e dokununca okuyucu açılıyor ve PDF görünüyor (sayfalar kayıyor)
- [ ] Uygulamayı kapatıp aynı PDF'i tekrar açınca **internet kapalıyken bile** açılıyor (cache çalışıyor)
- [ ] Aşağı çekince (pull-to-refresh) liste yenileniyor

Hepsi yeşilse Faz 1 bitti.

```powershell
cd <PROJE>
git add .
git commit -m "Faz 1: PDF listeleme, indirme, okuyucu ve cache"
```

Sonraki adım: `docs/FAZ-2-SENKRONIZASYON.md` (Claude tarafından sağlanacak).

---

## Ajan için kurallar
1. Kod bloklarını birebir uygula; endpoint/alan/paket adı değiştirme.
2. `pdfrx` API'sinde sürüm farkı yüzünden `PdfViewer.file(path)` derlenmezse, DUR ve hatayı raporla — uydurma düzeltme yapma.
3. Her DOĞRULAMA başarısızsa sonraki adıma geçme.
4. Token'ı veya `config.json`'u dışarı sızdırma.
