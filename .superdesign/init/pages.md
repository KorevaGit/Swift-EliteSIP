# Page dependency trees

All pages share `templates/base.html`, `static/app.css`, and `static/app.js`.

## /overview
- `internal/web/templates/overview.html`
  - `internal/web/templates/base.html`
  - `internal/web/static/app.css`
  - `internal/web/static/app.js`

## /employees
- `internal/web/templates/employees.html`
  - shared shell and assets above

## /employees/{id}
- `internal/web/templates/employee.html`
  - shared shell and assets above

## /presets
- `internal/web/templates/presets.html`
  - shared shell and assets above

## /presets/{id}
- `internal/web/templates/preset.html`
  - shared shell and assets above

## /audit
- `internal/web/templates/audit.html`
  - shared shell and assets above

## /settings
- `internal/web/templates/settings.html`
  - shared shell and assets above

## /login and /setup
- `internal/web/templates/login.html` or `setup.html`
  - `internal/web/templates/base.html`
  - shared assets above
