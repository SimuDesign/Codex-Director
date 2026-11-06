# Quota history — approved local UI contract

Approved for implementation with the [1.7.0 plan](../plans/2026-11-05-quota-history-1.7.0.md) on 2026-11-05. This document is a target, not runtime acceptance.

## Entry and structure

Home retains three modules and seven primary destinations. Add a labeled native secondary **额度历史 / Quota history** action to the quota module header, trailing at wide widths and wrapping below at compact widths. Use the existing 28pt action grammar with complete painted hit bounds. Do not add another refresh, source picker or primary destination.

Present one native Sheet, preserving Home scroll and returning keyboard/AX focus to the entry on dismissal. Ideal size 640×600, approximately 520–800pt wide within the parent/screen bounds. A 720×480 parent must remain usable without forced enlargement. The title and close action stay fixed; one vertical content scroll area contains the remaining content. Escape closes the native menu first when one is open, then the Sheet. No nested Sheet or side inspector.

Content order: valid current weekly/five-hour remaining and reported next resets with current capture time; independent outlined Last 7/30/60 days selector; read-only source name; recorded/calculable day counts, historical last observation and query cutoff; daily trend and accepted cycle-transition markers; continuous date rows with one inline expanded date. Source stays fixed at opening and changes via Home. Source disappearance never substitutes another source. Current account updates do not make historical observations appear fresh.

The period is shared and remembered independently of capability/ranking periods. Source/day/scroll/focus state remains window-local. Transition details page 20 at a time in memory; no per-row SQL or nested Sheet.

## Tokens and responsiveness

Consume existing DirectorColor, DirectorTypography, DirectorSpacing, outlined native segments and continuous rows. Padding 24pt, compact 16pt, section gap 24pt; date rows 16pt horizontal/12pt vertical. Use normal numeric/data roles, not Home-exclusive Avenir styles. No new assets, fonts, colors, glass content, decorative shadows or nested cards.

The 36pt outlined selector shows all three labels with existing brand selection and native independent focus. Wrap metadata while preserving complete dates and nonwrapping numbers. Charts reuse the quota gradient, dynamic value axis/headroom, horizontal grids and aligned date/bar centers. Seven days labels each day; 30/60 days use sparse ticks and avoid overlapping first/last dates. Do not put 60 numbers above bars. Selected dates have equivalent complete text in record rows.

Accepted transitions use a separate interval/mark band and **观察到周期切换 / Observed cycle transition** label. Same-day multiple transitions show a count. Expanded rows show the observation interval, not a fabricated actual reset instant.

## States, focus and privacy

- Known zero is `0%`; unknown is an em dash with a reason. Missing observation is not read failure.
- Today is partial observed use through its own observation time, not the final day total.
- Coverage means recorded X/N and calculable Y/N, not uninterrupted observation. Source-versus-account help must be keyboard/AX accessible.
- Pending uses native progress only in history content; close and period remain usable.
- Failed reads retain same-key previous content with retry/stale notice; first failure must not say “no records.” Retry is local history-only.
- Current expiry does not erase history or manufacture 100% remaining.
- Matching-input Home/history conflicts use evidenceConflict and do not count as calculable. Different cutoffs/timezones are not automatically conflicts.

Light/Dark, Increase Contrast, Reduce Motion and Reduce Transparency consume existing tokens. Small text meets 4.5:1, status is not color-only, focus is independently visible, reduced motion removes movement. Initial focus is close, then period and date records; updates do not steal focus. AX reads full date, period, numerical value/reason and transition interval. Hover is never the only fact access. Never display account identifiers, paths, raw records or session content.

## Required actual evidence

Use synthetic zh/en × Light/Dark at 720×480, 1280×800 and wide windows, sparse/all-unknown/zero/expired/current-missing/stale-error states and long dates. Verify entry/close/Escape/focus restoration, segments, chart/date synchronization, scrolling and in-memory pagination. Record real VoiceOver separately from AX; do not change OS settings without permission. Compilation and source tests are not visual acceptance.
