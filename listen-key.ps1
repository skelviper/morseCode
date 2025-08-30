param(
  [int]$DeviceId = -1,
  [int]$SampleRate = 8000,
  [int]$Bits = 16,
  [int]$Channels = 1,
  [int]$UpdatesPerSec = 25,
  [switch]$ListDevices,
  [int]$ThresholdPct = 10,
  [int]$HoldMs = 150,
  [switch]$KeyIndicator,
  [switch]$Scope,
  [int]$ScopeHeight = 16,
  [int]$PeakHalfLifeMs = 80,
  [double]$ScopeGain = 0.5,
  [ValidateSet('bars','wave')][string]$ScopeStyle = 'bars',
  [int]$EdgeThresholdPct = 12,   # high-pass pulse threshold for edge detect
  [int]$RefractoryMs = 40,       # minimum time between toggles
  [int]$Wpm = 20                 # Morse speed for timing (dot = 1200/Wpm ms)
)

# C# helper using WinMM waveIn APIs
$code = @"
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Threading;

public class WaveInCaptureV4 : IDisposable
{
    private const int CALLBACK_FUNCTION = 0x00030000;
    private const int WAVE_MAPPER = -1;
    private const int MMSYSERR_NOERROR = 0;
    private const int MM_WIM_DATA = 0x3C0;

    [DllImport("winmm.dll")] private static extern int waveInGetNumDevs();

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct WAVEINCAPS
    {
        public ushort wMid;
        public ushort wPid;
        public int vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
        public uint dwFormats;
        public ushort wChannels;
        public ushort wReserved1;
    }

    [DllImport("winmm.dll", CharSet = CharSet.Auto)]
    private static extern int waveInGetDevCaps(int uDeviceID, out WAVEINCAPS pwic, int cbwic);

    [DllImport("winmm.dll")]
    private static extern int waveInOpen(out IntPtr hWaveIn, int uDeviceID, ref WAVEFORMATEX lpFormat, WaveInProc dwCallback, IntPtr dwInstance, int dwFlags);
    [DllImport("winmm.dll")] private static extern int waveInPrepareHeader(IntPtr hWaveIn, IntPtr lpWaveInHdr, int uSize);
    [DllImport("winmm.dll")] private static extern int waveInUnprepareHeader(IntPtr hWaveIn, IntPtr lpWaveInHdr, int uSize);
    [DllImport("winmm.dll")] private static extern int waveInAddBuffer(IntPtr hwi, IntPtr pwh, int cbwh);
    [DllImport("winmm.dll")] private static extern int waveInStart(IntPtr hwi);
    [DllImport("winmm.dll")] private static extern int waveInStop(IntPtr hwi);
    [DllImport("winmm.dll")] private static extern int waveInClose(IntPtr hwi);

    [StructLayout(LayoutKind.Sequential)]
    private struct WAVEFORMATEX
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public int nSamplesPerSec;
        public int nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WAVEHDR
    {
        public IntPtr lpData;
        public int dwBufferLength;
        public int dwBytesRecorded;
        public IntPtr dwUser;
        public int dwFlags;
        public int dwLoops;
        public IntPtr lpNext;
        public IntPtr reserved;
    }

    private delegate void WaveInProc(IntPtr hwi, int uMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2);

    public class DataEventArgs : EventArgs
    {
        public readonly short[] Samples;
        public readonly int Count;
        public DataEventArgs(short[] samples, int count) { Samples = samples; Count = count; }
    }
    public event EventHandler<DataEventArgs> DataAvailable;

    private IntPtr _hWaveIn = IntPtr.Zero;
    private WaveInProc _callback;
    private int _bytesPerSample;
    private int _bufferBytes;
    private const int BufferCount = 4;
    private IntPtr[] _headers = new IntPtr[BufferCount];
    private IntPtr[] _buffers = new IntPtr[BufferCount];
    private ConcurrentQueue<ArraySegment<byte>> _queue = new ConcurrentQueue<ArraySegment<byte>>();
    private Thread _worker;
    private volatile bool _running;
    private double _lastPeakNorm;
    private double _lastRmsNorm;

    // Ring buffer for scope
    private short[] _ring;
    private int _ringWrite;
    private int _ringLen;
    private int _ringFilled;
    private object _sync = new object();

    // Edge detection (high-pass + debounce)
    private double _hpY;
    private int _xPrev;
    private double _hpAlpha;
    private double _edgeThresh; // normalized 0..1
    private int _refractoryMs;
    private DateTime _lastToggleUtc = DateTime.MinValue;
    private volatile bool _keyDown;

    public static int GetDeviceCount() { return waveInGetNumDevs(); }
    public static string GetDeviceName(int id)
    {
        WAVEINCAPS caps; int r = waveInGetDevCaps(id, out caps, Marshal.SizeOf(typeof(WAVEINCAPS)));
        if (r != MMSYSERR_NOERROR) return "Unknown"; return caps.szPname;
    }

    public WaveInCaptureV4(int deviceId, int sampleRate, int bitsPerSample, int channels, int updatesPerSec, int edgeThresholdPct, int refractoryMs)
    {
        if (bitsPerSample != 16) throw new ArgumentException("Only 16-bit PCM supported");
        if (channels != 1) throw new ArgumentException("Only mono supported");

        _bytesPerSample = (bitsPerSample / 8) * channels;
        int samplesPerUpdate = Math.Max(64, sampleRate / Math.Max(10, updatesPerSec));
        _bufferBytes = samplesPerUpdate * _bytesPerSample;

        var fmt = new WAVEFORMATEX
        {
            wFormatTag = 1,
            nChannels = (ushort)channels,
            nSamplesPerSec = sampleRate,
            wBitsPerSample = (ushort)bitsPerSample,
            nBlockAlign = (ushort)((bitsPerSample / 8) * channels),
            nAvgBytesPerSec = sampleRate * ((bitsPerSample / 8) * channels),
            cbSize = 0
        };

        _callback = new WaveInProc(Callback);
        int res = waveInOpen(out _hWaveIn, deviceId, ref fmt, _callback, IntPtr.Zero, CALLBACK_FUNCTION);
        if (res != MMSYSERR_NOERROR) throw new InvalidOperationException("waveInOpen failed: " + res);

        for (int i = 0; i < BufferCount; i++)
        {
            _buffers[i] = Marshal.AllocHGlobal(_bufferBytes);
            var hdr = new WAVEHDR { lpData = _buffers[i], dwBufferLength = _bufferBytes };
            _headers[i] = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WAVEHDR)));
            Marshal.StructureToPtr(hdr, _headers[i], false);
            waveInPrepareHeader(_hWaveIn, _headers[i], Marshal.SizeOf(typeof(WAVEHDR)));
            waveInAddBuffer(_hWaveIn, _headers[i], Marshal.SizeOf(typeof(WAVEHDR)));
        }

        // ring buffer ~2s
        _ringLen = Math.Max(sampleRate * 2, sampleRate / 2);
        _ring = new short[_ringLen];
        _ringWrite = 0; _ringFilled = 0;

        // High-pass config for edge detection (fc ~= 20 Hz)
        double fc = 20.0;
        double dt = 1.0 / sampleRate;
        double rc = 1.0 / (2.0 * Math.PI * fc);
        _hpAlpha = rc / (rc + dt);
        _edgeThresh = Math.Max(0.001, Math.Min(1.0, edgeThresholdPct / 100.0));
        _refractoryMs = Math.Max(10, refractoryMs);
        _hpY = 0.0; _xPrev = 0; _keyDown = false;

        _running = true;
        _worker = new Thread(Worker) { IsBackground = true };
        _worker.Start();
        waveInStart(_hWaveIn);
    }

    private void Callback(IntPtr hwi, int uMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2)
    {
        if (uMsg == MM_WIM_DATA)
        {
            var hdr = Marshal.PtrToStructure<WAVEHDR>(dwParam1);
            if (hdr.dwBytesRecorded > 0)
            {
                byte[] managed = new byte[hdr.dwBytesRecorded];
                Marshal.Copy(hdr.lpData, managed, 0, hdr.dwBytesRecorded);
                _queue.Enqueue(new ArraySegment<byte>(managed, 0, managed.Length));
            }
            waveInAddBuffer(_hWaveIn, dwParam1, Marshal.SizeOf(typeof(WAVEHDR)));
        }
    }

    private void Worker()
    {
        var tmp = new short[_bufferBytes / 2];
        while (_running)
        {
            ArraySegment<byte> seg;
            if (_queue.TryDequeue(out seg))
            {
                int count = seg.Count / 2;
                if (tmp.Length < count) tmp = new short[count];
                Buffer.BlockCopy(seg.Array, seg.Offset, tmp, 0, count * 2);
                var copy = new short[count];
                Buffer.BlockCopy(tmp, 0, copy, 0, count * 2);

                long peak = 0; double sumSq = 0.0;
                for (int i = 0; i < count; i++)
                {
                    int v = copy[i]; int a = v < 0 ? -v : v;
                    if (a > peak) peak = a;
                    sumSq += (double)v * (double)v;

                    // High-pass filter sample
                    double hp = _hpAlpha * (_hpY + (v - _xPrev));
                    _xPrev = v;
                    _hpY = hp;
                    double hpn = hp / 32768.0;
                    if (hpn > _edgeThresh || hpn < -_edgeThresh)
                    {
                        // Debounce
                        var now = DateTime.UtcNow;
                        if ((now - _lastToggleUtc).TotalMilliseconds >= _refractoryMs)
                        {
                            _keyDown = !_keyDown; // toggle on each strong edge
                            _lastToggleUtc = now;
                        }
                    }
                }
                double rms = Math.Sqrt(sumSq / Math.Max(1, count));
                _lastPeakNorm = Math.Min(1.0, peak / 32767.0);
                _lastRmsNorm = Math.Min(1.0, rms / 32767.0);

                lock (_sync)
                {
                    int w = _ringWrite; int len = _ringLen; int n = count;
                    int first = Math.Min(n, len - w);
                    Buffer.BlockCopy(copy, 0, _ring, w * 2, first * 2);
                    int remain = n - first;
                    if (remain > 0)
                    {
                        Buffer.BlockCopy(copy, first * 2, _ring, 0, remain * 2);
                        w = remain;
                    }
                    else { w += first; if (w == len) w = 0; }
                    _ringWrite = w;
                    _ringFilled = Math.Min(len, _ringFilled + n);
                }

                var handler = DataAvailable; if (handler != null) handler(this, new DataEventArgs(copy, count));
            }
            else { Thread.Sleep(1); }
        }
    }

    public void GetLevels(out double peakNorm, out double rmsNorm)
    { peakNorm = _lastPeakNorm; rmsNorm = _lastRmsNorm; }

    public void GetKey(out bool down)
    { down = _keyDown; }

    public int CopyRecent(short[] dst)
    {
        if (dst == null || dst.Length == 0) return 0;
        lock (_sync)
        {
            int available = _ringFilled; if (available == 0) return 0;
            int n = Math.Min(dst.Length, available);
            int end = _ringWrite; int start = end - n; if (start < 0) start += _ringLen;
            int first = Math.Min(n, _ringLen - start);
            Buffer.BlockCopy(_ring, start * 2, dst, 0, first * 2);
            int remain = n - first; if (remain > 0) Buffer.BlockCopy(_ring, 0, dst, first * 2, remain * 2);
            return n;
        }
    }

    public void Dispose()
    {
        _running = false; try { if (_worker != null) _worker.Join(200); } catch { }
        try { if (_hWaveIn != IntPtr.Zero) waveInStop(_hWaveIn); } catch { }
        for (int i = 0; i < BufferCount; i++)
        {
            if (_headers[i] != IntPtr.Zero) { try { waveInUnprepareHeader(_hWaveIn, _headers[i], Marshal.SizeOf(typeof(WAVEHDR))); } catch { } Marshal.FreeHGlobal(_headers[i]); _headers[i] = IntPtr.Zero; }
            if (_buffers[i] != IntPtr.Zero) { Marshal.FreeHGlobal(_buffers[i]); _buffers[i] = IntPtr.Zero; }
        }
        if (_hWaveIn != IntPtr.Zero) { try { waveInClose(_hWaveIn); } catch { } _hWaveIn = IntPtr.Zero; }
    }
}
"@

try {
  Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
} catch {
  if ($_.FullyQualifiedErrorId -ne 'TYPE_ALREADY_EXISTS,Microsoft.PowerShell.Commands.AddTypeCommand') { throw }
}

function Get-AudioInputDevices {
  $count = [WaveInCaptureV4]::GetDeviceCount()
  0..($count-1) | ForEach-Object {
    [pscustomobject]@{ Id = $_; Name = [WaveInCaptureV4]::GetDeviceName($_) }
  }
}

if ($ListDevices) {
  Write-Host "Available input devices:" -ForegroundColor Cyan
  Get-AudioInputDevices | Format-Table -AutoSize
  return
}

function Start-LevelMeter {
  param(
    [int]$DeviceId = -1,
    [int]$SampleRate = 8000,
    [int]$Bits = 16,
    [int]$Channels = 1,
    [int]$UpdatesPerSec = 25,
    [int]$ThresholdPct = 10,
    [int]$HoldMs = 150,
    [bool]$KeyIndicator = $false,
    [bool]$Scope = $false,
    [int]$ScopeHeight = 16,
    [int]$PeakHalfLifeMs = 80,
    [double]$ScopeGain = 0.5,
    [ValidateSet('bars','wave')][string]$ScopeStyle = 'bars'
    ,[int]$Wpm = 20
  )

  $capture = New-Object WaveInCaptureV4($DeviceId, $SampleRate, $Bits, $Channels, $UpdatesPerSec, $EdgeThresholdPct, $RefractoryMs)
  $stopRequested = $false
  $origCursorVisible = $Host.UI.RawUI.CursorSize
  $Host.UI.RawUI.CursorSize = 0
  [Console]::TreatControlCAsInput = $true

  try {
    $bufWidth = [Console]::BufferWidth
    $bufHeight = [Console]::BufferHeight
    $winWidth = [Console]::WindowWidth
    $winHeight = [Console]::WindowHeight
    $barMax = [Math]::Max(10, $winWidth - 20)
    $threshold = [Math]::Max(0.0, [Math]::Min(1.0, $ThresholdPct / 100.0))
    $lastHigh = Get-Date 0
    $intervalMs = [int](1000 / [Math]::Max(5, $UpdatesPerSec))
    $display = 0.0
    $releaseFactor = [Math]::Pow(0.5, $intervalMs / [Math]::Max(10.0, [double]$PeakHalfLifeMs))
    $scopeDisp = 0.0

    # Reserve scope area
    $scopeTop = [Console]::CursorTop
    if ($Scope) {
      $h = [Math]::Max(6, [Math]::Min(40, $ScopeHeight))
      $rowsNeeded = $h + 4  # +decode line
      for ($i=0; $i -lt $rowsNeeded; $i++) { Write-Host "" }
    }

    # Track last-known console size to handle live resize
    $lastBW = $bufWidth; $lastBH = $bufHeight; $lastWW = $winWidth; $lastWH = $winHeight

    # Morse decoding setup
    $dotMs = 1200.0 / [double]$Wpm
    $dashSplitMs = 2.0 * $dotMs  # >2 dots => dash
    $letterGapMs = 3.0 * $dotMs
    $wordGapMs = 7.0 * $dotMs
    $Morse = @{
      '.-'='A'; '-...'='B'; '-.-.'='C'; '-..'='D'; '.'='E'; '..-.'='F'; '--.'='G'; '....'='H'; '..'='I'; '.---'='J'; '-.-'='K'; '.-..'='L'; '--'='M'; '-.'='N'; '---'='O'; '.--.'='P'; '--.-'='Q'; '.-.'='R'; '...'='S'; '-'='T'; '..-'='U'; '...-'='V'; '.--'='W'; '-..-'='X'; '-.--'='Y'; '--..'='Z';
      '-----'='0'; '.----'='1'; '..---'='2'; '...--'='3'; '....-'='4'; '.....'='5'; '-....'='6'; '--...'='7'; '---..'='8'; '----.'='9';
      '.-.-.-'= '.'; '--..--'= ','; '..--..'='?'; '.----.'="'"; '-.-.--'='!'; '-..-.'='/'; '-.--.'='(' ; '-.--.-'= ')'; '.-...'='&'; '---...'= ':'; '-.-.-.'=';'; '-...-'='='; '.-.-.'='+'; '-....-'='-'; '..--.-'='_'; '.-..-.'='"'; '.--.-.'='@'
    }
    $m_prevDown = $false
    $m_lastChange = Get-Date
    $m_buf = ''
    $m_text = ''
    $m_lastWasSpace = $false

    # Grid buffer for scrolling history scope
    $grid = $null
    function Initialize-Grid([int]$w, [int]$h) {
      $g = @()
      for ($row=0; $row -lt $h; $row++) {
        $line = New-Object 'System.Char[]' ($w)
        for ($i=0; $i -lt $w; $i++) { $line[$i] = ' ' }
        $g += ,$line
      }
      return ,$g
    }

    while (-not $stopRequested) {
      $peak = 0.0; $rms = 0.0
      $capture.GetLevels([ref]$peak, [ref]$rms)

      $instant = [Math]::Min(1.0, $peak)
      $display = [Math]::Max($instant, $display * $releaseFactor)
      $level = $display
      $bars = [int]([Math]::Round($level * $barMax))
      $barStr = ("#" * $bars).PadRight($barMax, " ")
      $pct = [int]([Math]::Round($level * 100))
      $text = "Level: ".PadRight(8) + "|" + $barStr + "| " + $pct.ToString().PadLeft(3) + "%"

      if ($KeyIndicator) {
        $down = $false; $capture.GetKey([ref]$down)
        $keyTxt = if ($down) { 'DOWN' } else { 'UP  ' }
        $text += "  KEY: " + $keyTxt + "  (" + ([int]([Math]::Round($rms*100))).ToString().PadLeft(3) + "% rms)"
      }

      $text += "  (Ctrl+C to exit)"

      # Handle resize: if dimensions changed, clear and reserve again
      $curBW = [Console]::BufferWidth; $curBH = [Console]::BufferHeight
      $curWW = [Console]::WindowWidth; $curWH = [Console]::WindowHeight
      if ($curBW -ne $lastBW -or $curWW -ne $lastWW -or $curWH -ne $lastWH) {
        [Console]::Clear()
        $scopeTop = 0
        if ($Scope) {
          $h = [Math]::Max(6, [Math]::Min(40, $ScopeHeight))
          $rowsNeeded = $h + 4
          for ($i=0; $i -lt $rowsNeeded; $i++) { Write-Host "" }
        }
        $barMax = [Math]::Max(10, $curWW - 20)
        $lastBW = $curBW; $lastBH = $curBH; $lastWW = $curWW; $lastWH = $curWH
        $grid = $null
      }

      if ($Scope) {
        $h = [Math]::Max(6, [Math]::Min(40, $ScopeHeight))
        $w = [Math]::Max(20, [Console]::BufferWidth - 4) # keep margin to avoid wrap
        if ($null -eq $grid -or $grid.Length -ne $h -or $grid[0].Length -ne $w) {
          $grid = Initialize-Grid -w $w -h $h
        }
        # Scroll grid left by 1 and insert new column on the right
        for ($row=0; $row -lt $h; $row++) {
          for ($i=0; $i -lt ($w-1); $i++) { $grid[$row][$i] = $grid[$row][$i+1] }
          $grid[$row][$w-1] = ' '
        }
        $mid = [int][Math]::Round(($h-1)/2)
        if ($ScopeStyle -eq 'bars') {
          # Use RMS amplitude for a column bar, with gain and smoothing
          $scopeInst = [Math]::Min(1.0, [Math]::Max(0.0, $rms * $ScopeGain))
          $scopeDisp = [Math]::Max($scopeInst, $scopeDisp * $releaseFactor)
          $half = [int][Math]::Round($scopeDisp * ($h - 1) / 2.0)
          if ($half -lt 0) { $half = 0 } elseif ($half -ge $h) { $half = $h - 1 }
          for ($yy = $mid - $half; $yy -le $mid + $half; $yy++) { if ($yy -ge 0 -and $yy -lt $h) { $grid[$yy][$w-1] = '*' } }
        } else {
          # Wave style: plot mirrored point from most recent sample, DC-removed
          $points = New-Object 'System.Int16[]' ($w)
          $n = $capture.CopyRecent($points)
          $reduced = @()
          if ($n -gt 0) {
            $reduced = New-Object 'System.Double[]' ($n)
            for ($i=0; $i -lt $n; $i++) { $reduced[$i] = $points[$i] / 32768.0 }
            $avg = 0.0; for ($i=0; $i -lt $reduced.Length; $i++) { $avg += $reduced[$i] }; $avg = $avg / [double]$reduced.Length
            for ($i=0; $i -lt $reduced.Length; $i++) { $reduced[$i] = [Math]::Max(-1.0, [Math]::Min(1.0, $reduced[$i]-$avg)) }
            $vNow = $reduced[$reduced.Length-1]
            $y = [int]((1.0 - (($vNow + 1.0) * 0.5)) * ($h - 1))
            if ($y -lt 0) { $y = 0 } elseif ($y -ge $h) { $y = $h - 1 }
            $grid[$y][$w-1] = '*'; $grid[($h-1)-$y][$w-1] = '*'
          }
        }

        # Render the scroller
        [Console]::SetCursorPosition(0, $scopeTop)
        $topBorder = "+" + ("-" * $w) + "+"
        Write-Host $topBorder
        for ($row=0; $row -lt $h; $row++) {
          $line = New-Object 'System.Char[]' ($w)
          # baseline on mid row
          if ($row -eq $mid) { for ($i=0; $i -lt $w; $i++) { $line[$i] = '-' } } else { for ($i=0; $i -lt $w; $i++) { $line[$i] = ' ' } }
          for ($i=0; $i -lt $w; $i++) { if ($grid[$row][$i] -ne ' ') { $line[$i] = $grid[$row][$i] } }
          $lineStr = -join $line
          Write-Host ("|" + $lineStr + "|")
        }
        Write-Host ("+" + ("-" * $w) + "+")
        # Ensure the status line fits exactly one row to prevent wrap
        $maxLine = [Math]::Max(1, [Console]::BufferWidth - 1)
        if ($text.Length -gt $maxLine) { $text = $text.Substring(0, $maxLine) }
        else { $text = $text.PadRight($maxLine, ' ') }
        Write-Host $text
        # Morse decoded line
        $downNow = $false; $capture.GetKey([ref]$downNow)
        $now = Get-Date
        if ($downNow -ne $m_prevDown) {
          $dt = ($now - $m_lastChange).TotalMilliseconds
          if ($m_prevDown) {
            if ($dt -ge $dashSplitMs) { $m_buf += '-' } else { $m_buf += '.' }
          }
          $m_lastChange = $now
          $m_prevDown = $downNow
        } else {
          if (-not $downNow) {
            $gap = ($now - $m_lastChange).TotalMilliseconds
            if ($m_buf.Length -gt 0 -and $gap -ge $letterGapMs) {
              $ch = $Morse[$m_buf]
              if (-not $ch) { $ch = '?' }
              $m_text += $ch
              $m_buf = ''
              $m_lastWasSpace = $false
            }
            if ($gap -ge $wordGapMs -and -not $m_lastWasSpace -and $m_text.Length -gt 0) { $m_text += ' '; $m_lastWasSpace = $true }
          }
        }
        $mline = ('Morse: ' + $m_text + ' [' + $m_buf + ']')
        if ($mline.Length -gt $maxLine) { $mline = $mline.Substring($mline.Length - $maxLine) }
        else { $mline = $mline.PadRight($maxLine, ' ') }
        Write-Host $mline
      } else {
        [Console]::SetCursorPosition(0, [Console]::CursorTop)
        Write-Host $text -NoNewline
      }

      Start-Sleep -Milliseconds $intervalMs
      if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'C' -and $key.Modifiers -band [ConsoleModifiers]::Control) { $stopRequested = $true }
      }
    }
  }
  finally {
    $capture.Dispose()
    [Console]::TreatControlCAsInput = $false
    $Host.UI.RawUI.CursorSize = $origCursorVisible
    Write-Host "`nStopped."
  }
}

$devDesc = if ($DeviceId -ge 0) { [WaveInCaptureV4]::GetDeviceName($DeviceId) } else { 'Default (WAVE_MAPPER)' }
Write-Host ("Listening on microphone: " + $devDesc + " (DeviceId=" + $DeviceId + "). Press Ctrl+C to stop.") -ForegroundColor Cyan
Start-LevelMeter -DeviceId $DeviceId -SampleRate $SampleRate -Bits $Bits -Channels $Channels -UpdatesPerSec $UpdatesPerSec -ThresholdPct $ThresholdPct -HoldMs $HoldMs -KeyIndicator:$KeyIndicator -Scope:$Scope -ScopeHeight $ScopeHeight -PeakHalfLifeMs $PeakHalfLifeMs -Wpm $Wpm
