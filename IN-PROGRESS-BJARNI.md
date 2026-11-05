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
- **Conditional stages**: Transcode (OpenSubsonic `transcodedSuffix`), ReplayGain (when enabled), AutoEQ (only when effectively active on current device), Crossfade (hidden when suppressed for gapless album pairs), Output Conversion (only when device format differs from internal Float32/stereo)
- **Output Conversion**: shows only the values that differ (e.g. just sample rate if only that changes)
- **Physical DAC format**: reads `kAudioStreamPropertyPhysicalFormat` on the first output stream (not the virtual Float32 from `kAudioDevicePropertyStreamFormat`)
- **Server type**: `Stream` tile shows server type ("Navidrome") via `client.loadCapabilities()`, not cached `serverCapabilities` which may be nil
- **AutoEQ stage**: subtitle = profile name, detail = preamp dB + active filter count

#### OutputDeviceState

New `@Observable @MainActor` class centralising Core Audio output device monitoring, shared between `AudioPathView` and `AutoEQSettingsSection`.

- Tracks: device name, UID, sample rate, bit depth, float/PCM flag, channel count, available output devices list
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
