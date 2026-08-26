package storage

import (
	"context"
	"testing"
	"time"
)

func TestLogExternalIsIdempotent(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()
	at := time.Date(2026, 8, 26, 12, 0, 0, 0, time.UTC)
	actorID := int64(42)
	entityID := int64(7)

	for range 2 {
		if err := db.LogExternal(ctx, "sand-event-1", at, &actorID, "support",
			"sandbox.create", "sandbox", &entityID, "РОП Кочура"); err != nil {
			t.Fatalf("LogExternal: %v", err)
		}
	}

	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM audit_log WHERE external_event_id = 'sand-event-1'`).Scan(&count); err != nil {
		t.Fatalf("посчитать события: %v", err)
	}
	if count != 1 {
		t.Errorf("строк внешнего события %d, ожидалась одна", count)
	}
}

func TestLogExternalNeedsID(t *testing.T) {
	db := openTemp(t)
	if err := db.LogExternal(context.Background(), "", time.Now(), nil, "",
		"sandbox.create", "sandbox", nil, ""); err == nil {
		t.Fatal("внешнее событие без ID принято")
	}
}
