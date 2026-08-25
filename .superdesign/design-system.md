# EliteSIP Panel — Pearl Editorial System

## Product context

EliteSIP Panel is a compact Russian-language administrative site for a small office SIP client. Its jobs are operational rather than analytical: create employees, issue activation keys, maintain presets, inspect the audit trail, and edit installation settings. The interface must feel like a quiet tool, not a SaaS metrics dashboard.

Primary routes: Overview, Employees, Presets, Audit log, Settings. Preserve the existing information architecture, actions, Russian copy, semantic states, forms, tables, and disclosure sections.

## Primary visual source

Pearl by Dawid Pietrasiak is the single visual reference. Adapt its editorial restraint to an administrative application; do not reproduce its portfolio content or decorative project cards.

Source: https://pearl.framer.website/

Key Pearl traits to preserve:

- white-dominant matte canvas;
- Manrope throughout, mostly weight 500;
- strong black/gray typographic hierarchy;
- measured outer margins and deliberate empty space outside working data;
- transparent inset top navigation;
- broad, calm surfaces with soft 24px corners only when content is truly grouped;
- solid black pill actions;
- no gradients, blur, glass, glow, or ornamental illustration;
- restrained motion and no dashboard decoration.

## Application shell

- Replace the sidebar completely with top navigation.
- Desktop header: 72px minimum height, transparent white background, 80px horizontal inset, official EliteSIP AppIcon at left with the name EliteSIP; primary route links in one horizontal row; theme and account/logout controls aligned right.
- Active navigation is communicated by black text and a fine underline or small dot. Never use a filled navigation pill.
- The header remains compact and may become sticky with an opaque white background and one subtle hairline only after scrolling.
- Desktop content is fluid and wide: 48px side gutters, maximum useful width 1600–1800px. Do not constrain working tables to a narrow centered column.
- Mobile header has a compact brand/action row and a second horizontally scrollable navigation row. All routes remain visible and discoverable; no sidebar and no hamburger drawer.

Use the exact supplied official EliteSIP AppIcon in every logo position. Do not replace it with initials, emoji, generic telephone marks, invented SVGs, or text alone.

## Color system

Light is the primary designed theme.

- Canvas: #FFFFFF
- Primary ink: #000000
- Secondary ink: #969696
- Muted ink: #666666
- Quiet surface: #F2F2F4, adapted from Pearl's pale lavender-gray surface
- Hairline: #D9D9D9
- Inverse surface: #000000
- Inverse ink: #FFFFFF
- Primary action: black background, white text
- Link/action text: black with underline on hover; avoid generic bright blue in the product UI
- Success: #287A45
- Warning: #A56416
- Danger: #B33A35

Semantic colors are reserved for real status and validation. Never use them as decoration.

Dark theme, where retained, is a quiet tonal inversion: #111111 canvas, #F5F5F5 ink, #A5A5A5 secondary ink, #1C1C1C surface, #343434 hairline. It must keep the same Pearl hierarchy and matte character.

## Typography

- Family: Manrope, with system sans-serif fallbacks.
- Weight: 500 for almost all text; 600 only for critical compact labels when needed.
- Page title: 32px / 1.15 desktop, 30px / 1.15 tablet, 26px / 1.2 mobile. The overview may use a larger 36px editorial statement.
- Page-title supporting clause may continue at exactly the same size and weight in #969696, following Pearl's black-then-gray sentence treatment.
- Section title: 20px / 1.3.
- Table/form heading: 16px / 1.35.
- Body and controls: 14px / 1.4.
- Caption/metadata: 13px / 1.4, gray.
- Avoid uppercase micro-labels, excessive tracking, and tiny 11–12px dashboard text.

## Spacing and geometry

- Base unit: 8px.
- Desktop page gutter: 48px; tablet: 32px; mobile: 16–20px.
- Section rhythm: 24–40px between major regions.
- Internal content gaps: 8px, 12px, 16px, or 24px.
- Controls: 36–40px desktop; preserve 44px touch targets on mobile.
- Pill action radius: 999px.
- True grouped surface radius: 24px.
- Compact input/table row radius: 10–12px only when required.
- Avoid nesting rounded containers. A page section should usually be typography plus rows on the white canvas.

## Overview composition

The Overview page is the representative screen for approval.

1. Top navigation, no sidebar.
2. Editorial page introduction with a small contextual eyebrow and a large two-tone sentence: black title clause plus gray operational summary.
3. One black pill action for refreshing marks, aligned naturally with the introduction rather than floating in a toolbar.
4. Three operational counts presented as large typographic columns on the white canvas. No stat cards, colored icons, or miniature charts.
5. Problems and unfinished work rendered as spacious service-list rows with hairline dividers, clear text, status markers, and trailing actions/arrows.
6. The help section is a restrained accordion/list with large readable row labels and dividers, echoing Pearl's services list.
7. A black inverse footer band may contain secondary navigation, version/service state, and account actions. Do not force it into the first viewport.

## Tables, forms, and detail pages

- Tables are the dominant working plane and should use available width.
- Header row uses muted 12–13px labels; body rows are 14px with 40–44px height and hairline separators. A normal desktop viewport should show many records without turning the table into a separate scroll box.
- Avoid enclosing tables in cards. Only place a table on a quiet surface when it must be visually separated from a creation form.
- Forms use clear labels above inputs, compact vertical spacing, and simple white or quiet-gray fields with a 1px hairline. Secondary creation and diagnostic forms may be collapsed into disclosure rows so the working list stays primary.
- Use a single black pill as the primary submit action. Secondary actions are plain text or pale-gray pills.
- Destructive actions remain visually restrained until focused, hovered, or confirmed.
- Preset sections use large disclosure rows instead of many independent frames.

## Motion

- 140–220ms ease-out transitions.
- Small opacity and vertical-offset entrances are allowed on page load.
- Navigation underline, row arrow, and disclosure chevron may animate subtly.
- No parallax, spring bounce, hover lift, scale-up cards, animated gradients, or glass effects.
- Respect prefers-reduced-motion.

## Responsive behavior

- Desktop: top navigation and wide working canvas.
- Tablet: reduce gutters; allow actions to wrap under the title; keep navigation horizontally scrollable if required.
- Mobile: two-row header, horizontally scrollable route bar, single-column content, full-width controls, list-style tables with labels preserved.
- Never create horizontal document overflow. Only the navigation row may scroll horizontally.
- Preserve minimum 44px touch targets.

## Guardrails

- No sidebar.
- No grid of SaaS statistic cards.
- No excessive boxes, frames, chips, badges, or icon tiles.
- No gradients, glass, blur, neon, shadows on structural regions, or AI-generated decorative imagery.
- No generic dashboard hero copy or invented analytics.
- Do not add charts unless the source product genuinely contains chart data.
- Do not copy Pearl's portfolio text, project artwork, or creator identity.
- Use only the fonts, colors, spacing, and component styles defined here.
