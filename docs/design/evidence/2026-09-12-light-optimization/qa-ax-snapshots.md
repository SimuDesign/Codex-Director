# Independent QA AX snapshots · 2026-09-12

These are excerpts recorded from the isolated `Codex Director Validation` host
with the CUA bridge after source freeze. The host used Stress synthetic data;
no production app, preferences or user data were opened.

## Light, English, 720 × 480, Installed Plugins

The host reported `Actual product viewport size: Product 720 × 480`. The
capability list exposed a separate filter row containing:

- `text field Search capabilities`
- `menu button View, Value: All capabilities`
- `menu button Sort, Value: Past 7 days ↓`
- `menu button Plugin status, Value: All plugins`

The screenshot showed the search field on its own full row and the three
selectors on the following row. Scrolling the list changed the scroll value and
kept all four closed values available in AX.

## Light, Chinese, 1280, selected capability

After clicking the first capability, AX exposed a detail container with
`button Description: 关闭详情` and `button Description: 查看调用证据`. The
selected row remained readable behind the detail scrim. Closing the sheet
returned the list and removed the selected capability state.

## Dark, English, 1600, selected capability and evidence

The host reported `Product 1600 × 748` because the display constrained the
requested height. After selecting the first capability, AX exposed
`button Description: View usage evidence`. Activating it changed the same
control to `button Description: Hide usage evidence`; activating it again
removed the evidence entries and restored the original control. The detail
sheet close button remained available throughout.

## Settings refresh states

With the host's refresh-loading switch on, Settings exposed a disabled native
busy indicator labelled `Refreshing…`; the Settings action and adjacent delete
action were visibly aligned at the same outer height in Light and Dark. With
the switch off, AX exposed the disabled `Update now` button and the enabled
`Delete derived index` button. The Light loading action used white content on a
dark opaque rail.

## Keyboard and stress interaction

Focusing the capability list and pressing Down selected a real capability and
opened its detail. Escape/close returned to the list. A down/up/down scroll
sequence completed at scroll value `1` without a crash or outline reload. AX
structural rows (header, metrics, filter and group rows) remained present but
did not become the selected capability.

This file records AX inspection, not VoiceOver speech. VoiceOver, Increase
Contrast, Reduce Transparency and Reduce Motion were not exercised in this
run.
