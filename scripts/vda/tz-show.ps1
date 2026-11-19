# The session's time zone, for the client time zone checks (docs/30 §4.4): prints one line and writes it to
# C:\Users\Public\tz-<user>.txt; -Clip also puts it on the session clipboard (icactl tzprobe reads it there).
#   powershell -nop -ep bypass -file C:\Users\Public\tz-show.ps1 [-Clip] [-Tag stock]
param([switch]$Clip, [string]$Tag = '')
$z = Get-TimeZone
$offset = [TimeZoneInfo]::Local.GetUtcOffset([DateTime]::UtcNow).TotalMinutes
$tzutil = (tzutil /g) -join ' '
$line = "TZSHOW id=$($z.Id) | offset=$offset | dst=$([TimeZoneInfo]::Local.IsDaylightSavingTime([DateTime]::Now)) | " +
        "tzutil=$tzutil | standard=$($z.StandardName) | daylight=$($z.DaylightName) | now=$(Get-Date -Format o) | time=$(cmd /c echo %TIME%)"
$name = if ($Tag) { "tz-$Tag-$env:USERNAME.txt" } else { "tz-$env:USERNAME.txt" }
$line | Set-Content -Encoding ascii "C:\Users\Public\$name"
if ($Clip) { Set-Clipboard -Value $line }
$line
