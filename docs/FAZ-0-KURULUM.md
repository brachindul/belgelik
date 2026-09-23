# FAZ 0 — Ortam Kurulumu ve Proje İskeleti

> **Bu dosyayı uygulayacak ajana not:** Sen bir yazılım kurulum asistanısın. Aşağıdaki adımları **sırayla** uygula. Her adımın sonunda bir **DOĞRULAMA** komutu var; o komutun beklenen çıktısını görmeden bir sonraki adıma GEÇME. Bir komut hata verirse, hatayı aynen kullanıcıya bildir ve nasıl çözüleceğini açıkla, varsayımla ilerleme. İşletim sistemi **Windows**, kabuk **PowerShell**. Proje kök klasörü: `<PROJE>`.

## Faz 0'ın amacı
Faz 0 sonunda elimizde şunlar olacak:
1. Çalışan bir Flutter kurulumu (`flutter doctor` temiz).
2. Çalışan bir Python kurulumu.
3. Tailscale'in PC'de çalıştığının ve IP'sinin bilindiğinin teyidi.
4. `app/` içinde açılıp çalışan boş bir Flutter uygulaması.
5. `server/` içinde çalışıp `/health` isteğine cevap veren boş bir FastAPI sunucusu.
6. Telefon ile sunucunun Tailscale üzerinden konuşabildiğinin teyidi.

**HİÇBİR uygulama özelliği bu fazda yazılmaz.** Sadece iskelet + "merhaba dünya".

---

## Adım 1 — Mevcut araçları kontrol et

PowerShell'de tek tek çalıştır ve çıktıları kullanıcıya raporla:

```powershell
flutter --version
dart --version
python --version
git --version
tailscale version
```

- Komut "tanınmıyor / not recognized" derse o araç **kurulu değildir**, Adım 2'ye bak.
- Kuruluysa sürümü not et.

---

## Adım 2 — Eksik araçları kur

> **winget notu:** Bu makinede winget kuruludur. Herhangi bir `winget install` komutu "kaynak/paket anlaşmasını kabul et" diye sorarsa, komuta `--accept-source-agreements --accept-package-agreements` ekle.
> **Zaten kurulu olanlar:** Android Studio ve Tailscale bu makinede KURULU ve Tailscale'e GİRİŞ YAPILMIŞ durumda. Bunları yeniden kurma; sadece sürüm/IP teyidi yap (Adım 1, 3, 4).

### 2a. Git (yoksa)
`winget install --id Git.Git -e` ile kur. Sonra yeni bir PowerShell penceresi aç (PATH yenilensin).

### 2b. Python (yoksa)
`winget install --id Python.Python.3.12 -e` ile kur. Kurulumda "Add to PATH" işaretli olmalı; winget sürümü bunu otomatik yapar.
**DOĞRULAMA:** Yeni pencerede `python --version` → `Python 3.12.x` görülmeli.

### 2c. Flutter SDK (yoksa)
1. `winget install --id Google.Flutter -e` dene.
   - winget'te bulunamazsa manuel kurulum: <https://docs.flutter.dev/get-started/install/windows> adresinden Flutter SDK zip'ini `C:\src\flutter` içine çıkar ve `C:\src\flutter\bin` klasörünü kullanıcı PATH değişkenine ekle.
2. Yeni PowerShell penceresi aç.
**DOĞRULAMA:** `flutter --version` çalışmalı.

### 2d. Android Studio (yoksa — Android emülatörü/derleme için gerekli)
`winget install --id Google.AndroidStudio -e` ile kur. Kurulduktan sonra **bir kez Android Studio'yu aç**, ilk açılış sihirbazında Android SDK + Android SDK Command-line Tools + bir emülatör (örn. Pixel) kurulmasına izin ver.

### 2e. Tailscale (yoksa)
`winget install --id tailscale.tailscale -e` ile kur, ardından giriş yap (kullanıcının kendi hesabı). Kullanıcıya "Tailscale'e giriş yapmanı ve telefonunda da Tailscale'in açık/giriş yapılmış olduğunu kontrol etmeni istiyorum" de.

---

## Adım 3 — Flutter ortamını doğrula

```powershell
flutter doctor
```

- "Android toolchain", "Flutter" satırlarında ✅ (yeşil tik) olmalı.
- Lisans uyarısı çıkarsa: `flutter doctor --android-licenses` çalıştır, hepsine `y` ver.
- "Visual Studio - develop Windows apps" satırı kırmızıysa ve **Windows masaüstü derlemesi** isteniyorsa: Visual Studio Build Tools (Desktop development with C++) kurulmalı. Şimdilik Android öncelikli olduğu için bu opsiyoneldir; kullanıcıya not düş.
- Çıktıyı kullanıcıya aynen raporla.

---

## Adım 4 — Tailscale IP'sini öğren

```powershell
tailscale ip -4
```

- Çıktı `100.x.y.z` biçiminde bir IP olmalı. Bunu **kullanıcıya bildir ve not al** — sunucu adresi olarak kullanılacak.
- Çıktı boşsa Tailscale'e giriş yapılmamıştır; `tailscale up` çalıştır ve kullanıcıyı tarayıcıdan giriş yapmaya yönlendir.

---

## Adım 5 — FastAPI sunucu iskeletini oluştur

`<PROJE>\server` klasöründe çalış.

### 5a. Sanal ortam + bağımlılıklar
```powershell
cd <PROJE>\server
python -m venv .venv
.\.venv\Scripts\Activate.ps1
```
> Not: `Activate.ps1` "betik çalıştırma engellendi" hatası verirse:
> `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned` çalıştır, `y` de, sonra tekrar dene.

### 5b. `requirements.txt` dosyasını oluştur
İçeriği:
```
fastapi
uvicorn[standard]
```
Sonra kur:
```powershell
pip install -r requirements.txt
```

### 5c. `main.py` dosyasını oluştur
İçeriği **birebir** şu olsun:
```python
from fastapi import FastAPI

app = FastAPI(title="Belgelik Calisma Sunucusu")


@app.get("/health")
def health():
    return {"status": "ok", "service": "belgelik", "faz": 0}
```

### 5d. Sunucuyu çalıştır
```powershell
uvicorn main:app --host 0.0.0.0 --port 8000
```
> `--host 0.0.0.0` ÖNEMLİ: sunucunun Tailscale ağından (telefondan) erişilebilir olması için gereklidir. `127.0.0.1` kullanma.

**DOĞRULAMA (PC'de, ayrı bir PowerShell penceresinde):**
```powershell
curl http://localhost:8000/health
```
Beklenen çıktı: `{"status":"ok","service":"belgelik","faz":0}`

**DOĞRULAMA (telefonda):** Telefonun tarayıcısında `http://<TAILSCALE-IP>:8000/health` aç (örn. `http://100.x.y.z:8000/health`). Aynı JSON görünmeli.
- Görünmezse: (1) PC'de Windows Güvenlik Duvarı'nın 8000 portunu/Python'u engellemediğini kontrol et, (2) telefonda Tailscale'in açık olduğunu kontrol et.

---

## Adım 6 — Flutter uygulama iskeletini oluştur

`<PROJE>` kökünde çalış.

```powershell
cd <PROJE>
flutter create --org com.belgelik --project-name belgelik app
```

### 6a. Çalıştırma için cihaz
Bir Android emülatörü başlat (Android Studio > Device Manager > Pixel cihazını çalıştır) **veya** USB ile telefonu bağla (telefonda Geliştirici Seçenekleri + USB hata ayıklama açık olmalı).

```powershell
cd <PROJE>\app
flutter devices
```
En az bir cihaz listelenmeli.

### 6b. Çalıştır
```powershell
flutter run
```
**DOĞRULAMA:** Emülatörde/telefonda varsayılan Flutter sayaç uygulaması (ortada sayı, sağ altta + butonu) açılmalı. + butonuna basınca sayı artmalı.

---

## Adım 7 — `.gitignore` ve git başlat

`<PROJE>\.gitignore` oluştur:
```
# Python
server/.venv/
server/data/
server/pdf-kutuphane/
__pycache__/
*.pyc

# Flutter
app/build/
app/.dart_tool/
app/.idea/
*.iml

# Genel
.DS_Store
```

Sonra:
```powershell
cd <PROJE>
git init
git add .
git commit -m "Faz 0: ortam kurulumu ve proje iskeleti"
```

---

## Faz 0 BİTİŞ KONTROL LİSTESİ
Hepsini tek tek kullanıcıya teyit ettir:

- [ ] `flutter doctor` Android tarafı temiz
- [ ] `python --version` çalışıyor
- [ ] Tailscale IP'si öğrenildi: `100.____.____.____`
- [ ] Sunucu `/health` PC'den cevap veriyor
- [ ] Sunucu `/health` **telefondan Tailscale üzerinden** cevap veriyor  ← EN KRİTİK
- [ ] Flutter boş uygulaması emülatörde/telefonda açılıyor
- [ ] git deposu başlatıldı, ilk commit atıldı

Bu liste tamamlanınca Faz 0 bitti. Bir sonraki adım: `docs/FAZ-1-PDF-OKUYUCU.md` (henüz yazılmadı, proje sahibi/Claude tarafından sağlanacak).

---

## Ajan için genel kurallar
1. Komutları **olduğu gibi** çalıştır; "iyileştirme" adına paket sürümü, port, host değiştirme.
2. Belirsizlik/hata olursa **dur ve sor**, varsayımla devam etme.
3. Her adımdaki DOĞRULAMA başarısızsa bir sonraki adıma geçme.
4. Kullanıcının makinesinde zaten kurulu olan araçları yeniden kurma; sürümünü teyit edip geç.
5. Hiçbir gizli bilgiyi (Tailscale hesabı vb.) dışarı gönderme.
