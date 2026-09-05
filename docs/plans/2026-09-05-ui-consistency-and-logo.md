# UI consistency and logo integration plan

Date: 2026-09-05  
Branch: `ui-optimization`

## Approved scope

- Replace the shipping application icon with the approved clean hexagon mark on a subtly graduated dark, full-bleed background.
- Make Home the page-grid reference for all six primary destinations.
- Keep each page's native scroll container full width so its vertical scroll indicator remains on the workspace's far-right edge.
- Use one responsive page-title scale and one decorative-symbol size across primary pages.

## Visual contract

- Standard horizontal gutter: 40 pt at workspace widths of 760 pt or wider.
- Compact horizontal gutter: 16 pt below 760 pt.
- Vertical page gutter: 24 pt.
- Maximum readable content width: 1440 pt, centered inside the workspace.
- Page title: rounded semibold system face, 60 pt standard and 42 pt compact.
- Decorative page symbol: 24 pt semibold, semantic accent color, hidden from accessibility because the adjacent title carries the meaning.
- Primary page titles use the same solid primary-text treatment as Home; title-word gradients are removed.
- Home remains illustration-free and therefore does not gain a decorative page symbol.

## Implementation

1. Add a shared page-layout calculation and shared scroll-content frame.
2. Route Home and Settings scroll content through that frame.
3. Keep the capability `List` full width and apply the shared grid using scroll-content margins.
4. Update Home and capability titles to use the shared responsive title and symbol tokens; remove Settings and capability title accents.
5. Point the Icon Composer package at the approved raster source while preserving the platform-owned app-icon mask.
6. Update visual-system documentation and source-contract tests.

## Verification

- Run focused DirectorUI page-chrome and layout tests.
- Run the complete Swift test suite.
- Build the synthetic-data UI-validation app and inspect all six primary destinations at standard and compact widths.
- Build, install, verify, and relaunch the local application according to the repository deployment contract.

