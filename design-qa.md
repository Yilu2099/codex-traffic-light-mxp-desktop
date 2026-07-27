# Design QA

## Source truth

- Selected visual direction: `Docs/design/vertical-traffic-light-reference.png`
- Native implementation: `Sources/CodexTrafficLightApp/TrafficLightView.swift`
- Default viewport: 80 × 260 pt (50% of the 160 × 520 ultra-compact design canvas)
- Verified state: real `working` state with weekly quota row; the window was exposed through its menu toggle without writing a fake task state

## Visual comparison history

1. The first native pass was wider than the selected reference. The logical canvas was narrowed to 230 × 520 and the signal housing, text block, divider, and quota row were realigned.
2. The full-size widget was visually faithful but obscured too much desktop content. Rendering was changed to scale the same native design into a 115 × 260 default window.
3. The active lens now animates only its glow, fill, and rim opacity with a slow sine curve. Two captured frames produced different image hashes, confirming the breathing animation without changing layout.
4. A persistent, aspect-locked resize path was added to the bottom-right handle. The supported width range is 68–200 pt, and the last width is restored on launch.
5. User review requested less lateral whitespace. The logical canvas was reduced from 230 to 190 pt while retaining the 96 pt signal housing and the original lens sizes.
6. The quota row was simplified from `周额度 65%` to centered `周：65%`; its font increased from 18 to 23 pt, while remaining below the 34 pt state label. The progress track increased from 6 to 10 pt.
7. Default and enlarged captures were compared together with the selected reference. At 95 × 260 and 140 × 384, housing, type, divider, quota text, progress bar, corner radius, and resize affordance scale proportionally without reflow or clipping.
8. The quota label was raised by 6 logical points, leaving an 8-point gap above the progress track while preserving clear separation from the state label.
9. A second whitespace review reduced the logical canvas from 190 to 160 pt and widened the signal housing from 96 to 108 pt. The housing now sits 18 pt from each body edge while the animated glow retains safe clearance.
10. A previous red-light screenshot check wrote a `quota-spacing-qa = waiting` task into the production state file. That task was cleared, and subsequent visual QA uses only the app's display toggle so test state cannot be mistaken for a real Codex request.

## Inspection

- No clipped status or quota text at the default or enlarged verified sizes.
- Reduced body-to-signal side clearance remains balanced and does not crowd the active glow.
- The three lenses remain centered and equally spaced.
- The active light remains visually dominant; inactive lights retain enough color to be identifiable.
- The resize handle is visible but subordinate to status information.
- Movement and resizing use screen-space deltas to avoid window jumps while dragging.
- Red alert blinking remains separate from the subtle continuous breathing effect.

## Verification

- Release build: passed
- Core/status/quota/collector test executable: 48/48 passed
- Local LaunchAgent installation: passed
- Installed default window bounds: 80 × 260 pt
- Supported width range: 68–200 pt, with fixed 160:520 aspect ratio
- Live-state verification: `working`; no QA or manual `waiting` task present
- Breathing frame comparison: passed

final result: passed
