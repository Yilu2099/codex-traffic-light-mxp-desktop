**Comparison Target**

- Source visual truth: the installed v1.2.45 card layout plus the user instruction to remove numeric rank labels.
- Implementation screenshot: `/Users/lu/Desktop/开发/创新局/状态栏极简榜单-client-v1.2.41-20260822/artifacts/status-popover-no-rank-v1.2.47.png`
- Combined comparison evidence: `/Users/lu/Desktop/开发/创新局/状态栏极简榜单-client-v1.2.41-20260822/artifacts/status-popover-no-rank-v1.2.47-comparison.png`
- Viewport: native SwiftUI popover at 456 x 640 points, Aqua light appearance, 2x capture.
- Pixels and normalization: both before and after captures are 912 x 1280 at the same native 456 x 640-point viewport and 2x density.
- State: ranking loaded while local data is syncing; four joined members visible with quota and work-time data.

**Findings**

- No actionable P0, P1, or P2 mismatch remains.
- Fonts and typography: native macOS system typography preserves the target hierarchy; quota, member names, metadata, and Token values remain legible without wrapping.
- Spacing and layout rhythm: the compact header, horizontal quota card, section title, four complete member rows, and persistent footer fit the fixed popover. The production header is intentionally slightly shorter than the concept to honor the user's request to reduce top space.
- Colors and visual tokens: warm-white canvas, charcoal text, green quota accents, pale amber start time, and pale blue end time remain unchanged.
- Image quality and asset fidelity: the real bundled Wanhe logo and production member avatars are used at native resolution and circular crop. Production avatars remain authoritative where the generated concept differs.
- Copy and content: production wording and runtime quota/reset values retain their live semantics rather than hard-coded concept values.
- Affordances: member rows still open member detail; the filled green footer still opens the team leaderboard; guide/version content remains available farther down the scroll view.

**Comparison History**

- Earlier release v1.2.45 showed numeric rank labels before every avatar.
- Fix: removed the numeric label and its reserved width, then shifted each avatar and member detail block left without changing row actions or data.
- Post-fix evidence: the side-by-side comparison shows cleaner member rows, more usable content width, and no vertical or footer regression.

**Focused Region Comparison**

- Header/quota: sync capsule and horizontal three-part quota card match the selected hierarchy.
- Member rows/footer: avatars now anchor the rows directly; identity/status, quota, Token total, two-tone work band, grouped border, and filled green action remain aligned.

**Implementation Checklist**

- [x] Preserve current online-state and primary-quota safety behavior.
- [x] Restore rounded quota and ranking containers.
- [x] Restore split amber/blue work-time bands.
- [x] Show four complete members on first screen.
- [x] Restore the filled green leaderboard action.
- [x] Remove numeric rank labels without changing sorting or click behavior.

**Follow-up Polish**

- None required for this release.

final result: passed
