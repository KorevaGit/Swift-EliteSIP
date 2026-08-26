package sand

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"
	"time"
)

// AuditDeliveryInterval — запасной проход outbox. Обычный обработчик после
// действия попробует доставить событие сразу; таймер подбирает то, что осталось
// после недоступности основной базы или остановки процесса между двумя файлами.
const AuditDeliveryInterval = 30 * time.Second

// AuditEvent — событие песочницы для общего журнала панели.
type AuditEvent struct {
	At         time.Time
	ActorID    *int64
	ActorLogin string
	Action     string
	Entity     string
	EntityID   *int64
	Details    string
}

// AuditSink — узкая граница основной базы. Пакет песочницы не должен знать её
// таблицы и миграции, ему нужна только идемпотентная операция приёма.
type AuditSink interface {
	LogExternal(context.Context, string, time.Time, *int64, string, string, string, *int64, string) error
}

// QueueAudit кладёт событие в outbox внутри уже открытой предметной транзакции.
// Будущие операции песочницы обязаны вызывать её до commit той же транзакции.
func QueueAudit(ctx context.Context, tx *sql.Tx, event AuditEvent) (string, error) {
	if event.Action == "" {
		return "", fmt.Errorf("у события песочницы нет действия")
	}
	if event.At.IsZero() {
		event.At = time.Now()
	}

	eventID, err := newEventID()
	if err != nil {
		return "", err
	}
	_, err = tx.ExecContext(ctx,
		`INSERT INTO audit_outbox
		 (event_id, at, actor_id, actor_login, action, entity, entity_id, details)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		eventID, formatTime(event.At), nullInt64(event.ActorID), event.ActorLogin,
		event.Action, event.Entity, nullInt64(event.EntityID), event.Details)
	if err != nil {
		return "", fmt.Errorf("поставить событие %q в outbox: %w", event.Action, err)
	}
	return eventID, nil
}

// DeliverAudit переносит не более limit событий в общий журнал. Нулевой limit
// означает обычную порцию в сто строк — достаточно для запуска и таймера, не
// удерживая единственное соединение sand.db надолго.
func (db *DB) DeliverAudit(ctx context.Context, sink AuditSink, limit int) (int, error) {
	if limit <= 0 {
		limit = 100
	}

	rows, err := db.QueryContext(ctx,
		`SELECT event_id, at, actor_id, actor_login, action, entity, entity_id, details
		   FROM audit_outbox
		  WHERE delivered_at IS NULL
		  ORDER BY at, event_id
		  LIMIT ?`, limit)
	if err != nil {
		return 0, fmt.Errorf("прочитать outbox песочницы: %w", err)
	}

	var events []outboxEvent
	for rows.Next() {
		var event outboxEvent
		var at string
		var actorID, entityID sql.NullInt64
		if err := rows.Scan(&event.ID, &at, &actorID, &event.ActorLogin,
			&event.Action, &event.Entity, &entityID, &event.Details); err != nil {
			rows.Close()
			return 0, fmt.Errorf("прочитать событие outbox: %w", err)
		}
		event.At, err = readTime(at)
		if err != nil {
			rows.Close()
			return 0, err
		}
		event.ActorID = readNullInt64(actorID)
		event.EntityID = readNullInt64(entityID)
		events = append(events, event)
	}
	if err := rows.Close(); err != nil {
		return 0, fmt.Errorf("закрыть чтение outbox: %w", err)
	}
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("прочитать outbox песочницы: %w", err)
	}

	delivered := 0
	for _, event := range events {
		if err := sink.LogExternal(ctx, event.ID, event.At, event.ActorID,
			event.ActorLogin, event.Action, event.Entity, event.EntityID, event.Details); err != nil {
			return delivered, err
		}
		if _, err := db.ExecContext(ctx,
			`UPDATE audit_outbox SET delivered_at = ?
			  WHERE event_id = ? AND delivered_at IS NULL`,
			formatTime(time.Now()), event.ID); err != nil {
			return delivered, fmt.Errorf("отметить событие %q доставленным: %w", event.ID, err)
		}
		delivered++
	}
	return delivered, nil
}

type outboxEvent struct {
	ID         string
	At         time.Time
	ActorID    *int64
	ActorLogin string
	Action     string
	Entity     string
	EntityID   *int64
	Details    string
}

func newEventID() (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("выпустить ID события outbox: %w", err)
	}
	return hex.EncodeToString(raw), nil
}

func formatTime(t time.Time) string {
	return t.UTC().Format(time.RFC3339Nano)
}

func readTime(raw string) (time.Time, error) {
	t, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		return time.Time{}, fmt.Errorf("прочитать время %q: %w", raw, err)
	}
	return t, nil
}

func nullInt64(value *int64) any {
	if value == nil {
		return nil
	}
	return *value
}

func readNullInt64(value sql.NullInt64) *int64 {
	if !value.Valid {
		return nil
	}
	return &value.Int64
}
