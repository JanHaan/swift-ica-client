# A full-screen window with a bar docked at the monitor's top, as Remote Desktop Connection shows in full screen
# (docs/80 §7.1, D197, VM scenario S33):
#   powershell -nop -ep bypass -file C:\Users\Public\fs-bar.ps1 [-Mode full|max] [-Seconds N]
# full: FSBAR-FULL, a borderless window covering the primary monitor, and FSBAR-BAR, a topmost 576x27 bar (at 100 %;
#       scaled with the DPI) at the monitor's top centre. A click on the bar turns it green ("CLICKED").
# max:  FSBAR-MAX, an ordinary window, maximised.
# Every state goes to C:\Users\Public\fsbar-<user>.txt (bounds, work area, clicks). Ends after N seconds (default 90).
param([string]$Mode = 'full', [int]$Seconds = 90)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$log = "C:\Users\Public\fsbar-$env:USERNAME.txt"
function Note([string]$line) { Add-Content -Encoding ascii $log "$(Get-Date -Format o) $line"; $line }
Set-Content -Encoding ascii $log ''
$screen = [Windows.Forms.Screen]::PrimaryScreen
$g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $s = $g.DpiY / 96; $g.Dispose()
Note "FSBAR start mode=$Mode monitor=$($screen.Bounds) work=$($screen.WorkingArea) dpiScale=$s"
$timer = New-Object Windows.Forms.Timer
$timer.Interval = $Seconds * 1000
$timer.add_Tick({ Note 'FSBAR end'; [Windows.Forms.Application]::Exit() })
$timer.Start()
if ($Mode -eq 'max') {
    $f = New-Object Windows.Forms.Form
    $f.Text = 'FSBAR-MAX'; $f.BackColor = [Drawing.Color]::FromArgb(250, 250, 250)
    $f.WindowState = 'Maximized'
    $f.add_Shown({ Note "FSBAR max bounds=$($f.Bounds) client=$($f.RectangleToScreen($f.ClientRectangle))" })
    [Windows.Forms.Application]::Run($f)
    exit
}
$full = New-Object Windows.Forms.Form
$full.Text = 'FSBAR-FULL'; $full.FormBorderStyle = 'None'; $full.StartPosition = 'Manual'
$full.Bounds = $screen.Bounds; $full.BackColor = [Drawing.Color]::FromArgb(40, 40, 40)
$bar = New-Object Windows.Forms.Form
$bar.Text = 'FSBAR-BAR'; $bar.FormBorderStyle = 'None'; $bar.StartPosition = 'Manual'; $bar.TopMost = $true
$bar.ShowInTaskbar = $false; $bar.Owner = $full
$w = [int](576 * $s); $h = [int](27 * $s)
$bar.Bounds = New-Object Drawing.Rectangle(($screen.Bounds.X + ($screen.Bounds.Width - $w) / 2), $screen.Bounds.Y, $w, $h)
$button = New-Object Windows.Forms.Button
$button.Dock = 'Fill'; $button.FlatStyle = 'Flat'; $button.FlatAppearance.BorderSize = 0
$button.BackColor = [Drawing.Color]::FromArgb(0, 90, 200); $button.ForeColor = [Drawing.Color]::White; $button.Text = 'FSBAR'
$clicks = 0
$button.add_Click({
    $script:clicks++
    $button.BackColor = [Drawing.Color]::FromArgb(0, 200, 0); $button.Text = "CLICKED $script:clicks"
    Note "FSBAR clicked $script:clicks"
})
$bar.Controls.Add($button)
$full.add_Shown({ $bar.Show(); Note "FSBAR full bounds=$($full.Bounds) bar=$($bar.Bounds)" })
[Windows.Forms.Application]::Run($full)
