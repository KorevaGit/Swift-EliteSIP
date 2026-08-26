package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
)

// logAction пишет строку журнала внутри уже открытой транзакции.
//
// Внутри транзакции, а не рядом с ней, намеренно: администраторы равны и все
// могут всё, поэтому журнал — единственный ответ на «кто это сделал». Запись,
// которую можно потерять отдельно от действия, такого ответа не даёт.
func logAction(ctx context.Context, tx *sql.Tx, at time.Time, actor *int64, action, entity string, entityID *int64, details string) error {
	// Логин берётся подзапросом в момент записи, а не параметром: так ни одно
	// из тринадцати мест, которые пишут в журнал, не может его забыть.
	_, err := tx.ExecContext(ctx,
		`INSERT INTO audit_log (at, admin_id, actor_login, action, entity, entity_id, details)
		 VALUES (?, ?, COALESCE((SELECT login FROM admins WHERE id = ?), ''), ?, ?, ?, ?)`,
		formatTime(at), nullInt64(actor), nullInt64(actor),
		action, entity, nullInt64(entityID), details,
	)
	if err != nil {
		return fmt.Errorf("записать в журнал действие %q: %w", action, err)
	}
	return nil
}

// LogExternal принимает событие из outbox соседней базы.
//
// externalID делает приём идемпотентным: процесс может успеть записать строку
// сюда и умереть до отметки доставки в sand.db. Повтор после запуска увидит
// тот же ID, ничего не продублирует и завершится успешно.
func (db *DB) LogExternal(ctx context.Context, externalID string, at time.Time,
	actor *int64, actorLogin, action, entity string, entityID *int64, details string) error {
	if externalID == "" {
		return errors.New("у внешнего события нет идентификатора")
	}

	_, err := db.ExecContext(ctx,
		`INSERT INTO audit_log
		 (external_event_id, at, admin_id, actor_login, action, entity, entity_id, details)
		 VALUES (?, ?,
		         CASE WHEN ? IS NULL THEN NULL
		              WHEN EXISTS (SELECT 1 FROM admins WHERE id = ?) THEN ?
		              ELSE NULL END,
		         ?, ?, ?, ?, ?)
		 ON CONFLICT(external_event_id) WHERE external_event_id IS NOT NULL DO NOTHING`,
		externalID, formatTime(at), nullInt64(actor), nullInt64(actor), nullInt64(actor), actorLogin,
		action, entity, nullInt64(entityID), details)
	if err != nil {
		return fmt.Errorf("принять внешнее событие %q: %w", externalID, err)
	}
	return nil
}

// AuditFilter — отбор в журнале.
//
// Четыре поля и ни одним больше: тип события, человек, срок и поиск по тексту.
// Отдельного отбора по сотруднику или предустановке нет — поиск текстом его
// покрывает, а пятый список в шапке читается хуже, чем ищется.
type AuditFilter struct {
	Action string    // точное название события
	Actor  string    // логин
	Since  time.Time // нулевое время — без ограничения
	Query  string    // подстрока в подробностях
	Limit  int
	Offset int
}

// AuditPage возвращает строки журнала, самые свежие первыми.
func (db *DB) AuditPage(ctx context.Context, filter AuditFilter) ([]model.AuditEntry, error) {
	query := `SELECT id, at, admin_id, actor_login, action, entity, entity_id, details
		        FROM audit_log`

	var (
		where []string
		args  []any
	)
	if filter.Action != "" {
		where = append(where, `action = ?`)
		args = append(args, filter.Action)
	}
	if filter.Actor != "" {
		where = append(where, `actor_login = ?`)
		args = append(args, filter.Actor)
	}
	if !filter.Since.IsZero() {
		where = append(where, `at >= ?`)
		args = append(args, formatTime(filter.Since))
	}
	if filter.Query != "" {
		where = append(where, `(details LIKE ? OR action LIKE ?)`)
		args = append(args, "%"+filter.Query+"%", "%"+filter.Query+"%")
	}
	if len(where) > 0 {
		query += ` WHERE ` + strings.Join(where, ` AND `)
	}

	limit := filter.Limit
	if limit <= 0 {
		limit = 100
	}
	query += ` ORDER BY id DESC LIMIT ? OFFSET ?`
	args = append(args, limit, filter.Offset)

	rows, err := db.QueryContext(ctx, query, args...)
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
		if err := rows.Scan(&e.ID, &at, &adminID, &e.ActorLogin,
			&e.Action, &e.Entity, &entityID, &e.Details); err != nil {
			return nil, fmt.Errorf("прочитать строку журнала: %w", err)
		}
		e.At = readTime(at)
		e.AdminID = readNullInt64(adminID)
		e.EntityID = readNullInt64(entityID)
		out = append(out, e)
	}
	return out, rows.Err()
}

// AuditActions перечисляет названия событий, которые в журнале есть.
//
// Из них собирается отбор по типу. Список берётся из самих записей, а не из
// перечня в коде: перечень разошёлся бы с действительностью в первый же раз,
// когда где-то заведут новое событие и забудут дописать его сюда.
func (db *DB) AuditActions(ctx context.Context) ([]string, error) {
	rows, err := db.QueryContext(ctx, `SELECT DISTINCT action FROM audit_log ORDER BY action`)
	if err != nil {
		return nil, fmt.Errorf("перечислить события журнала: %w", err)
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var action string
		if err := rows.Scan(&action); err != nil {
			return nil, fmt.Errorf("прочитать название события: %w", err)
		}
		out = append(out, action)
	}
	return out, rows.Err()
}

// AuditActors перечисляет имена, встречающиеся в журнале.
func (db *DB) AuditActors(ctx context.Context) ([]string, error) {
	rows, err := db.QueryContext(ctx,
		`SELECT DISTINCT actor_login FROM audit_log WHERE actor_login <> '' ORDER BY actor_login`)
	if err != nil {
		return nil, fmt.Errorf("перечислить имена в журнале: %w", err)
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var login string
		if err := rows.Scan(&login); err != nil {
			return nil, fmt.Errorf("прочитать имя из журнала: %w", err)
		}
		out = append(out, login)
	}
	return out, rows.Err()
}

// AuditRetention — сколько живёт рутинная строка журнала.
//
// Три месяца. Дальше она отвечает на вопросы, которых уже не задают, а место в
// базе занимает.
const AuditRetention = 90 * 24 * time.Hour

// AuditKeptForever — события, которые не чистятся никогда.
//
// Одно, и оно не оптимизация, а условие: карточка сотрудника удаляется целиком
// именно потому, что строка «удалён Пётр Смирнов, номер 172» остаётся навсегда.
// На «кто сидел на 172 в прошлый вторник» отвечает только она — CDR на АТС
// знает номер, но не человека, — а жалоба всплывает и через полгода.
//
// Убирая отсюда строку, надо сначала убрать обещание из окна удаления
// сотрудника и абзац из docs/UI.md, а не наоборот.
var AuditKeptForever = []string{"сотрудник удалён"}

// PurgeAudit убирает рутину старше срока и возвращает число убранных строк.
func (db *DB) PurgeAudit(ctx context.Context, now time.Time) (int64, error) {
	args := []any{formatTime(now.Add(-AuditRetention))}
	holes := make([]string, 0, len(AuditKeptForever))
	for _, action := range AuditKeptForever {
		holes = append(holes, "?")
		args = append(args, action)
	}

	res, err := db.ExecContext(ctx,
		`DELETE FROM audit_log WHERE at < ? AND action NOT IN (`+strings.Join(holes, ", ")+`)`, args...)
	if err != nil {
		return 0, fmt.Errorf("почистить журнал: %w", err)
	}
	removed, _ := res.RowsAffected()
	return removed, nil
}
