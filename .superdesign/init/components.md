# Shared UI components

The panel is server-rendered Go HTML with no frontend framework or component library. Shared primitives are CSS classes in `elitesip-site/internal/web/static/app.css`; page templates reuse them directly.

## Button
- Source: `elitesip-site/internal/web/static/app.css`
- Variants: `.button`, `.button-primary`, `.button-danger`, `.button-quiet`
```css
.button { display:inline-flex; align-items:center; justify-content:center; gap:4px; padding:4px 10px; border:.5px solid var(--hairline-strong); border-radius:999px; background:var(--surface-raised); color:var(--text); font:inherit; font-weight:500; cursor:pointer; }
.button-primary { background:var(--accent); border-color:transparent; color:var(--accent-text); }
.button-danger { color:var(--red); }
.button-quiet { background:transparent; border-color:transparent; box-shadow:none; color:var(--text-secondary); }
```

## Fields
- Source: `elitesip-site/internal/web/static/app.css`
```css
.field { display:flex; flex-direction:column; gap:var(--gap-tight); min-width:0; }
.field > label,.field-label { font-size:11px; font-weight:590; color:var(--text-secondary); }
input[type="text"],input[type="password"],input[type="number"],input[type="search"],select,textarea { width:100%; padding:5px 8px; font:inherit; color:var(--text); background:var(--surface-solid); border:.5px solid var(--hairline-strong); border-radius:var(--radius-control); }
```

## Data table, status and notices
- Source: `elitesip-site/internal/web/static/app.css`
```css
.table { width:100%; border-collapse:collapse; }
.table th { text-align:left; font-size:10px; font-weight:590; text-transform:uppercase; letter-spacing:.04em; color:var(--text-tertiary); padding:4px 12px; border-bottom:.5px solid var(--hairline); }
.table td { padding:6px 12px; border-bottom:.5px solid var(--hairline); vertical-align:middle; }
.badge { display:inline-flex; align-items:center; gap:5px; padding:2px 9px; border-radius:999px; font-size:12px; font-weight:500; background:var(--surface-sunken); color:var(--text-secondary); }
.notice { display:flex; gap:8px; align-items:flex-start; padding:8px 12px; border-radius:10px; border:.5px solid var(--hairline); background:var(--surface-raised); }
```
