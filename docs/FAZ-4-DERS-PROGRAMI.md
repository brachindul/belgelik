# FAZ 4 — Ders Programı

> **Ajana not:** Önce `ROADMAP.md`'yi oku. Bu faz Faz 1-3 üzerine eklenir. Kod bloklarını birebir uygula. DOĞRULAMA başarısızsa dur ve raporla. OS: Windows, PowerShell. Sunucu: `<SUNUCU-IP>:8000`.

## Faz 4'ün amacı
1. Sunucu, **tarih bazlı çalışma görevlerini** SQLite'ta saklar (örn. 2026-06-10 → "İdare Hukuku, 120 dk").
2. Görevler çapraz cihaz senkronize olur (sunucu = gerçeğin kaynağı).
3. Uygulamada 3. sekme **Program**: günün görevleri, ekle/sil, tamamlandı işaretle, günler arası gezinme.

**Kapsam:** Tarih bazlı görev CRUD + tamamlandı işareti. Haftalık otomatik tekrar ve pomodoro-ders bağlama bu fazda YOK (Faz 5'te opsiyonel).

---

## BÖLÜM A — SUNUCU

### A1. `server/main.py` dosyasının TAMAMINI şu içerikle değiştir:
> (Faz 1-2'deki her şey duruyor; üzerine `tasks` tablosu + görev endpoint'leri eklendi.)

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
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS tasks (
                id             INTEGER PRIMARY KEY AUTOINCREMENT,
                date           TEXT NOT NULL,
                subject        TEXT NOT NULL,
                target_minutes INTEGER NOT NULL DEFAULT 0,
                done           INTEGER NOT NULL DEFAULT 0,
                updated_at     INTEGER NOT NULL
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


class TaskIn(BaseModel):
    date: str
    subject: str
    target_minutes: int = 0


class TaskUpdate(BaseModel):
    subject: str | None = None
    target_minutes: int | None = None
    done: bool | None = None


@app.get("/health")
def health():
    return {"status": "ok", "service": "belgelik", "faz": 4}


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


def _task_row_to_dict(row) -> dict:
    return {
        "id": row["id"],
        "date": row["date"],
        "subject": row["subject"],
        "target_minutes": row["target_minutes"],
        "done": bool(row["done"]),
        "updated_at": row["updated_at"],
    }


@app.get("/tasks", dependencies=[Depends(check_auth)])
def list_tasks(date: str):
    with db() as conn:
        rows = conn.execute(
            "SELECT * FROM tasks WHERE date = ? ORDER BY id",
            (date,),
        ).fetchall()
    return {"items": [_task_row_to_dict(r) for r in rows]}


@app.post("/tasks", dependencies=[Depends(check_auth)])
def create_task(body: TaskIn):
    now = int(time.time())
    with db() as conn:
        cur = conn.execute(
            """
            INSERT INTO tasks (date, subject, target_minutes, done, updated_at)
            VALUES (?, ?, ?, 0, ?)
            """,
            (body.date, body.subject, body.target_minutes, now),
        )
        new_id = cur.lastrowid
        row = conn.execute("SELECT * FROM tasks WHERE id = ?", (new_id,)).fetchone()
    return _task_row_to_dict(row)


@app.put("/tasks/{task_id}", dependencies=[Depends(check_auth)])
def update_task(task_id: int, body: TaskUpdate):
    now = int(time.time())
    with db() as conn:
        row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Gorev bulunamadi")
        subject = body.subject if body.subject is not None else row["subject"]
        target = (
            body.target_minutes
            if body.target_minutes is not None
            else row["target_minutes"]
        )
        done = (
            (1 if body.done else 0) if body.done is not None else row["done"]
        )
        conn.execute(
            """
            UPDATE tasks
            SET subject = ?, target_minutes = ?, done = ?, updated_at = ?
            WHERE id = ?
            """,
            (subject, target, done, now, task_id),
        )
        row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    return _task_row_to_dict(row)


@app.delete("/tasks/{task_id}", dependencies=[Depends(check_auth)])
def delete_task(task_id: int):
    with db() as conn:
        conn.execute("DELETE FROM tasks WHERE id = ?", (task_id,))
    return {"ok": True}
```

### A2. Sunucuyu yeniden başlat
```powershell
cd <PROJE>\server
.\.venv\Scripts\Activate.ps1
uvicorn main:app --host 0.0.0.0 --port 8000
```

### A3. DOĞRULAMA (sunucu) — `<TOKEN>` gerçek değerle
```powershell
curl -X POST http://localhost:8000/tasks -H "X-Auth-Token: <TOKEN>" -H "Content-Type: application/json" -d "{\"date\": \"2026-06-10\", \"subject\": \"Idare Hukuku\", \"target_minutes\": 120}"
curl "http://localhost:8000/tasks?date=2026-06-10" -H "X-Auth-Token: <TOKEN>"
```
- İkinci komut eklediğin görevi `id` ile birlikte dönmeli.

---

## BÖLÜM B — FLUTTER UYGULAMASI

### B1. `app/lib/models.dart`'a `StudyTask` EKLE (mevcutlar kalsın):
```dart
class StudyTask {
  final int id;
  final String date;
  final String subject;
  final int targetMinutes;
  final bool done;

  StudyTask({
    required this.id,
    required this.date,
    required this.subject,
    required this.targetMinutes,
    required this.done,
  });

  factory StudyTask.fromJson(Map<String, dynamic> json) => StudyTask(
        id: json['id'] as int,
        date: json['date'] as String,
        subject: json['subject'] as String,
        targetMinutes: json['target_minutes'] as int,
        done: json['done'] as bool,
      );
}
```

### B2. `app/lib/api.dart`'a görev metotlarını EKLE (`Api` sınıfı içine):
```dart
  static Future<List<StudyTask>> getTasks(String date) async {
    final res = await http.get(
      Uri.parse('${AppConfig.baseUrl}/tasks?date=$date'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw Exception('Gorevler alinamadi (HTTP ${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (data['items'] as List)
        .map((e) => StudyTask.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> createTask(
      String date, String subject, int targetMinutes) async {
    final res = await http.post(
      Uri.parse('${AppConfig.baseUrl}/tasks'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'date': date,
        'subject': subject,
        'target_minutes': targetMinutes,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Gorev eklenemedi (HTTP ${res.statusCode})');
    }
  }

  static Future<void> updateTask(int id, {bool? done}) async {
    final res = await http.put(
      Uri.parse('${AppConfig.baseUrl}/tasks/$id'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({if (done != null) 'done': done}),
    );
    if (res.statusCode != 200) {
      throw Exception('Gorev guncellenemedi (HTTP ${res.statusCode})');
    }
  }

  static Future<void> deleteTask(int id) async {
    await http.delete(
      Uri.parse('${AppConfig.baseUrl}/tasks/$id'),
      headers: _headers,
    );
  }
```

### B3. `app/lib/screens/schedule_screen.dart` oluştur:
```dart
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';

class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  DateTime _date = DateTime.now();
  late Future<List<StudyTask>> _future;

  String get _dateStr {
    final y = _date.year.toString().padLeft(4, '0');
    final m = _date.month.toString().padLeft(2, '0');
    final d = _date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() => _future = Api.getTasks(_dateStr));
  }

  void _changeDay(int delta) {
    setState(() => _date = _date.add(Duration(days: delta)));
    _reload();
  }

  Future<void> _addTaskDialog() async {
    final subjectCtrl = TextEditingController();
    final minutesCtrl = TextEditingController(text: '60');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Görev ekle'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: subjectCtrl,
              decoration: const InputDecoration(labelText: 'Ders / konu'),
            ),
            TextField(
              controller: minutesCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Hedef (dakika)'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('İptal')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Ekle')),
        ],
      ),
    );
    if (ok == true && subjectCtrl.text.trim().isNotEmpty) {
      await Api.createTask(
        _dateStr,
        subjectCtrl.text.trim(),
        int.tryParse(minutesCtrl.text) ?? 0,
      );
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Program')),
      floatingActionButton: FloatingActionButton(
        onPressed: _addTaskDialog,
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                    onPressed: () => _changeDay(-1),
                    icon: const Icon(Icons.chevron_left)),
                TextButton(
                  onPressed: () {
                    setState(() => _date = DateTime.now());
                    _reload();
                  },
                  child: Text(_dateStr,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                    onPressed: () => _changeDay(1),
                    icon: const Icon(Icons.chevron_right)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<StudyTask>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Hata: ${snapshot.error}'));
                }
                final tasks = snapshot.data!;
                if (tasks.isEmpty) {
                  return const Center(child: Text('Bu güne görev yok'));
                }
                return ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (context, i) {
                    final t = tasks[i];
                    return Dismissible(
                      key: ValueKey(t.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      onDismissed: (_) async {
                        await Api.deleteTask(t.id);
                      },
                      child: CheckboxListTile(
                        value: t.done,
                        onChanged: (v) async {
                          await Api.updateTask(t.id, done: v ?? false);
                          _reload();
                        },
                        title: Text(
                          t.subject,
                          style: TextStyle(
                            decoration: t.done
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        subtitle: Text('${t.targetMinutes} dk'),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
```

### B4. `app/lib/screens/home_shell.dart` güncelle — 3. sekme ekle
```dart
import 'package:flutter/material.dart';

import 'library_screen.dart';
import 'pomodoro_screen.dart';
import 'schedule_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  final _pages = const [
    LibraryScreen(),
    ScheduleScreen(),
    PomodoroScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.library_books), label: 'Kütüphane'),
          NavigationDestination(
              icon: Icon(Icons.calendar_today), label: 'Program'),
          NavigationDestination(icon: Icon(Icons.timer), label: 'Pomodoro'),
        ],
      ),
    );
  }
}
```

---

## BÖLÜM C — TEST

```powershell
cd <PROJE>\app
flutter run
```
1. Alt menüde **Program** sekmesine geç.
2. Sağ alttaki **+** ile görev ekle (ders adı + dakika).
3. Görev listede görünmeli.
4. Checkbox ile tamamlandı işaretle → üstü çizilmeli.
5. Görevi sola kaydır → silinmeli.
6. Gün okları (`<` `>`) ile başka güne geç, geri gelince görev hâlâ orada (sunucudan).
7. **Sync testi:** Bir cihazda görev ekle, diğer cihazda aynı güne bak → görünmeli.
8. Diğer sekmeler (Kütüphane, Pomodoro) hâlâ çalışıyor olmalı (regresyon yok).

---

## DOĞRULAMA / BİTİŞ KONTROL LİSTESİ
- [ ] `POST/GET/PUT/DELETE /tasks` curl ile çalışıyor
- [ ] Program sekmesinde görev ekleme/silme/işaretleme çalışıyor
- [ ] Günler arası gezinme doğru görevleri getiriyor
- [ ] Görevler sunucuda kalıcı (uygulamayı kapatıp açınca duruyor)
- [ ] (Varsa 2. cihaz) görevler çapraz cihaz senkronize
- [ ] Kütüphane + Pomodoro regresyonsuz

Hepsi yeşilse Faz 4 bitti — **dört ana özellik tamam!** 🎉

```powershell
cd <PROJE>
git add .
git commit -m "Faz 4: ders programi (tarih bazli gorevler, capraz cihaz sync)"
```

Sonraki adım: `docs/FAZ-5-CILA.md` (opsiyonel — karanlık tema, istatistik, sınav geri sayımı, pomodoro-ders bağlama vb.).

---

## Ajan için kurallar
1. Kod bloklarını birebir uygula; endpoint/alan adı değiştirme.
2. Her DOĞRULAMA başarısızsa sonraki adıma geçme.
3. Belirsizlikte dur ve raporla.
