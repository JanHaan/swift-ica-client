# VDA-side microphone recorder for the lab (backlog 1.6). Replaces mic-rec.ps1's MCI path, which returned 322 and a
# 44-byte WAV for the stock client too. Installed as C:\Users\Public\mic-wavein.ps1 by scripts/vda/install.sh.
# In a session: powershell -nop -ep bypass -file C:\Users\Public\mic-wavein.ps1 [-Seconds 4]
# Lists the waveIn devices and the privacy consent values, tries waveInOpen for a few PCM formats (mapper, then
# device 0), records with the first that opens, writes C:\Users\Public\micw-<user>.wav/.txt, and reports the level and
# the share of 1000 Hz and 440 Hz (Goertzel against ±30 % bands). MMRESULT: 0 ok, 2 bad id, 4 allocated, 32 bad format.
param([int]$Seconds = 4)
Add-Type -TypeDefinition @'
using System; using System.IO; using System.Text; using System.Threading; using System.Runtime.InteropServices;
public static class MicW {
  [StructLayout(LayoutKind.Sequential)] public struct WFX { public ushort tag, ch; public uint rate, avg; public ushort align, bits, cb; }
  [StructLayout(LayoutKind.Sequential)] public struct HDR { public IntPtr data; public uint len, rec; public IntPtr user; public uint flags, loops; public IntPtr next, res; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct CAPS { public ushort mid, pid; public uint ver;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string name; public uint formats; public ushort ch, r1; }
  [DllImport("winmm.dll")] public static extern uint waveInGetNumDevs();
  [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern int waveInGetDevCapsW(UIntPtr id, ref CAPS c, uint size);
  [DllImport("winmm.dll")] static extern int waveInOpen(out IntPtr h, uint id, ref WFX f, IntPtr cb, IntPtr inst, uint flags);
  [DllImport("winmm.dll")] static extern int waveInPrepareHeader(IntPtr h, IntPtr hdr, uint size);
  [DllImport("winmm.dll")] static extern int waveInUnprepareHeader(IntPtr h, IntPtr hdr, uint size);
  [DllImport("winmm.dll")] static extern int waveInAddBuffer(IntPtr h, IntPtr hdr, uint size);
  [DllImport("winmm.dll")] static extern int waveInStart(IntPtr h);
  [DllImport("winmm.dll")] static extern int waveInReset(IntPtr h);
  [DllImport("winmm.dll")] static extern int waveInClose(IntPtr h);
  public static string Caps(uint id) { CAPS c = new CAPS(); int r = waveInGetDevCapsW(new UIntPtr(id), ref c, (uint)Marshal.SizeOf(c));
    return r == 0 ? String.Format("'{0}' ch {1} formats 0x{2:x}", c.name, c.ch, c.formats) : "caps error " + r; }
  static WFX Fmt(uint rate, ushort ch) { WFX f = new WFX(); f.tag = 1; f.ch = ch; f.rate = rate; f.bits = 16;
    f.align = (ushort)(ch * 2); f.avg = rate * f.align; return f; }
  public static int TryOpen(uint id, uint rate, ushort ch) { IntPtr h; WFX f = Fmt(rate, ch);
    int r = waveInOpen(out h, id, ref f, IntPtr.Zero, IntPtr.Zero, 0); if (r == 0) waveInClose(h); return r; }
  public static string Record(uint id, uint rate, ushort ch, int seconds, string wav) {
    IntPtr h; WFX f = Fmt(rate, ch); int r = waveInOpen(out h, id, ref f, IntPtr.Zero, IntPtr.Zero, 0);
    if (r != 0) return "record open " + r;
    int n = seconds * 10, blen = (int)(f.avg / 10), hsz = Marshal.SizeOf(typeof(HDR));
    IntPtr[] hs = new IntPtr[n];
    for (int i = 0; i < n; i++) { HDR x = new HDR(); x.data = Marshal.AllocHGlobal(blen); x.len = (uint)blen;
      hs[i] = Marshal.AllocHGlobal(hsz); Marshal.StructureToPtr(x, hs[i], false);
      waveInPrepareHeader(h, hs[i], (uint)hsz); waveInAddBuffer(h, hs[i], (uint)hsz); }
    int s = waveInStart(h); DateTime end = DateTime.Now.AddSeconds(seconds + 3);
    while (DateTime.Now < end && (((HDR)Marshal.PtrToStructure(hs[n - 1], typeof(HDR))).flags & 1) == 0) Thread.Sleep(50);
    waveInReset(h);
    MemoryStream pcm = new MemoryStream(); int done = 0;
    for (int i = 0; i < n; i++) { HDR x = (HDR)Marshal.PtrToStructure(hs[i], typeof(HDR));
      if ((x.flags & 1) != 0 && x.rec > 0) { byte[] b = new byte[x.rec]; Marshal.Copy(x.data, b, 0, (int)x.rec); pcm.Write(b, 0, b.Length); done++; }
      waveInUnprepareHeader(h, hs[i], (uint)hsz); Marshal.FreeHGlobal(x.data); Marshal.FreeHGlobal(hs[i]); }
    waveInClose(h);
    byte[] d = pcm.ToArray();
    using (BinaryWriter w = new BinaryWriter(File.Create(wav))) { w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + d.Length);
      w.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); w.Write(16); w.Write((short)1); w.Write((short)ch); w.Write((int)rate);
      w.Write((int)f.avg); w.Write((short)f.align); w.Write((short)16); w.Write(Encoding.ASCII.GetBytes("data")); w.Write(d.Length); w.Write(d); }
    int frames = d.Length / f.align; double[] m = new double[frames]; double peak = 0, sum = 0;
    for (int i = 0; i < frames; i++) { double v = 0; for (int c = 0; c < ch; c++) v += BitConverter.ToInt16(d, i * f.align + 2 * c) / 32768.0;
      v /= ch; m[i] = v; sum += v * v; peak = Math.Max(peak, Math.Abs(v)); }
    double rms = frames > 0 ? Math.Sqrt(sum / frames) : 0;
    return String.Format("record {0}x{1} start {2}: {3} of {4} buffers, {5} bytes, {6:F2} s, peak {7:F3}, rms {8:F4} ({9:F1} dBFS), 1000 Hz blocks {10:F2}, 440 Hz blocks {11:F2}",
      rate, ch, s, done, n, d.Length, frames / (double)rate, peak, rms, rms > 0 ? 20 * Math.Log10(rms) : -999, Share(m, 1000, rate), Share(m, 440, rate));
  }
  static double G(double[] s, int a, int len, double fq, uint rate) { double k = 2 * Math.Cos(2 * Math.PI * fq / rate), q1 = 0, q2 = 0;
    for (int i = a; i < a + len; i++) { double q0 = k * q1 - q2 + s[i]; q2 = q1; q1 = q0; } return q1 * q1 + q2 * q2 - k * q1 * q2; }
  // Share of non-silent 50 ms blocks dominated by fq.
  static double Share(double[] s, double fq, uint rate) { int b = (int)rate / 20, hit = 0, tot = 0;
    for (int a = 0; a + b <= s.Length; a += b) { tot++; double e = 0; for (int i = a; i < a + b; i++) e += s[i] * s[i];
      if (Math.Sqrt(e / b) < 0.003) continue; double p = G(s, a, b, fq, rate);
      if (p > 10 * Math.Max(G(s, a, b, fq * 0.7, rate), G(s, a, b, fq * 1.3, rate))) hit++; }
    return tot > 0 ? hit / (double)tot : 0; }
}
'@
$base = "C:\Users\Public\micw-$env:USERNAME"
$L = New-Object System.Collections.Generic.List[string]
$L.Add("time " + (Get-Date -Format s) + " user $env:USERNAME session $env:SESSIONNAME")
$n = [MicW]::waveInGetNumDevs(); $L.Add("waveInGetNumDevs $n")
for ($i = 0; $i -lt $n; $i++) { $L.Add("dev $i " + [MicW]::Caps([uint32]$i)) }
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone',
               'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone',
               'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged') {
    $v = (Get-ItemProperty $k -ErrorAction SilentlyContinue).Value; $L.Add("consent " + ($k -replace '^.*ConsentStore\\','') + " " + $(if ($v) { $v } else { "-" }) + " (" + $k.Substring(0,4) + ")")
}
$fmts = @(@(44100,1),@(48000,2),@(44100,2),@(16000,1),@(8000,1))
$pick = $null
foreach ($id in @([uint32]4294967295, [uint32]0)) {
    foreach ($f in $fmts) {
        $r = [MicW]::TryOpen($id, [uint32]$f[0], [uint16]$f[1])
        $L.Add("open " + $(if ($id -eq 4294967295) { "mapper" } else { "dev $id" }) + " " + $f[0] + "x" + $f[1] + " -> $r")
        if ($r -eq 0 -and -not $pick) { $pick = @($id, $f[0], $f[1]) }
    }
}
if ($pick) { $L.Add([MicW]::Record($pick[0], [uint32]$pick[1], [uint16]$pick[2], $Seconds, "$base.wav")) } else { $L.Add("record none: no format opened") }
$L | Set-Content "$base.txt"; $L
