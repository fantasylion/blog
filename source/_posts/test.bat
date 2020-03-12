@ECHO OFF
powershell.exe -command "ls 'C:\DATA\code\blog\source\_posts\2016-03-30-introduce-ffmpeg.md' | foreach-object { $_.LastWriteTime = '03/30/2016 22:13:36'; $_.CreationTime = '03/30/2016 22:13:36' }"
PAUSE