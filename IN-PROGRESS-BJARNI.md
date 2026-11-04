# In Progress — Bjarni

## Branch: 2-spectrum-analyzer

### Real-time FFT spectrum analyzer for macOS full-screen player

Adds a live frequency-curve visualizer behind the full-screen player on macOS.

- **Signal chain**: tap on `mainMixerNode`, after ReplayGain EQ processing — the curve reflects the signal as heard
- **FFT pipeline**: 2048-point real FFT via `vDSP` with Hann window, log-spaced bin mapping (~21 Hz – 20 kHz), sub-bin linear interpolation for low-frequency bins that collapse to the same integer FFT bin
- **Multi-channel**: stereo or mono, two curves stacked with per-channel opacity
- **Animation**: `AnimatableMagnitudes: VectorArithmetic` (fixed 40-element, zero-padded) so SwiftUI can interpolate smoothly between FFT frames at any detail level
- **Rendering**: `.drawingGroup()` offloads to Metal; path built inline without intermediate array allocation
- **Settings** (Playback tab → Spectrum Analyser section):
  - Enable/disable toggle (stops the tap entirely when off)
  - Theme picker: White · Blue/Red
  - Detail: Low (10) · Medium (20) · High (40 bins)
  - Sensitivity slider (dB floor, −40 to −80)
  - Responsiveness slider (EWMA attack coefficient, 0.3 – 1.0)
  - Show stereo channels toggle
- **Conditional rendering**: curve fades in/out with `.opacity` transition; tap started/stopped on playback state and enable toggle

### Status

Ready for PR once branch 1-navigation is merged.

---

## Branch: 3-autoeq

### AutoEQ headphone correction (macOS only)

Applies per-headphone frequency correction using profiles from [autoeq.app](https://autoeq.app).

- **Signal chain**: `AutoEQService` attaches a 15-band `AVAudioUnitEQ` node after the ReplayGain node via `player.attach(node:)`
- **Profile format**: AutoEQ ParametricEQ.txt — `Preamp:` line + `Filter N:` lines; keyword-based parser handles PK/LS/HS/LP/HP/notch and the `BW Oct` bandwidth format
- **Parser robustness**: keyword scanning (`Fc`, `Gain`, `Q`) instead of fixed token positions; `BW Oct` falls back via `Q = sqrt(2^N) / (2^N - 1)`; `Q → bandwidth` via `2 × asinh(1/(2Q)) / ln(2)` clamped [0.05, 5.0]
- **Import**: file importer in settings; profile saved as JSON in `~/Documents/app.cassette/autoeq/`
- **Selection**: profile rows with checkmark; trash button to delete; auto-selects on import
- **Enable toggle**: bypasses all bands when disabled (profile preserved); profiles and import button hidden when off
- **Settings**: AutoEQ section in Playback tab above Crossfade, macOS only

### Status

Ready for PR once branch 2-spectrum-analyzer is merged.

---

## Branch: 1-navigation

### Back navigation for macOS detail views

Adds back navigation via two mechanisms:

- **Mouse back button** — Logi Options+ "Back" sends `NSEvent.EventType.swipe` with `deltaX > 0`. Monitored via `NSEvent.addLocalMonitorForEvents(matching: .swipe)` in `RootViewMacOS`.
- **2-finger trackpad swipe** — Detected via `.scrollWheel` events with `hasPreciseScrollingDeltas`. Triggers when accumulated horizontal delta > 60 pt and horizontal dominance > 2× vertical. Prevents conflicts with normal vertical scrolling.

Navigation is a no-op when the full player is visible or the navigation stack is empty. Uses `NotificationCenter` (`.cassetteNavigateBack`) as the bridge between AppKit event monitors and SwiftUI `NavigationStack`.

### Toolbar button normalization for macOS detail views

The detail views (album, artist, playlist) previously used `cassetteGlassButton` (custom circle glass) on each toolbar button, combined with `.sharedBackgroundVisibility(.hidden)` to suppress the system-provided shared pill. This was intentional — circles and pills would overlap.

Replaced that design with the system default: removed the custom glass circles and removed `.cassetteSharedBackgroundVisibility(.hidden)` from all `ToolbarItem`s. The system now draws the shared glass pill behind grouped toolbar items automatically, matching the list views (albums, artists).

### Status

Ready for PR once PR #136 / `fix/macos-button-hit-targets` is merged into main.
