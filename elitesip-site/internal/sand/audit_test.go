package sand

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/koreva/elitesip-site/internal/storage"
)

type failingAuditSink struct{ err error }

func (s failingAuditSink) LogExternal(context.Context, string, time.Time, *int64,
	string, string, string, *int64, string) error {
	return s.err
}

func queueSandboxCreated(t *testing.T, db *DB) string {
	t.Helper()
	ctx := context.Background()
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("начать транзакцию: %v", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`INSERT INTO sandboxes (rop, format, created_at) VALUES ('Кочура', 'office', ?)`, testTime)
	if err != nil {
		t.Fatalf("создать песок: %v", err)
	}
	sandboxID, _ := res.LastInsertId()
	actorID := int64(3)
	eventID, err := QueueAudit(ctx, tx, AuditEvent{
		At:         time.Date(2026, 8, 26, 12, 0, 0, 0, time.UTC),
		ActorID:    &actorID,
		ActorLogin: "support",
		Action:     "sandbox.create",
		Entity:     "sandbox",
		EntityID:   &sandboxID,
		Details:    "РОП Кочура",
	})
	if err != nil {
		t.Fatalf("QueueAudit: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit: %v", err)
	}
	return eventID
}

func TestAuditSurvivesFailureBetweenDatabases(t *testing.T) {
	sandDB := openTemp(t)
	mainDB, err := storage.Open(filepath.Join(t.TempDir(), "panel.db"))
	if err != nil {
		t.Fatalf("открыть основную базу: %v", err)
	}
	t.Cleanup(func() { mainDB.Close() })

	eventID := queueSandboxCreated(t, sandDB)
	wantFailure := errors.New("основная база недоступна")
	if delivered, err := sandDB.DeliverAudit(context.Background(), failingAuditSink{wantFailure}, 100); !errors.Is(err, wantFailure) || delivered != 0 {
		t.Fatalf("первая доставка: delivered=%d err=%v", delivered, err)
	}

	var pending int
	if err := sandDB.QueryRow(`SELECT COUNT(*) FROM audit_outbox WHERE event_id = ? AND delivered_at IS NULL`, eventID).Scan(&pending); err != nil {
		t.Fatalf("прочитать outbox: %v", err)
	}
	if pending != 1 {
		t.Fatalf("после отказа в outbox строк %d, ожидалась одна", pending)
	}

	if delivered, err := sandDB.DeliverAudit(context.Background(), mainDB, 100); err != nil || delivered != 1 {
		t.Fatalf("повторная доставка: delivered=%d err=%v", delivered, err)
	}
	entries, err := mainDB.AuditPage(context.Background(), storage.AuditFilter{Action: "sandbox.create"})
	if err != nil {
		t.Fatalf("прочитать общий журнал: %v", err)
	}
	if len(entries) != 1 || entries[0].ActorLogin != "support" || entries[0].Details != "РОП Кочура" {
		t.Fatalf("в общем журнале не то событие: %#v", entries)
	}
}

func TestAuditRetryAfterAcceptedEventDoesNotDuplicate(t *testing.T) {
	sandDB := openTemp(t)
	mainDB, err := storage.Open(filepath.Join(t.TempDir(), "panel.db"))
	if err != nil {
		t.Fatalf("открыть основную базу: %v", err)
	}
	t.Cleanup(func() { mainDB.Close() })

	eventID := queueSandboxCreated(t, sandDB)
	// Имитируем остановку после INSERT в основной журнал, но до UPDATE outbox.
	if err := mainDB.LogExternal(context.Background(), eventID,
		time.Date(2026, 8, 26, 12, 0, 0, 0, time.UTC), nil, "support",
		"sandbox.create", "sandbox", nil, "РОП Кочура"); err != nil {
		t.Fatalf("предварительно принять событие: %v", err)
	}

	if delivered, err := sandDB.DeliverAudit(context.Background(), mainDB, 100); err != nil || delivered != 1 {
		t.Fatalf("повторная доставка: delivered=%d err=%v", delivered, err)
	}
	var count int
	if err := mainDB.QueryRow(`SELECT COUNT(*) FROM audit_log WHERE external_event_id = ?`, eventID).Scan(&count); err != nil {
		t.Fatalf("посчитать строки журнала: %v", err)
	}
	if count != 1 {
		t.Errorf("после повтора строк %d, ожидалась одна", count)
	}
}

func TestRolledBackActionLeavesNoAudit(t *testing.T) {
	db := openTemp(t)
	tx, err := db.Begin()
	if err != nil {
		t.Fatalf("Begin: %v", err)
	}
	if _, err := QueueAudit(context.Background(), tx, AuditEvent{Action: "sandbox.create"}); err != nil {
		t.Fatalf("QueueAudit: %v", err)
	}
	if err := tx.Rollback(); err != nil {
		t.Fatalf("Rollback: %v", err)
	}

	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM audit_outbox`).Scan(&count); err != nil {
		t.Fatalf("посчитать outbox: %v", err)
	}
	if count != 0 {
		t.Errorf("после rollback осталось событий: %d", count)
	}
}
