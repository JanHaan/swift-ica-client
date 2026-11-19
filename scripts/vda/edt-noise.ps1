# Moving test content for the lab VDA (bulkprobe D135, chromaprobe D155, backlog 2.2). Recreates mac-D's
# C:\Users\Public\edt-noise.ps1 (lost with the golden @v3 rebuild) with the same interface, plus a deterministic mode.
# Installed by scripts/vda/install.sh. In a session: powershell -nop -ep bypass -file C:\Users\Public\edt-noise.ps1
#   [-Seconds 30] [-Pattern noise|scroll]
# A window titled "edt-noise" with a 1024×640 client area, redrawn every 50 ms, closed after -Seconds.
#   noise:  fresh random RGB per pixel every frame (incompressible; bulk throughput).
#   scroll: a fixed texture moved 4 px left per frame, pixel (cx, cy) of frame t = T((cx + 4t) mod 1024, cy):
#           rows 0-319 per-pixel hash colours, rows 320-639 1-px saturated colour stripes (ChromaMetric.scrollTexture
#           in ICAKit computes the same T, so a decoded frame can be matched and compared pixel by pixel).
param([int]$Seconds = 30, [string]$Pattern = "noise")
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Windows.Forms; using System.Runtime.InteropServices;
public class EdtNoise : Form {
  const int W = 1024, H = 640;
  Bitmap bmp = new Bitmap(W, H, PixelFormat.Format24bppRgb);
  byte[] frame = new byte[W * 3 * H]; byte[] tex = new byte[W * 3 * H];
  Random rng = new Random(); bool scroll; int t; Timer timer = new Timer(); DateTime end;
  static readonly byte[,] Stripes = { {255,0,0}, {0,0,255}, {0,255,0}, {255,255,0}, {255,0,255}, {0,255,255} };
  public static uint Hash(uint x, uint y) { unchecked {
    uint h = x * 0x9E3779B1u + y * 0x85EBCA77u; h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12; h *= 0x297A2D39u; h ^= h >> 15; return h; } }
  public EdtNoise(int seconds, bool scroll) {
    this.scroll = scroll; Text = "edt-noise"; ClientSize = new Size(W, H); DoubleBuffered = true;
    FormBorderStyle = FormBorderStyle.FixedSingle; StartPosition = FormStartPosition.CenterScreen;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
      int i = (y * W + x) * 3; byte r, g, b;
      if (y < 320) { uint h = Hash((uint)x, (uint)y); r = (byte)h; g = (byte)(h >> 8); b = (byte)(h >> 16); }
      else { int k = (x + y / 2) % 6; r = Stripes[k, 0]; g = Stripes[k, 1]; b = Stripes[k, 2]; }
      tex[i] = b; tex[i + 1] = g; tex[i + 2] = r;   // 24bpp DIB order: B, G, R
    }
    end = DateTime.Now.AddSeconds(seconds);
    timer.Interval = 50; timer.Tick += (s, e) => { if (DateTime.Now > end) { Close(); return; } Step(); Invalidate(); }; timer.Start();
    Step();
  }
  void Step() {
    if (scroll) {
      int s = (4 * t) % W;
      for (int y = 0; y < H; y++) {
        int row = y * W * 3;
        Buffer.BlockCopy(tex, row + s * 3, frame, row, (W - s) * 3);
        Buffer.BlockCopy(tex, row, frame, row + (W - s) * 3, s * 3);
      }
    } else rng.NextBytes(frame);
    t++;
    BitmapData d = bmp.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
    for (int y = 0; y < H; y++) Marshal.Copy(frame, y * W * 3, IntPtr.Add(d.Scan0, y * d.Stride), W * 3);
    bmp.UnlockBits(d);
  }
  protected override void OnPaint(PaintEventArgs e) { e.Graphics.DrawImageUnscaled(bmp, 0, 0); }
}
'@
[System.Windows.Forms.Application]::Run((New-Object EdtNoise($Seconds, ($Pattern -eq "scroll"))))
