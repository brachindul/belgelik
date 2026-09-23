# Flutter yolu: once PATH'teki 'flutter'i dene, bulunamazsa sabit kuruluma dus.
$flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutter) { $flutter = "C:\src\flutter\bin\flutter.bat" }

Write-Host "== Flutter testleri =="
Push-Location app; & $flutter test; $f = $LASTEXITCODE; Pop-Location
Write-Host "== Sunucu testleri =="
Push-Location server; & ".\.venv\Scripts\python.exe" -m pytest -q; $s = $LASTEXITCODE; Pop-Location
if ($f -ne 0 -or $s -ne 0) { Write-Host "BASARISIZ"; exit 1 } else { Write-Host "HEPSI YESIL" }
