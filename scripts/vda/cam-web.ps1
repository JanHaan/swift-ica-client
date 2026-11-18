# VDA-side browser webcam checker for the lab (backlog 1.10). Installed as C:\Users\Public\cam-web.ps1 by scripts/vda/install.sh.
# In a session: powershell -nop -ep bypass -file C:\Users\Public\cam-web.ps1 [-Seconds 6]
# Opens a local page in the lab's Edge (64-bit, Chromium: Media Foundation capture, DirectShow as a fallback) with
# --use-fake-ui-for-media-stream (the camera permission is granted without a prompt) and a throw-away profile. The page
# lists the video inputs, opens the first one whose label contains "Citrix" (else the default), counts frames for
# -Seconds and reads the colour bars of the last frame like cam-grab.ps1 (WYCGMRBK for ICALabCam). It reports through
# the window title, which this script reads; then Edge is closed. Writes C:\Users\Public\camw-<user>.txt.
param([int]$Seconds = 6)
$base = "C:\Users\Public\camw-$env:USERNAME"
$page = Join-Path $env:TEMP 'camweb.html'
$prof = Join-Path $env:TEMP 'camweb-profile'
@"
<!doctype html><html><head><title>CAMWEB starting</title></head><body><video id=v autoplay muted playsinline></video>
<canvas id=c></canvas><script>
const say = t => { document.title = 'CAMWEB ' + t; };
(async () => {
  try {
    let s0 = await navigator.mediaDevices.getUserMedia({video: true}); s0.getTracks().forEach(t => t.stop());
    const ins = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'videoinput');
    const names = ins.map(d => d.label).join('|');
    const pick = ins.find(d => /citrix/i.test(d.label)) || ins[0];
    const s = await navigator.mediaDevices.getUserMedia({video: {deviceId: {exact: pick.deviceId}}});
    const v = document.getElementById('v'); v.srcObject = s; await v.play();
    let n = 0; const tick = () => { n++; v.requestVideoFrameCallback(tick); }; v.requestVideoFrameCallback(tick);
    await new Promise(r => setTimeout(r, $Seconds * 1000));
    const c = document.getElementById('c'); c.width = v.videoWidth; c.height = v.videoHeight;
    const g = c.getContext('2d'); g.drawImage(v, 0, 0);
    let bars = '';
    for (let i = 0; i < 8; i++) {
      const p = g.getImageData(Math.floor((2 * i + 1) * c.width / 16), Math.floor(c.height * 3 / 8), 1, 1).data;
      bars += 'KBGCRMYW'[(p[0] > 128 ? 4 : 0) + (p[1] > 128 ? 2 : 0) + (p[2] > 128 ? 1 : 0)];
    }
    say('done devices=[' + names + '] used=[' + pick.label + '] frames=' + n + ' size=' + v.videoWidth + 'x' + v.videoHeight + ' bars=' + bars);
  } catch (e) { say('error ' + e.name + ': ' + e.message); }
})();
</script></body></html>
"@ | Set-Content -Encoding UTF8 $page
Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
$L = New-Object Collections.Generic.List[string]
$L.Add("time " + (Get-Date -Format s) + " user $env:USERNAME session $env:SESSIONNAME; Edge $((Get-Item $edge).VersionInfo.ProductVersion)")
$a = "--user-data-dir=`"$prof`" --use-fake-ui-for-media-stream --no-first-run --no-default-browser-check --new-window `"file:///$($page -replace '\\','/')`""
Start-Process -FilePath $edge -ArgumentList $a | Out-Null
$title = ''
$deadline = (Get-Date).AddSeconds($Seconds + 60)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    $t = (Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like 'CAMWEB*' } | Select-Object -First 1).MainWindowTitle
    if ($t) { $title = $t }
    if ($title -match '^CAMWEB (done|error)') { break }
}
$L.Add("page: " + $(if ($title) { $title -replace ' - .*Edge.*$', '' } else { 'no CAMWEB window title' }))
Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $edge } |
    Where-Object { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -like "*camweb-profile*" } |
    Stop-Process -Force -ErrorAction SilentlyContinue
$frames = if ($title -match 'frames=(\d+)') { [int]$Matches[1] } else { 0 }
$pass = $frames -ge 10 -and $title -match 'bars=WYCGMRBK'
$L.Add("RESULT: " + $(if ($pass) { 'PASS' } else { 'FAIL' }) + " cam-web $frames frames")
$L | Set-Content "$base.txt"; $L
Remove-Item $page -ErrorAction SilentlyContinue
