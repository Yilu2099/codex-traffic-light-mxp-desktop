**Source visual truth**

- `/Users/lu/.codex/attachments/e0bef83e-0692-405f-8780-936b83c49b75/codex-clipboard-7284f3e8-eda1-4446-9ee1-0276d5b81b02.png`
- Source pixels: 874 × 776. The source is a cropped @2x-style capture of the 456-point Mac status popover member list.

**Rendered implementation**

- `/Users/lu/.codex/generated_images/01a02540-13a2-7633-880b-b0a0e3e9904e/statusbar-compact-countdown-preview.png`
- Implementation pixels: 912 × 1280 at a 456 × 640 point popover viewport and 2× density.
- State: light appearance, quota card plus member list with active, pending, zero-token, and large-token examples.
- Normalization: the implementation was scaled to the source width in `/tmp/weekly-balance-countdown-comparison.jpg`; the member-row regions were compared visually. The source is cropped and contains different live members, so copy differences other than the requested countdown rule are not fidelity findings.

**Full-view comparison evidence**

- The existing warm palette, card radius, avatar scale, ranking column, member information hierarchy, Token column, dividers, and green semantic color remain unchanged.
- The quota card and list preserve the original vertical rhythm; shortening the countdown does not introduce empty-looking rows or disturb alignment.

**Focused region comparison evidence**

- Source rows 3 and 4 wrap `6天15小时后刷新` / `6天17小时后刷新` onto a second line.
- Revised active row renders `周余额 78% · 5天后刷新` on one line.
- Revised pending rows render `周余额待同步 · 刷新待更新` on one line at the same 456-point popover width.
- The right Token column remains aligned and does not collide with the quota text.

**Findings**

- No remaining P0, P1, or P2 visual issues in the requested countdown and member-row scope.
- Typography: the quota row keeps the existing system font, semantic weight, color, and hierarchy; single-line tightening is bounded to 82% only when needed.
- Spacing: row height and column spacing remain consistent; removing the forced second line restores even row rhythm.
- Colors: existing green, muted gray, warm background, and divider tokens are unchanged.
- Images: existing bundled avatars and brand assets are unchanged and remain sharp at 2× capture density.
- Copy: at or above one day the countdown now shows whole days only; below one day it shows rounded-up hours only.

**Comparison history**

- Initial P1: long day-and-hour countdown wrapped in the source rows, increasing row density inconsistently.
- Fix: shortened the day-level format to `X天后刷新` and constrained the quota line to one line with controlled tightening.
- Post-fix evidence: the rendered implementation keeps active and pending quota states on one line without changing the Token column or row height.

**Implementation checklist**

- [x] Apply compact countdown rule to shared Mac formatter.
- [x] Apply the same rule to the website formatter.
- [x] Keep member quota text on one line in both clients.
- [x] Run website tests/build and all 67 Mac client tests/build.
- [x] Inspect the real 456 × 640 Mac renderer and narrow website text output.

**Follow-up polish**

- None required for this scope.

final result: passed
