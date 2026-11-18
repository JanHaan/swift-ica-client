# VDA-side webcam checker for the lab (backlog 1.10). Installed as C:\Users\Public\cam-grab.ps1 by scripts/vda/install.sh.
# In a session: powershell -nop -ep bypass -file C:\Users\Public\cam-grab.ps1 [-Seconds 6] [-Device "Citrix HDX Web Camera"] [-Bits 64]
# Opens the camera with the lab's 32-bit VLC ("Webcam Test" is the same VLC; -Bits 64: "Webcam Test 64"),
# headless (dummy interface and video output), saves every frame as PNG through VLC's scene filter, and reports:
# the camera consent value, the DirectShow video devices registered for 32-bit apps, VLC's dshow lines, the frame count
# and size, the colour bars read at mid-height of the top three quarters (ICALabCam shows W Y C G M R B K), whether
# the picture moves, and a RESULT line. Writes C:\Users\Public\camg-<user>.txt and the last frame as camg-<user>.png.
# -Bits 64: the lab's 64-bit VLC (C:\Program Files\VLC64, "Webcam Test 64") instead of the 32-bit one.
# -KillAfter N: kill VLC N s after its start (an app that dies while capturing), wait 20 s, then open the camera again
# for -Seconds with a fresh VLC: the frames, bars and RESULT are those of that second run (can an app use the camera
# after another one died with it?).
# -Expect "": skip the bar check (another test pattern, e.g. ICA Viewer's synthetic one).
param([int]$Seconds = 6, [string]$Device = 'Citrix HDX Web Camera', [string]$Expect = 'WYCGMRBK', [ValidateSet(32, 64)][int]$Bits = 32, [int]$KillAfter = 0)
Add-Type -AssemblyName System.Drawing
$base = "C:\Users\Public\camg-$env:USERNAME"
$dir = Join-Path $env:TEMP 'camgrab'
$vlcLog = Join-Path $env:TEMP 'camgrab-vlc.log'
$L = New-Object Collections.Generic.List[string]
$L.Add("time " + (Get-Date -Format s) + " user $env:USERNAME session $env:SESSIONNAME")
$ck = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam'
$L.Add("consent webcam " + (Get-ItemProperty $ck -ErrorAction SilentlyContinue).Value + ", NonPackaged " +
    (Get-ItemProperty "$ck\NonPackaged" -ErrorAction SilentlyContinue).Value)
foreach ($v in @(@(32, 'WOW6432Node\'), @(64, ''))) {
    $cat = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\$($v[1])Classes\CLSID\{860BB310-5D01-11D0-BD3B-00A0C911CE86}\Instance"
    $devs = @(Get-ChildItem $cat -ErrorAction SilentlyContinue | ForEach-Object { (Get-ItemProperty $_.PSPath).FriendlyName })
    $L.Add("$($v[0])-bit video input devices registered: " + ($devs -join ', '))
}
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $dir | Out-Null
Remove-Item "$base.png" -ErrorAction SilentlyContinue
$vlc = $(if ($Bits -eq 64) { 'C:\Program Files\VLC64\vlc.exe' } else { 'C:\Program Files (x86)\VideoLAN\VLC\vlc.exe' })
$L.Add("VLC $Bits-bit: $vlc")
function Grab($dev) {
    Remove-Item $vlcLog -ErrorAction SilentlyContinue
    $a = "-I dummy --dummy-quiet --ignore-config --no-audio --no-video-title-show dshow:// --dshow-vdev=`"$dev`" " +
         "--dshow-adev=none --video-filter=scene --scene-format=png --scene-ratio=1 --scene-prefix=f --scene-path=`"$dir`" " +
         "--vout=dummy --run-time=$Seconds --play-and-exit --file-logging --logfile=`"$vlcLog`" --log-verbose=2 vlc://quit"
    $t0 = Get-Date
    $p = Start-Process -FilePath $vlc -ArgumentList $a -PassThru
    if ($KillAfter -gt 0) {
        if (-not $p.WaitForExit(1000 * $KillAfter)) { $p.Kill(); $L.Add("vlc: killed on purpose after $KillAfter s (-KillAfter); waiting 20 s"); Start-Sleep 20 }
    } elseif (-not $p.WaitForExit(1000 * ($Seconds + 40))) { $p.Kill(); $L.Add("vlc: killed after $($Seconds + 40) s") }
    $L.Add(("vlc on `"{0}`": exit {1} after {2:N1} s" -f $dev, $p.ExitCode, ((Get-Date) - $t0).TotalSeconds))
    if (Test-Path $vlcLog) {
        $lines = @(Get-Content $vlcLog)
        $lines | Where-Object { $_ -match 'dshow|scene|error|picture|chroma|size' -and $_ -notmatch 'looking for|probing|resyncing|is at 0|creating (demux|access)|Creating an input|gives access' } |
            Select-Object -Unique | Select-Object -First 20 | ForEach-Object { $L.Add("  " + $_) }
        $script:found = @($lines | ForEach-Object { if ($_ -match 'dshow debug: found device: (.+)$') { $Matches[1].Trim() } } | Select-Object -Unique)
    }
    @(Get-ChildItem $dir -Filter *.png -ErrorAction SilentlyContinue).Count
}
# The camera the session's DirectShow lists: with the stock client's per-camera announcement (CTXCTL PnP) the session
# has "Citrix HDX Webcam - <Mac camera>" and the generic "Citrix HDX Web Camera" is refused ("unsupported device type").
# So: the requested device first; with no frame, each other "Citrix HDX" device VLC found.
$found = @()
$used = $Device
$n = Grab $Device
if ($n -eq 0) {
    foreach ($d in $found | Where-Object { $_ -ne $Device -and $_ -like 'Citrix HDX*' }) {
        Remove-Item "$dir\*" -ErrorAction SilentlyContinue
        $used = $d; $n = Grab $d
        if ($n -gt 0) { break }
    }
}
if ($KillAfter -gt 0) {
    $L.Add("killed run: $n frames; opening the camera again")
    Remove-Item "$dir\*" -ErrorAction SilentlyContinue
    $KillAfter = 0
    $n = Grab $used
}
$L.Add("devices VLC found: " + ($found -join ', ') + "; used: $used")
$files = @(Get-ChildItem $dir -Filter *.png -ErrorAction SilentlyContinue | Sort-Object Name)
$L.Add("frames: $($files.Count) in $Seconds s")
function Bars($bmp) {
    $w = $bmp.Width; $h = $bmp.Height; $s = ''
    for ($i = 0; $i -lt 8; $i++) {
        $x = [int]((2 * $i + 1) * $w / 16); $y = [int]($h * 3 / 8); $r = 0; $g = 0; $b = 0
        for ($dy = -2; $dy -le 2; $dy++) { for ($dx = -2; $dx -le 2; $dx++) {
            $c = $bmp.GetPixel([Math]::Min($w - 1, [Math]::Max(0, $x + $dx)), [Math]::Min($h - 1, [Math]::Max(0, $y + $dy)))
            $r += $c.R; $g += $c.G; $b += $c.B } }
        $k = $(if ($r / 25 -gt 128) { 4 } else { 0 }) + $(if ($g / 25 -gt 128) { 2 } else { 0 }) + $(if ($b / 25 -gt 128) { 1 } else { 0 })
        $s += 'KBGCRMYW'[$k]
    }
    $s
}
function Grid($bmp) {   # a coarse 16x12 luminance grid, for motion
    $v = @(); for ($j = 0; $j -lt 12; $j++) { for ($i = 0; $i -lt 16; $i++) {
        $c = $bmp.GetPixel([int](($i + 0.5) * $bmp.Width / 16), [int](($j + 0.5) * $bmp.Height / 12)); $v += ($c.R + $c.G + $c.B) / 3 } }
    , $v
}
$pass = $false
if ($files.Count -gt 0) {
    $first = [Drawing.Bitmap]::FromFile($files[0].FullName); $last = [Drawing.Bitmap]::FromFile($files[-1].FullName)
    $L.Add("size: $($first.Width)x$($first.Height) (first), $($last.Width)x$($last.Height) (last)")
    $b1 = Bars $first; $b2 = Bars $last
    $L.Add("bars: $b1 (first frame), $b2 (last frame)" + $(if ($Expect) { ", expected $Expect" } else { '' }))
    $g1 = Grid $first; $g2 = Grid $last; $d = 0; for ($i = 0; $i -lt $g1.Count; $i++) { $d += [Math]::Abs($g1[$i] - $g2[$i]) }
    $diff = $d / $g1.Count
    $mean = ($g2 | Measure-Object -Average).Average
    $L.Add(("motion: mean luminance difference first/last {0:N1}; last frame mean luminance {1:N0}" -f $diff, $mean))
    $first.Dispose(); $last.Dispose()
    Copy-Item $files[-1].FullName "$base.png"
    $pass = $files.Count -ge 10 -and $diff -gt 1.0 -and ((-not $Expect) -or $b2 -eq $Expect)
}
$L.Add("RESULT: " + $(if ($pass) { 'PASS' } else { 'FAIL' }) + " cam-grab $Bits-bit $($files.Count) frames")
$L | Set-Content "$base.txt"; $L
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
