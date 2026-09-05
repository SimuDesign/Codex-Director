# Codex Director AppIcon v2

Status: approved implementation direction

## Intent

The icon uses the approved rounded hexagon mark as a compact expression of coordinated capabilities. Three broad blue, cyan and mint fields flow through one stable container, retaining a light visual relationship to interlocking AI marks without reproducing another product's logo. It contains no text, prompt content, file path, user identity, or SF Symbol.

## Layer contract

- Background: full-bleed deep navy field with a restrained diagonal tonal gradient.
- Mark: one centered rounded hexagon containing three flat, subtly softened blue–cyan–mint fields.
- Treatment: no pre-rendered corner radius, ornamental outline, glass layer, specular highlight, or drop shadow.

The approved 4096×4096 production export `CD-FM-H-v2.2-fullbleed-dark` remains the visual source. The shipping Icon Composer document reconstructs it as three 1024×1024 alpha-mask layers—blue hexagon, cyan band and mint field—over the document's navy gradient fill. This keeps the approved silhouette and color relationships while allowing Icon Composer and the platform to control system corner masking, appearance variants and macOS icon-size rendering.

## Accessibility and privacy

The icon communicates identity and coordination, not runtime content. Runtime status, evidence confidence, and task details stay in the app UI and are never encoded as user-specific icon text or imagery.

## Build status and validation

`Resources/AppIcon.icon` is the formal Xcode 26 Icon Composer source. The Xcode target passes the
`.icon` package to `actool`, which generates the macOS `AppIcon.icns` and compiled asset data at build
time; no legacy asset-catalog fallback is part of the target. The source package contains the artwork
layers and manifest, while system masking and appearance rendering remain platform controlled.

Build validation must confirm that `CFBundleIconName == AppIcon`, `AppIcon.icns` is present, the
Icon Composer compilation succeeds, and the bundle is signed with the hardened runtime. Human review
remains required for Finder, Dock, Launchpad, Spotlight, app switcher, About, Light, and Dark
appearances.
