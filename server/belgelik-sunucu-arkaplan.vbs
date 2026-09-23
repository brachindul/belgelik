' Belgelik Calisma Sunucusu - arka planda (pencere acmadan) baslatici
' Not: pythonw.exe kullanma — uvicorn konsol olmayinca log yazarken cokuyor.
' Bunun yerine python.exe + log dosyasina yonlendirme, pencere gizli (0).
' Yol, bu betigin bulundugu klasorden turetilir (makineden bagimsiz).
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
serverDir = fso.GetParentFolderName(WScript.ScriptFullName)
python = serverDir & "\.venv\Scripts\python.exe"
sh.CurrentDirectory = serverDir
sh.Run "cmd /c """"" & python & """ -m uvicorn main:app --host 0.0.0.0 --port 8000 >> stdout.log 2>> stderr.log""", 0, False
