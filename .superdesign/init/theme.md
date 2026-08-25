# Theme

## Compact token summary

- Font: Apple system stack (`-apple-system`, BlinkMacSystemFont, SF Pro Text), mono: SF Mono/Menlo.
- Accent: macOS blue `#007aff` light / `#0a84ff` dark.
- Semantic: red `#ff3b30`, green `#34c759`, orange `#ff9500`.
- Light background `#eceef2`, dark `#16171a`; current UI adds three radial tint gradients.
- Surfaces: translucent white/dark panels with 0.5px hairlines and light blur.
- Spacing: 4, 6, 8, 12px; label column 132px.
- Radius: window 12px, card 10px, control 8px, buttons capsule.
- Type: 13px body, 15px h1, 13px h2, 11px secondary labels.
- Breakpoints: 900px shell collapse, 620px table-to-cards and vertical form layout.
- Motion: 120–180ms state transitions; disabled under reduced motion.

## Raw token source
Source: `elitesip-site/internal/web/static/app.css`
```css
:root {
  color-scheme:light dark;
  --accent:#007aff; --accent-hover:#0071eb; --accent-text:#fff;
  --red:#ff3b30; --green:#34c759; --orange:#ff9500;
  --bg:#eceef2;
  --surface:rgba(255,255,255,.72); --surface-solid:#fff; --surface-raised:rgba(255,255,255,.86); --surface-sunken:rgba(120,120,128,.08); --surface-hover:rgba(120,120,128,.10);
  --hairline:rgba(0,0,0,.10); --hairline-strong:rgba(0,0,0,.16);
  --text:#1c1c1e; --text-secondary:rgba(60,60,67,.62); --text-tertiary:rgba(60,60,67,.38);
  --pad:12px; --pad-tight:8px; --gap-section:8px; --gap-element:6px; --gap-tight:4px;
  --label-column:132px; --radius-window:12px; --radius-card:10px; --radius-control:8px; --radius-capsule:999px;
  --font:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue","Segoe UI",system-ui,sans-serif;
  --font-mono:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace;
}
```

The full canonical CSS is `elitesip-site/internal/web/static/app.css` and must be passed directly to design generation using token and selector ranges because it is 1248 lines.
