# Yedekten geri yukleme (coklu profil)

Yedekler `server/backups/<tarih>/<profil-id>/` altinda tutulur:
```
backups/2026-07-04/profil1/app.db
backups/2026-07-04/profil1/pdf-kutuphane.zip   (--pdfs ile alindiysa)
backups/2026-07-04/profil2/app.db
backups/2026-07-04/profil2/pdf-kutuphane.zip
backups/2026-07-04/_legacy/app.db            (eski tekil data/app.db varsa)
```

Adimlar (`<tarih>` ve `<profil>` degerlerini kendine gore degistir):
1. Sunucuyu durdur:  `Stop-Process -Name pythonw -Force`   (veya gorev/pencere)
2. Bozuk/eski DB'yi degistir (ilgili profilin DB'si `data\<profil>\app.db`):
   `Copy-Item server\backups\<tarih>\<profil>\app.db server\data\<profil>\app.db -Force`
3. (Gerekirse) PDF'ler (ilgili profilin kutuphanesine):
   - profil1 -> `server\pdf-kutuphane`, profil2 -> `server\pdf-profil2` (config.json'daki pdf_dir'e bak)
   `Expand-Archive server\backups\<tarih>\<profil>\pdf-kutuphane.zip -DestinationPath server\pdf-kutuphane -Force`
4. Sunucuyu yeniden baslat (`Start-ScheduledTask -TaskName "BelgelikSunucu"`).

> Not: `python backup.py` config.json'daki tum profilleri otomatik yedekler.
> `--pdfs` eklenirse her profilin PDF kutuphanesi de zip'lenir.

## Mevzuat haftalık yenileme (Faz 24)

Windows Görev Zamanlayıcı’da haftalık çalıştırılabilecek komut:

```powershell
server\.venv\Scripts\python.exe server\mevzuat_watch.py --db server\data\<profil>\app.db
```

Bu komut yalnızca Emsal-mcp üzerinden yenileme yapar; doğrudan mevzuat sitesi
scraper’ı değildir. Emsal-mcp Resmî Gazete adaptörü arama desteği kazandığında
watcher aynı ingest/diff akışını kullanacaktır.
