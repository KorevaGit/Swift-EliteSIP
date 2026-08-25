# Routes

Router: Go 1.22 `http.ServeMux` in `elitesip-site/internal/web/server.go`. Every authenticated page uses `templates/base.html`.

| Route | Template | Purpose |
|---|---|---|
| `/login` | `login.html` | Sign in |
| `/setup` | `setup.html` | Create first administrator |
| `/overview` | `overview.html` | Operational dashboard, loose ends and instructions |
| `/employees` | `employees.html` | Create/search/list employees |
| `/employees/{id}` | `employee.html` | Employee details, activations and destructive actions |
| `/presets` | `presets.html` | Create/list/publish presets |
| `/presets/{id}` | `preset.html` | Large preset editor and revision history |
| `/audit` | `audit.html` | Audit log |
| `/settings` | `settings.html` | Office admin password and application URL |

```go
mux.Handle("GET /overview", s.guard(s.showOverview))
mux.Handle("GET /employees", s.guard(s.showEmployees))
mux.Handle("GET /employees/{id}", s.guard(s.showEmployee))
mux.Handle("GET /presets", s.guard(s.showPresets))
mux.Handle("GET /presets/{id}", s.guard(s.showPreset))
mux.Handle("GET /audit", s.guard(s.showAudit))
mux.Handle("GET /settings", s.guard(s.showSettings))
```
