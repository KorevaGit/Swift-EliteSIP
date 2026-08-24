package storage

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
)

// logAction пишет строку журнала внутри уже открытой транзакции.
//
// Внутри транзакции, а не рядом с ней, намеренно: администраторы равны и все
// могут всё, поэтому журнал — единственный ответ на «кто это сделал». Запись,
// которую можно потерять отдельно от действия, такого ответа не даёт.
func logAction(ctx context.Context, tx *sql.Tx, at time.Time, actor *int64, action, entity string, entityID *int64, details string) error {
	_, err := tx.ExecContext(ctx,
		`INSERT INTO audit_log (at, admin_id, action, entity, entity_id, details)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		formatTime(at), nullInt64(actor), action, entity, nullInt64(entityID), details,
	)
	if err != nil {
		return fmt.Errorf("записать в журнал действие %q: %w", action, err)
	}
	return nil
}

// AuditPage возвращает последние строки журнала, самые свежие первыми.
func (db *DB) AuditPage(ctx context.Context, limit int) ([]model.AuditEntry, error) {
	rows, err := db.QueryContext(ctx,
		`SELECT id, at, admin_id, action, entity, entity_id, details
		   FROM audit_log ORDER BY id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("прочитать журнал: %w", err)
	}
	defer rows.Close()

	var out []model.AuditEntry
	for rows.Next() {
		var (
			e        model.AuditEntry
			at       string
			adminID  sql.NullInt64
			entityID sql.NullInt64
		)
		if err := rows.Scan(&e.ID, &at, &adminID, &e.Action, &e.Entity, &entityID, &e.Details); err != nil {
			return nil, fmt.Errorf("прочитать строку журнала: %w", err)
		}
		e.At = readTime(at)
		e.AdminID = readNullInt64(adminID)
		e.EntityID = readNullInt64(entityID)
		out = append(out, e)
	}
	return out, rows.Err()
}
