# Lab VDA (run as SYSTEM through icalab.sh ga): allow microphone access for the lab users. Windows Server creates new
# profiles with HKCU ...\CapabilityAccessManager\ConsentStore\microphone Value=Deny, so waveInOpen fails (MMSYSERR_ERROR,
# MCI record 322) in every ICA session, whatever the client does (D158). Sets Value=Allow (and NonPackaged=Allow) in every
# labuser profile (loaded hive or NTUSER.DAT) and in the Default profile, and prints the before/after values.
$sub = 'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
function Fix($root, $who) {
    $k = "Registry::$root\$sub"; $before = (Get-ItemProperty $k -ErrorAction SilentlyContinue).Value
    New-Item -Path "$k\NonPackaged" -Force | Out-Null
    Set-ItemProperty -Path $k -Name Value -Value Allow -Type String
    Set-ItemProperty -Path "$k\NonPackaged" -Name Value -Value Allow -Type String
    "$who microphone " + $(if ($before) { $before } else { '-' }) + " -> " + (Get-ItemProperty $k).Value
}
$targets = @(Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -match '\\labuser\d+$' } |
    ForEach-Object { [pscustomobject]@{ Who = Split-Path $_.LocalPath -Leaf; Sid = $_.SID; Path = $_.LocalPath } })
$targets += [pscustomobject]@{ Who = 'Default'; Sid = $null; Path = 'C:\Users\Default' }
foreach ($t in $targets) {
    if ($t.Sid -and (Test-Path "Registry::HKEY_USERS\$($t.Sid)")) { Fix "HKEY_USERS\$($t.Sid)" "$($t.Who) (loaded)"; continue }
    $hive = Join-Path $t.Path 'NTUSER.DAT'
    if (-not (Test-Path $hive)) { "$($t.Who): no NTUSER.DAT"; continue }
    reg load 'HKU\IcaLabMic' $hive | Out-Null
    Fix 'HKEY_USERS\IcaLabMic' $t.Who
    [gc]::Collect(); Start-Sleep -Milliseconds 300; reg unload 'HKU\IcaLabMic' | Out-Null
}
