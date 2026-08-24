package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
)

// NumberWithHolder — номер и тот, за кем он закреплён сейчас.
//
// Список номеров без владельца отвечает на «какие номера у нас есть», но не на
// «свободен ли этот» — а спрашивают именно второе, потому что номер выдают.
type NumberWithHolder struct {
	// Поля номера перечислены, а не получены встраиванием model.Number: имя
	// встроенного поля совпало бы с именем типа, и обращение к самому номеру
	// читалось бы как n.Number.Number.
	ID          int64
	Number      string
	SIPPassword string
	Label       string
	CreatedAt   time.Time
	RetiredAt   *time.Time

	HolderID   *int64
	HolderName string
}

// CreateNumber заводит номер.
//
// Номера и SIP-пароли вбиваются руками: импорта из FreePBX нет — решение
// 24 августа 2026.
func (db *DB) CreateNumber(ctx context.Context, actor *int64, number, sipPassword, label string) (model.Number, error) {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return model.Number{}, fmt.Errorf("завести номер: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`INSERT INTO numbers (number, sip_password, label, created_at) VALUES (?, ?, ?, ?)`,
		number, sipPassword, label, formatTime(now))
	if err != nil {
		return model.Number{}, fmt.Errorf("завести номер %s: %w", number, err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return model.Number{}, fmt.Errorf("завести номер %s: %w", number, err)
	}

	// Пароль в журнал не идёт: журнал читают чаще, чем карточку номера, и
	// секрет в нём разошёлся бы по экранам и снимкам.
	if err := logAction(ctx, tx, now, actor, "номер заведён", "number", &id, number); err != nil {
		return model.Number{}, err
	}
	if err := tx.Commit(); err != nil {
		return model.Number{}, fmt.Errorf("завести номер %s: %w", number, err)
	}

	return model.Number{
		ID: id, Number: number, SIPPassword: sipPassword, Label: label,
		CreatedAt: now.UTC().Truncate(time.Second),
	}, nil
}

// NumberByID возвращает номер вместе с паролем.
func (db *DB) NumberByID(ctx context.Context, id int64) (model.Number, error) {
	var (
		n         model.Number
		createdAt string
		retiredAt sql.NullString
	)
	err := db.QueryRowContext(ctx,
		`SELECT id, number, sip_password, label, created_at, retired_at FROM numbers WHERE id = ?`, id).
		Scan(&n.ID, &n.Number, &n.SIPPassword, &n.Label, &createdAt, &retiredAt)
	if errors.Is(err, sql.ErrNoRows) {
		return model.Number{}, ErrNotFound
	}
	if err != nil {
		return model.Number{}, fmt.Errorf("прочитать номер %d: %w", id, err)
	}
	n.CreatedAt = readTime(createdAt)
	n.RetiredAt = readNullTime(retiredAt)
	return n, nil
}

// ListNumbers перечисляет номера вместе с действующими владельцами.
func (db *DB) ListNumbers(ctx context.Context, includeRetired bool) ([]NumberWithHolder, error) {
	query := `
		SELECT n.id, n.number, n.sip_password, n.label, n.created_at, n.retired_at,
		       e.id, COALESCE(e.name, '')
		  FROM numbers n
		  LEFT JOIN number_assignments a
		         ON a.number_id = n.id AND a.released_at IS NULL
		  LEFT JOIN employees e ON e.id = a.employee_id`
	if !includeRetired {
		query += ` WHERE n.retired_at IS NULL`
	}
	query += ` ORDER BY n.number`

	rows, err := db.QueryContext(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("перечислить номера: %w", err)
	}
	defer rows.Close()

	var out []NumberWithHolder
	for rows.Next() {
		var (
			n         NumberWithHolder
			createdAt string
			retiredAt sql.NullString
			holderID  sql.NullInt64
		)
		if err := rows.Scan(&n.ID, &n.Number, &n.SIPPassword, &n.Label,
			&createdAt, &retiredAt, &holderID, &n.HolderName); err != nil {
			return nil, fmt.Errorf("прочитать строку номера: %w", err)
		}
		n.CreatedAt = readTime(createdAt)
		n.RetiredAt = readNullTime(retiredAt)
		n.HolderID = readNullInt64(holderID)
		out = append(out, n)
	}
	return out, rows.Err()
}

// SetNumberPassword меняет SIP-пароль номера.
//
// Отдельным действием, а не общей правкой карточки: смена пароля пира — это
// единственный механизм отзыва доступа, и в журнале она должна стоять
// отдельной строкой, по которой видно, когда уволенного действительно
// отключили от АТС.
//
// Панель при этом ничего не меняет на самой АТС — там пароль меняют руками.
// Здесь записывается новый, чтобы следующая активация выдала машине рабочий.
func (db *DB) SetNumberPassword(ctx context.Context, actor *int64, id int64, sipPassword string) error {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("сменить пароль номера: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx, `UPDATE numbers SET sip_password = ? WHERE id = ?`, sipPassword, id)
	if err != nil {
		return fmt.Errorf("сменить пароль номера %d: %w", id, err)
	}
	if affected, _ := res.RowsAffected(); affected == 0 {
		return ErrNotFound
	}
	if err := logAction(ctx, tx, now, actor, "пароль номера сменён", "number", &id, ""); err != nil {
		return err
	}
	return tx.Commit()
}

// RetireNumber выводит номер из обращения и освобождает его.
func (db *DB) RetireNumber(ctx context.Context, actor *int64, id int64) error {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("вывести номер из обращения: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`UPDATE numbers SET retired_at = ? WHERE id = ? AND retired_at IS NULL`, formatTime(now), id)
	if err != nil {
		return fmt.Errorf("вывести номер %d из обращения: %w", id, err)
	}
	if affected, _ := res.RowsAffected(); affected == 0 {
		return ErrNotFound
	}

	if _, err := tx.ExecContext(ctx,
		`UPDATE number_assignments SET released_at = ? WHERE number_id = ? AND released_at IS NULL`,
		formatTime(now), id); err != nil {
		return fmt.Errorf("освободить номер %d: %w", id, err)
	}

	if err := logAction(ctx, tx, now, actor, "номер выведен из обращения", "number", &id, ""); err != nil {
		return err
	}
	return tx.Commit()
}
