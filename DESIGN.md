# Vordi Design System

This is the product UI source of truth for Vordi. It is derived from the local reference set at `/Users/raunaksingh/Desktop/wisprflow-ui`, which contains 47 Wispr Flow macOS screenshots captured on 2026-05-25.

Use the visual language, spacing, controls, and state patterns. Do not ship copied Wispr Flow logos, screenshots, text, or photographic assets. Recreate any imagery as Vordi-branded assets with the same calm, dark, warm, photographic treatment.

## Summary

Vordi should feel like a polished native macOS productivity tool: warm off-white surfaces, quiet navigation, black primary actions, soft rounded cards, compact type, and minimal color. Color is functional, not decorative. The interface should be calm enough for repeated daily use.

The Swift implementation lives in `Sources/Views/DesignSystem.swift`. Base tokens still live in `Theme` inside `Sources/Views/MainDashboardView.swift`; `DesignSystem.swift` extends them with the screenshot-derived components and measurements.

## Reference Measurements

The screenshot set is mostly `3024 x 1964` px, which is a 2x Retina capture of a `1512 x 982` pt app window. Use point values in code.

- App capture: `1512 x 982 pt`
- Sidebar width: `218 pt`
- Main rounded pane starts at `x = 218 pt`
- Main content page padding: `44 pt` horizontal, `28 pt` top
- Centered content width for Dictionary, Snippets, Scratchpad: about `808 pt`
- Settings overlay panel: `960 x 640 pt`
- Settings inner nav width: `212 pt`
- Standard list row height: `56 pt`
- Input height: `40 pt`
- Primary action height: `38 pt`
- Loading modal: `720 x 504 pt`
- Add vocabulary modal: `528 x 256 pt`
- Add or edit snippet modal: `688 x 480 pt`
- Confirmation modal: `688 x 212 pt`
- Languages modal: `852 x 548 pt`
- Milestone/stats modal: `608 x 374 pt`

## Color

Use warm neutrals first.

- Canvas/sidebar: warm cream, close to `#F5F1EA`
- Main content: almost white, close to `#FBFAF7`
- Raised surfaces: warm white or light cream, not blue-gray
- Primary text: near-black warm ink, close to `#1A1714`
- Secondary text: muted warm brown-gray, close to `#5A5450`
- Dividers: 1 px warm gray lines, very low contrast
- Primary CTA: black/near-black fill with cream text
- Secondary CTA: warm gray fill, close to `#EDE9E1`, with dark text
- Destructive CTA: soft coral red, not bright system red
- Selected/focus accent: violet, used for selected mic/language/focus states only
- Promo tint: pale lavender for trial or plan chips

Do not make orange the global UI accent. Orange is only for the `fn` badge and a few Vordi-specific highlights.

## Typography

Use system sans for product UI and Georgia/New York-style serif only for editorial moments.

- Main product page titles: system sans, 20 pt, semibold
- Settings section titles: serif, 24 pt, regular
- Hero display: 26 pt, semibold, with italic serif for a single emphasized word
- Body/nav/list rows: 14 pt
- Supporting copy: 13 pt
- Captions/timestamps: 11 pt
- Category labels: 10 pt, semibold, uppercase, tracking about `0.5`
- Hotkey labels: monospaced, 13 pt semibold

Never use display type inside buttons, form labels, table rows, or dense controls.

## Layout

The product shape is sidebar plus a large rounded main pane.

- Keep the sidebar quiet, cream, and fixed width.
- Main panes should feel spacious, not card-stacked.
- Center content-heavy pages inside an `808 pt` column.
- Put page title left and primary action right on the same baseline.
- Use underline tabs for `All`, `Personal`, and `Shared with team`; no segmented pill for those filters.
- Use grouped settings sections as warm blocks with 56 pt rows and hairline dividers.
- Do not put cards inside cards. Use repeated cards only for real repeated items.

## Components

Use these Swift components for new UI:

- `VFButton`: all buttons. Use `.primary`, `.secondary`, `.destructive`, `.ghost`, `.outline`, or `.pill`.
- `VFBadge`: `Basic`, `Beta`, discount, and promo labels.
- `VFPageHeader`: page title plus optional badge and CTA.
- `VFTabBar`: underline tabs.
- `VFFormSection`, `VFFormRow`, `VFDivider`: settings rows.
- `VFSearchBar`: inline search fields in toolbar areas.
- `VFToggle`: switch rows with black ON state.
- `VFDropdown`: compact select controls and popovers.
- `VFContextMenuItem`: three-dot menus.
- `VFConfirmDialog`: destructive confirmations.
- `VFLoadingOverlay`: modal loading state, never use a loose spinner.
- `VFMicRowItem`: selectable microphone row.
- `VFHeroBanner`: dark photographic/hero card pattern.

## Interaction States

Every reusable component must support default, hover, focus, pressed, disabled, loading, and destructive/error states where applicable.

- Loading state is a centered modal with icon, bold `Loading...`, and a thin animated bar.
- Modal backdrop is black at roughly 28 percent opacity.
- Popovers are white, radius 12, 1 px border, and soft shadow.
- Context menus use left icons, 36-40 pt rows, and red only for destructive items.
- Search opens inline in the toolbar area; do not show a separate search page.
- Toggles use black ON, warm-gray OFF.
- Selected language/mic items use violet border and pale violet fill.

## Imagery

Hero banners use a darkened, blurred, warm photograph with text over it. Use real or generated bitmap images with a strong dark overlay. Avoid abstract gradients, decorative blobs, or SVG hero art.

## Review Checklist

Before shipping a new UI surface:

- It uses `Theme`, `Font.vf*`, and `VF*` components.
- No new hard-coded colors, radii, shadows, or arbitrary spacing.
- Page width and modal width match the reference measurements above.
- Primary actions are black, not orange.
- Tabs are underline tabs, not segmented pills, unless the task is a compact mode switch.
- Inputs are 40 pt tall with 8 pt radius.
- Destructive actions are coral red and always paired with cancel.
- Loading uses `VFLoadingOverlay`.
- No copied Wispr Flow assets or text are shipped.
