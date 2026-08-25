# Extractable components

## AppShell
- Source: `elitesip-site/internal/web/templates/base.html`
- Category: layout
- Description: Authenticated shell with EliteSIP brand, five-section navigation, administrator footer, flash notices and main content slot.
- Extractable props: `activeSection`, `adminLogin`
- Hardcoded: EliteSIP phone mark, navigation labels and SVG icons, theme/logout controls.

No other layout component is independently templated. Buttons, fields, badges, notices and tables are simple CSS primitives and should stay inline in drafts.
