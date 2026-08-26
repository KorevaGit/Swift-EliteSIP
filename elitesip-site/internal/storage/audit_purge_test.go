package storage

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

// Уборка журнала уносит рутину и не трогает удаления сотрудников.
//
// Три месяца выбраны затем, чтобы не копить хлам. Но удаление сотрудника —
// единственное, что от человека остаётся: карточка стирается целиком именно
// потому, что строка в журнале остаётся навсегда, и на «кто сидел на 172 в
// прошлый вторник» отвечает только она. Жалоба всплывает и через полгода.
func TestPurgeAuditKeepsEmployeeDeletions(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "panel.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer db.Close()

	ctx := context.Background()
	now := time.Now()
	long := formatTime(now.AddDate(0, -6, 0))

	for _, row := range []struct{ action, details string }{
		{"ключ выпущен", "Пётр Смирнов"},
		{"вход в панель", "eugene"},
		{"сотрудник удалён", "Пётр Смирнов, номер 172"},
	} {
		if _, err := db.ExecContext(ctx,
			`INSERT INTO audit_log (at, actor_login, action, entity, details) VALUES (?, 'eugene', ?, 'employee', ?)`,
			long, row.action, row.details); err != nil {
			t.Fatalf("подготовка: %v", err)
		}
	}
	// Свежая рутина остаётся: она моложе срока.
	if _, err := db.ExecContext(ctx,
		`INSERT INTO audit_log (at, actor_login, action, entity, details) VALUES (?, 'eugene', 'ключ выпущен', 'employee', 'Анна')`,
		formatTime(now)); err != nil {
		t.Fatalf("подготовка: %v", err)
	}

	removed, err := db.PurgeAudit(ctx, now)
	if err != nil {
		t.Fatalf("PurgeAudit: %v", err)
	}
	if removed != 2 {
		t.Errorf("убрано строк: %d, ожидалось 2", removed)
	}

	left, err := db.AuditPage(ctx, AuditFilter{Limit: 10})
	if err != nil {
		t.Fatalf("AuditPage: %v", err)
	}
	if len(left) != 2 {
		t.Fatalf("в журнале осталось %d строк, ожидалось 2", len(left))
	}
	var kept bool
	for _, e := range left {
		if e.Action == "сотрудник удалён" {
			kept = true
			if e.Details != "Пётр Смирнов, номер 172" {
				t.Errorf("удаление сохранилось без подробностей: %q", e.Details)
			}
		}
	}
	if !kept {
		t.Error("уборка унесла удаление сотрудника — вместе с единственным ответом на «кто сидел на 172»")
	}
}
