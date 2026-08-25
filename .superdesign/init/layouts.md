# Shared layout

## Authenticated shell
- Source: `elitesip-site/internal/web/templates/base.html`
- Two-column shell with a persistent sidebar, brand, five route links, administrator identity, theme switcher, logout, flash notices, and page content.
```html
{{if .Admin.Login}}
<div class="shell">
  <aside class="sidebar">
    <div class="brand"><span class="brand-mark">[phone SVG]</span><span><span class="brand-name">EliteSIP</span><br><span class="brand-note">панель управления</span></span></div>
    <nav class="nav">
      <a class="nav-item" href="/overview">Обзор</a>
      <a class="nav-item" href="/employees">Сотрудники</a>
      <a class="nav-item" href="/presets">Предустановки</a>
      <a class="nav-item" href="/audit">Журнал</a>
      <a class="nav-item" href="/settings">Настройки</a>
    </nav>
    <div class="sidebar-footer"><span class="who"><strong>{{.Admin.Login}}</strong><span>администратор</span></span>[theme/logout controls]</div>
  </aside>
  <main class="main">{{range .Flashes}}[notice/key/message]{{end}}{{template "content" .}}</main>
</div>
{{else}}{{template "content" .}}{{end}}
```

## Layout CSS
- Source: `elitesip-site/internal/web/static/app.css`
```css
.shell { display:grid; grid-template-columns:180px minmax(0,1fr); gap:12px; padding:12px; max-width:1280px; margin:0 auto; min-height:100vh; align-content:start; }
.sidebar { position:sticky; top:12px; align-self:start; max-height:calc(100vh - 24px); display:flex; flex-direction:column; padding:8px; border-radius:12px; background:var(--surface); border:.5px solid var(--hairline); }
.main { min-width:0; display:flex; flex-direction:column; gap:8px; }
.toolbar { display:flex; align-items:center; gap:8px; flex-wrap:wrap; padding:8px 12px; border-radius:12px; background:var(--surface); border:.5px solid var(--hairline); }
@media (max-width:900px) { .shell{grid-template-columns:minmax(0,1fr)} .nav{flex-direction:row;overflow-x:auto} }
```
