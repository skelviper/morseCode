Morse Key Reader (PowerShell)
================================

A Windows PowerShell script that reads a telegraph key (or microphone input) via the PC audio input, renders a live console scope, and decodes Morse code in real time.

Features
- Live level meter with fast decay and adjustable sensitivity
- Scrolling ASCII waveform/spectrum-style scope (btop-like)
- Edge-based key detection (robust on AC‑coupled mic inputs)
- Real‑time Morse decoding with WPM timing and gap detection
- Device listing and selection via WinMM (no external dependencies)

Quick Start
- Allow scripts for this session:
  `Set-ExecutionPolicy -Scope Process Bypass -Force`
- List input devices:
  `./listen-key.ps1 -ListDevices`
- Run with default device + scope + decoder:
  `./listen-key.ps1 -Scope -KeyIndicator`
- Pick a specific device (e.g., 0):
  `./listen-key.ps1 -DeviceId 0 -Scope -KeyIndicator`

Common Options
- `-Scope`: Enable scrolling history scope
- `-ScopeHeight <int>`: Scope height (default 16)
- `-ScopeGain <0..1>`: Scope amplitude scaling (default 0.5)
- `-ScopeStyle bars|wave`: Bars (default) or point waveform
- `-PeakHalfLifeMs <int>`: Visual level release half-life (default 80ms)
- `-KeyIndicator`: Show debounced key state (UP/DOWN)
- `-Wpm <int>`: Morse speed (default 20; dot = 1200/Wpm ms)
- Edge detector tuning:
  - `-EdgeThresholdPct <int>`: Pulse threshold (default 12)
  - `-RefractoryMs <int>`: Minimum time between toggles (default 40)

Notes on Hardware and Signal Path
- PC mic inputs are AC‑coupled; a telegraph key (DC switch) creates pulses on press/release. The script’s edge detector converts these pulses into a stable key state with debounce.
- If sensitivity feels high/low, adjust `-EdgeThresholdPct` and `-RefractoryMs`. For the scope’s visual size only, adjust `-ScopeGain` and/or `-ScopeHeight`.
- Ensure PowerShell has microphone access in Windows Privacy settings.

Troubleshooting
- No meter movement: verify the correct device via `-ListDevices`, raise mic level/boost in Sound settings, test by tapping the mic/plug tip.
- Scope duplicates or wraps: the script adapts to resize and trims lines to buffer width; try in Windows Terminal or classic console.

Development
- Embedded C# (WinMM waveIn) compiled from PowerShell via `Add-Type`.
- Class name increments (WaveInCaptureV4) to avoid type caching between runs.

License
- MIT (optional; add LICENSE if needed).

