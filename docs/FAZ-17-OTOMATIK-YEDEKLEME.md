# FAZ 17 — Otomatik Yedekleme

> **Ajana not:** Önce `ROADMAP-V2.md` FAZ 17'yi oku. Sunucu/işletim tarafı (PC). Uygulama değişikliği YOK (opsiyonel /backup hariç). OS: Windows, PowerShell. DOĞRULAMA başarısızsa dur.

## Amaç
`server/data/app.db` (pozisyon/işaretleme/yer imi/program/arama indeksi) ve `server/pdf-kutuphane/` için **günlük, dönen** otomatik yedek. Eskiler otomatik temizlenir. Geri yükleme belgelenir.

---

## ADIM 1 — Yedekleme scripti `server/backup.py`
```python
"""Belgelik calisma sunucusu - yedekleme.
- app.db'yi tutarli sekilde kopyalar (SQLite backup API).
- pdf-kutuphane'yi zip'ler (opsiyonel, --pdfs ile).
- backups/ altinda gunluk klasor; N gunden eski yedekleri siler.
Kullanim:
  python backup.py            # sadece DB
  python backup.py --pdfs     # DB + PDF zip
"""
import sqlite3
import sys
import shutil
import zipfile
from datetime import datetime, timedelta
from pathlib import Path

BASE = Path(__file__).resolve().parent
DB = BASE / "data" / "app.db"
PDF_DIR = BASE / "pdf-kutuphane"
BACKUPS = BASE / "backups"
KEEP_DAYS = 14

def backup_db(dest_dir: Path):
    dest_dir.mkdir(parents=True, exist_ok=True)
    out = dest_dir / "app.db"
    if not DB.exists():
        print("app.db yok, atlandi")
        return
    # Tutarli yedek: SQLite online backup API
    src = sqlite3.connect(DB)
    dst = sqlite3.connect(out)
    with dst:
        src.backup(dst)
    src.close()
    dst.close()
    print(f"DB yedeklendi -> {out}")

def backup_pdfs(dest_dir: Path):
    if not PDF_DIR.exists():
        return
    out = dest_dir / "pdf-kutuphane.zip"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for p in PDF_DIR.rglob("*"):
            if p.is_file():
                z.write(p, p.relative_to(PDF_DIR))
    print(f"PDF'ler zip'lendi -> {out}")

def rotate():
    if not BACKUPS.exists():
        return
    cutoff = datetime.now() - timedelta(days=KEEP_DAYS)
    for d in BACKUPS.iterdir():
        if not d.is_dir():
            continue
        try:
            day = datetime.strptime(d.name, "%Y-%m-%d")
        except ValueError:
            continue
        if day < cutoff:
            shutil.rmtree(d, ignore_errors=True)
            print(f"Eski yedek silindi: {d.name}")

def main():
    today = datetime.now().strftime("%Y-%m-%d")
    dest = BACKUPS / today
    backup_db(dest)
    if "--pdfs" in sys.argv:
        backup_pdfs(dest)
    rotate()
    print("Yedekleme tamam.")

if __name__ == "__main__":
    main()
```

### `.gitignore`'a ekle
```
server/backups/
```

### DOĞRULAMA (elle)
```powershell
cd <PROJE>\server
.\.venv\Scripts\Activate.ps1
python backup.py --pdfs
```
- `server/backups/<bugün>/app.db` ve `pdf-kutuphane.zip` oluşmalı.

---

## ADIM 2 — Günlük zamanlanmış görev (Windows)
Sunucu görevindeki gibi PowerShell ile günlük 03:00'te çalıştır:
```powershell
$py = "<PROJE>\server\.venv\Scripts\python.exe"
$script = "<PROJE>\server\backup.py"
$action = New-ScheduledTaskAction -Execute $py -Argument "`"$script`" --pdfs" -WorkingDirectory "<PROJE>\server"
$trigger = New-ScheduledTaskTrigger -Daily -At 3am
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "BelgelikYedek" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Gunluk DB + PDF yedegi" -Force
```
> PDF'ler büyükse her gün zip yormaması için: ayrı bir görevle PDF'leri haftalık, DB'yi günlük yedekleyebilirsin (DB için `--pdfs`'siz ayrı görev). Basit başlangıç: günde 1, `--pdfs` ile.

### DOĞRULAMA
```powershell
Start-ScheduledTask -TaskName "BelgelikYedek"
Start-Sleep -Seconds 5
Get-ChildItem <PROJE>\server\backups
```
- Bugünün klasörü + içeriği görünmeli.

---

## ADIM 3 — (Opsiyonel) `/backup` endpoint'i
`server/main.py`'ye, uygulamadan elle tetikleme için:
```python
@app.post("/backup", dependencies=[Depends(check_auth)])
def trigger_backup(background_tasks: BackgroundTasks):
    import subprocess, sys
    background_tasks.add_task(
        lambda: subprocess.run([sys.executable, str(BASE_DIR / "backup.py"), "--pdfs"])
    )
    return {"ok": True}
```
> `BackgroundTasks` import'u FAZ 15'te eklendi. İstersen Ayarlar'a "Şimdi yedekle" butonu (`Api` üzerinden POST /backup).

---

## ADIM 4 — Geri yükleme (belgele: `server/RESTORE.md`)
```
# Yedekten geri yukleme
1. Sunucuyu durdur:  Stop-Process -Name pythonw -Force   (veya gorev/pencere)
2. Bozuk/eski app.db'yi degistir:
   Copy-Item server\backups\<tarih>\app.db server\data\app.db -Force
3. (Gerekirse) PDF'ler:
   Expand-Archive server\backups\<tarih>\pdf-kutuphane.zip -DestinationPath server\pdf-kutuphane -Force
4. Sunucuyu yeniden baslat (Start-ScheduledTask -TaskName "BelgelikSunucu").
```

## DOĞRULAMA / BİTİŞ
- [ ] `python backup.py --pdfs` yedek üretiyor
- [ ] Görev zamanlayıcı günlük tetikliyor
- [ ] 14 günden eski yedekler temizleniyor
- [ ] RESTORE.md geri yükleme adımlarını içeriyor
- [ ] backups/ .gitignore'da

```powershell
cd <PROJE> && git add -A && git commit -m "Faz 17: otomatik yedekleme (backup.py + gorev zamanlayici)"
```

## Ajan kuralları
1. `src.backup(dst)` (SQLite online backup) kullan — kopyalama sırasında DB tutarlı kalır.
2. backups/ klasörünü git'e ekleme.
3. Görev zamanlayıcıyı kullanıcı bağlamında (Interactive) kur; parola gerektiren "logon olmadan" modunu kullanma.
