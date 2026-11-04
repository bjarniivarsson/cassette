# In Progress — Bjarni

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
