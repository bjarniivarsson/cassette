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

## Branch: 4-conditional-autoeq-plus-audio-path

### Device-conditional AutoEQ + Audio Path visualization (macOS only)

Two related features built on shared output-device monitoring infrastructure.

#### Device-conditional AutoEQ

AutoEQ can now be scoped to a specific output device instead of always being active.

- **New toggle** in AutoEQ settings: "Only for this device" — when enabled, a device picker appears listing all current system output devices
- **Device picker** shows all output devices (devices with at least one output stream); selecting one stores its Core Audio UID (stable across reboots) in `AutoEQSettings.targetDeviceUID`
- **Effective state**: `AutoEQSettings.isEffectivelyEnabled(currentDeviceUID:)` computes whether AutoEQ should be active given the current device
- **Player integration**: `PlayerService.autoEQSettingsDidChange(currentDeviceUID:)` accepts the current device UID and applies effective state; `AppContainer` wires `OutputDeviceState.onDeviceChange` to call this whenever the user switches devices

#### Audio Path visualization

Adds an "Audio Path" popover accessible from `AudioFormatBadge` in the macOS full-screen player. Shows the full signal chain as a vertical stack of stage cards.

- **Stages** (in order): Source → [Transcode?] → Stream/Downloaded → Conversion (PCM→Float32, with channel downmix annotation) → [ReplayGain?] → [AutoEQ?] → [Crossfade?] → [Output Conversion?] → Output
- **Conditional stages**: Transcode (OpenSubsonic `transcodedSuffix`), ReplayGain (when enabled and gain ≠ 0), AutoEQ (only when effectively active on current device), Crossfade (hidden when suppressed for gapless album pairs), Output Conversion (only when device format differs from internal Float32/stereo)
- **Output Conversion**: shows only the values that differ (e.g. just sample rate if only that changes); uses `function` icon for both conversion cards
- **Physical DAC format**: three-step resolution — integer PCM physical format → `kAudioStreamPropertyAvailablePhysicalFormats` for best integer depth at any rate → `kAudioDevicePropertyTransportType` to classify OS-managed devices (built-in/Bluetooth/AirPlay/Virtual) and show "32-bit Float (OS)" as honest fallback
- **ReplayGain stage**: shows raw gain, pre-amp (if non-zero), and total separately: "Gain · +3.0dB (Track) · +1.0dB (Pre-Amp) · Total · +4.0dB"
- **Stream stage**: format "Navidrome → Cassette" via `client.loadCapabilities()`
- **Source quality label**: "Hi-Res Lossless" (lossless codec + ≥24-bit + ≥96 kHz) or "Lossless" shown as subtitle
- **Channel labels**: `channelLabel(_:)` helper maps 1→Mono, 2→Stereo, 4→Quad, 5→5.0 Surround, 6→5.1, 7→6.1, 8→7.1
- **Crossfade flash fix**: derives both current and next track from the same `playerState` snapshot to avoid a momentary state mismatch when skipping tracks with "disable for gapless" enabled

#### Spectrum analyzer improvements

- **Visualizer types**: `LinesSpectrumAnalyzerView` (curved filled area) and `BarsSpectrumAnalyzerView` (bottom-anchored bars with rounded caps), each in their own file
- **Type setting**: "Type" picker (Lines / Bars) added above "Theme" in Spectrum Analyser settings; persisted to `cassette.spectrum.visualizerType`
- **FFT size**: 4096-point (from 2048); `hi` bin boundary is now dynamic — derived as `nyquistBins × (930/1024)` so it correctly covers ~20 kHz at any FFT size or sample rate
- **Pause decay**: a 30 fps `Timer` inside `SpectrumAnalyzerService` applies exponential decay (factor 0.88 per tick, ~1.1 s to near-zero) whenever no tap has published in the last 50 ms — bars/lines fall smoothly to zero on pause instead of freezing
- **Always visible**: visualizer shown whenever enabled, not gated on playback state; height 110 pt
- **Baseline clipping**: both views use `height + 1` as the reference height so zero-magnitude bins are pushed 1 pt below the frame and fully clipped

#### OutputDeviceState

New `@Observable @MainActor` class centralising Core Audio output device monitoring, shared between `AudioPathView` and `AutoEQSettingsSection`.

- Tracks: device name, UID, sample rate, bit depth, float/PCM flag, `isOSManaged` flag, channel count, available output devices list
- Registered as `AppContainer.outputDeviceState` (macOS only)
- Uses `AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyDefaultOutputDevice`

### Status

Ready for PR once branch 3-autoeq is merged.

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
