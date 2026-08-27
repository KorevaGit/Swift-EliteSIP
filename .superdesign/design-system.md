# EliteSIP Panel — Compact Framed Workspace

## Product context

EliteSIP Panel is a compact Russian-language administrative site for a small office SIP client. Its jobs are operational rather than analytical: create employees, issue activation keys, maintain presets, work with sandbox trainees, inspect the audit trail, and edit installation settings. The interface must feel like a quiet, compact operational tool, not a SaaS metrics dashboard.

Preserve the existing information architecture, actions, Russian copy, semantic states, forms, tables, and disclosure sections across all routes.

## Primary visual direction

The user-provided EliteSIP admin screenshot is the primary visual reference. Treat it as a direction, not a pixel-perfect target: retain its compact top navigation and framed content groups, but improve alignment, density, responsive behavior, and visual polish.

Core traits:

- very light neutral canvas with white working cards;
- Manrope throughout, mostly weight 500;
- restrained black/gray hierarchy without display-sized page titles;
- compact, consistent outer margins and tight vertical rhythm;
- transparent inset top navigation;
- related content packed into bounded cards with 14–16px corners, subtle borders, and one restrained shadow;
- solid black pill actions;
- no gradients, blur, glass, glow, ornamental illustration, or dashboard decoration.

## Application shell

- No sidebar.
- Desktop header: 64px minimum height, transparent white background, 48px horizontal inset, official EliteSIP brand mark and product name at left; primary products in one horizontal row; theme, account, and logout controls aligned right.
- Active navigation uses black text and a fine underline. Never use a filled navigation pill.
- Product subnavigation is a compact second row only where needed.
- Desktop content is fluid and wide: 32–48px side gutters and a maximum useful width around 1600px. Working tables must not be constrained to a narrow centered column.
- Mobile header has a compact brand/action row and horizontally scrollable navigation rows. No hamburger drawer.

Use the exact supplied official EliteSIP logo in every logo position. Do not replace it with initials, emoji, a generic telephone mark, an invented SVG, or text alone.

## Color system

Light is the primary designed theme.

- Canvas: #F6F6F7
- Card surface: #FFFFFF
- Primary ink: #000000
- Secondary ink: #666666
- Tertiary ink: #969696
- Quiet surface: #F2F2F4
- Hairline: #D9D9D9
- Strong hairline: #BCBCBC
- Inverse surface: #000000
- Inverse ink: #FFFFFF
- Primary action: black background, white text
- Success: #287A45
- Warning: #A56416
- Danger: #B33A35

Semantic colors are reserved for real status and validation. Never use them as decoration.

Dark theme is a quiet tonal inversion: #111111 canvas, #1C1C1C cards, #F5F5F5 ink, #A5A5A5 secondary ink, #343434 hairline. It must retain the same density and hierarchy.

## Typography

- Family: Manrope, with system sans-serif fallbacks.
- Weight: 500 for most text; 600 for critical compact labels and actions.
- Page title: 22–24px desktop, 21–22px tablet, 20px mobile. Omit it entirely when active navigation and card headings already provide sufficient orientation.
- Never use an editorial hero sentence or display-sized introductory heading in the admin portal.
- Card title: 17–20px / 1.3.
- Table/form heading: 15–17px / 1.35.
- Body and controls: 14px / 1.4.
- Caption/metadata: 12–13px / 1.4, gray.
- Avoid uppercase micro-labels and excessive tracking.

## Spacing and geometry

- Base unit: 4px, with common gaps of 8, 12, 16, 20, and 24px.
- Desktop page gutter: 32–48px; tablet: 24–32px; mobile: 14–18px.
- Section rhythm: 12–20px between major regions.
- Card padding: 18–24px desktop, 16–18px mobile.
- Controls: 36–40px desktop; preserve 44px touch targets on mobile.
- Primary action radius: 999px.
- Grouped card radius: 14–16px.
- Input radius: 10–12px.
- Cards use a 1px neutral border and one restrained shadow such as 0 4px 16px rgba(0,0,0,.06). Never stack multiple shadow styles.
- Avoid nested rounded containers. Tinted inset rows are allowed only for controls, summaries, or status details inside a card.

## Representative overview composition

The Overview page is the representative screen for approval.

1. Keep the existing top navigation and product architecture; no sidebar.
2. Remove the large page title and editorial introduction. Start with operational content immediately after a compact optional context/action row.
3. Use a responsive two-column workspace: a wider primary column for product/state summary and unresolved work; a secondary column for setup status, quick actions, and help. Collapse to one column on narrow screens.
4. Put each meaningful content group in a clean card frame. Card headers contain a short title, optional one-line explanation, and trailing action or count where useful.
5. Operational counts are compact summary cells inside one card, not separate oversized stat cards. Values should usually be 26–34px, never hero-sized.
6. Problems and unfinished work are compact rows inside their parent cards. Separate rows with subtle internal hairlines; do not use page-wide divider bands.
7. Help is a compact accordion card with 48–56px rows.

## Tables, forms, and detail pages

- Tables use available width inside one table card.
- Header rows use a quiet gray fill and muted 12–13px labels. Body rows are 14px with 40–44px height and subtle internal separators. The card supplies the outer boundary; avoid duplicate borders around the table.
- Forms are grouped into cards by task. Use compact labels, tight vertical spacing, and white or quiet-gray fields with a 1px hairline.
- On mixed pages, place the form card beside or above the dominant table card according to available width. Keep the working list visually primary.
- Use one black pill as the primary submit action. Secondary actions are plain text or pale-gray pills.
- Destructive actions remain restrained until focused, hovered, or confirmed.
- Preset sections use compact cards or disclosure groups: one card per coherent domain, never one per field.
- Status badges are allowed only where a text state needs rapid scanning. Keep them small, low-contrast, and semantic.

## Motion

- 140–200ms ease-out transitions.
- Navigation underline, row arrow, button fill, and disclosure chevron may animate subtly.
- No parallax, spring bounce, scale-up cards, animated gradients, or glass effects.
- An interactive card may only adjust its border or shadow slightly on hover.
- Respect prefers-reduced-motion.

## Responsive behavior

- Desktop: top navigation and compact two- or three-column card grids where the content supports them.
- Tablet: reduce gutters and collapse grids intentionally; allow header actions to wrap.
- Mobile: two-row header, horizontally scrollable route bar, single-column cards, full-width controls, and list-style tables with labels preserved.
- Never create horizontal document overflow. Only navigation and genuinely wide data tables may scroll within their own bounded region.
- Preserve minimum 44px touch targets.

## Guardrails

- No sidebar.
- No display-sized page headings or editorial hero copy.
- No grid of isolated SaaS statistic cards; group related metrics into one summary card.
- Every frame must correspond to a clear task or information group. Do not box individual labels, fields, or rows.
- No page-wide divider bands as the primary grouping mechanism.
- No gradients, glass, blur, neon, heavy shadows, or AI-generated decorative imagery.
- No generic dashboard copy, invented analytics, or charts unsupported by the product.
- Do not change product behavior or invent new data.
- Use only the fonts, colors, spacing, and component styles defined here.
