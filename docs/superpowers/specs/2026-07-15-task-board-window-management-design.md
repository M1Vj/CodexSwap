# Task Board Window Management Design

## Goal

Let the CodexSwap Task Board occupy its own macOS full-screen Space or move safely between physical displays without interrupting, duplicating, or mutating task execution.

## User experience

- The Task Board supports the standard macOS full-screen transition, including the green window control and a visible `Window` menu action in the board header.
- A `Move to Next Display` action moves the existing board window to the next connected display while preserving its relative position and fitting it inside that display's visible frame.
- A `Center on Current Display` action recovers a poorly positioned window without changing its size unless the display is smaller.
- The board remembers its last non-full-screen position and size between openings and app launches, but expands an unusably small stored frame to the screen-aware minimum.
- Reopening CodexSwap from Finder, Spotlight, Dock, or `open` while no window is visible opens the Task Board; reopening while another CodexSwap window is visible does not replace it.
- If a display is disconnected, the restored board is constrained to an available display.
- Moving a full-screen board first exits full screen, then performs the display move after AppKit completes the transition.
- Manual drags, resizes, screen changes, and Space returns are normalized after interaction ends, so a collapsed frame expands automatically without fighting the pointer.
- The SwiftUI content has no fixed root minimum; the native window owns a screen-aware minimum that can shrink to fit unusually small displays.

## Architecture

Task state remains owned by the existing `TaskBoardViewModel`; window management is isolated in `TaskBoardWindowController`. The controller passes a small set of window-only closures to `TaskBoardView`, which renders a native SwiftUI `Menu` alongside existing header actions.

Pure geometry calculations live in `SwapKit` so display movement and frame fitting can be proven deterministically without constructing AppKit windows. A debounced app-layer frame monitor converts between `NSRect` and the pure frame type, defers recovery while the pointer or full-screen transition is active, and performs native `NSWindow` operations on the main actor.

## Safety invariants

1. Full-screen, centering, moving, closing, or reopening the board never calls task actions or changes queue state.
2. Only one `TaskBoardWindowController` and one board view model remain active.
3. Every programmatically assigned frame has positive dimensions and fits the target display's visible frame.
4. A display move requested during full screen runs only after `windowDidExitFullScreen`.
5. When there is only one display, `Move to Next Display` is harmless and leaves the current frame unchanged.
6. Frame recovery never runs during a native full-screen transition or active pointer interaction.

## Verification

- Unit tests cover relative-position preservation, tiny-frame expansion during moves and restoration, post-interaction normalization policy, very-small-display sizing, clamping, centering, and single-display behavior.
- Existing task-board tests prove task behavior remains unchanged.
- The full Swift test suite, repository release-tool checks, and release build must pass.
- The rebuilt `/Applications/CodexSwap.app` must be launched and checked for full-screen capability, frame persistence, clean runtime logs, and an unchanged scheduler state.

## Non-goals

- CodexSwap will not use private macOS APIs to assign a window to an arbitrary Desktop/Space. Native full screen creates a dedicated Space; users may also move the window through Mission Control.
- The feature will not create a second board instance or duplicate task state.
