package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
)

// EmployeeCard — сотрудник вместе с тем, что о нём спрашивают в списке.
type EmployeeCard struct {
	model.Employee
	NumberID   *int64
	Number     string
	PresetName string
}

// CreateEmployee заводит сотрудника.
func (db *DB) CreateEmployee(ctx context.Context, actor *int64, name string, presetID *int64) (model.Employee, error) {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return model.Employee{}, fmt.Errorf("завести сотрудника: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`INSERT INTO employees (name, preset_id, created_at) VALUES (?, ?, ?)`,
		name, nullInt64(presetID), formatTime(now))
	if err != nil {
		return model.Employee{}, fmt.Errorf("завести сотрудника %q: %w", name, err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return model.Employee{}, fmt.Errorf("завести сотрудника %q: %w", name, err)
	}
	if err := logAction(ctx, tx, now, actor, "сотрудник заведён", "employee", &id, name); err != nil {
		return model.Employee{}, err
	}
	if err := tx.Commit(); err != nil {
		return model.Employee{}, fmt.Errorf("завести сотрудника %q: %w", name, err)
	}

	return model.Employee{
		ID: id, Name: name, PresetID: presetID,
		CreatedAt: now.UTC().Truncate(time.Second),
	}, nil
}

// EmployeeByID возвращает сотрудника.
func (db *DB) EmployeeByID(ctx context.Context, id int64) (model.Employee, error) {
	var (
		e           model.Employee
		presetID    sql.NullInt64
		createdAt   string
		dismissedAt sql.NullString
	)
	err := db.QueryRowContext(ctx,
		`SELECT id, name, preset_id, created_at, dismissed_at FROM employees WHERE id = ?`, id).
		Scan(&e.ID, &e.Name, &presetID, &createdAt, &dismissedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return model.Employee{}, ErrNotFound
	}
	if err != nil {
		return model.Employee{}, fmt.Errorf("прочитать сотрудника %d: %w", id, err)
	}
	e.PresetID = readNullInt64(presetID)
	e.CreatedAt = readTime(createdAt)
	e.DismissedAt = readNullTime(dismissedAt)
	return e, nil
}

// ListEmployees перечисляет сотрудников с их номерами и предустановками.
func (db *DB) ListEmployees(ctx context.Context, includeDismissed bool) ([]EmployeeCard, error) {
	query := `
		SELECT e.id, e.name, e.preset_id, e.created_at, e.dismissed_at,
		       n.id, COALESCE(n.number, ''), COALESCE(p.name, '')
		  FROM employees e
		  LEFT JOIN number_assignments a
		         ON a.employee_id = e.id AND a.released_at IS NULL
		  LEFT JOIN numbers n ON n.id = a.number_id
		  LEFT JOIN presets p ON p.id = e.preset_id`
	if !includeDismissed {
		query += ` WHERE e.dismissed_at IS NULL`
	}
	query += ` ORDER BY e.name`

	rows, err := db.QueryContext(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("перечислить сотрудников: %w", err)
	}
	defer rows.Close()

	var out []EmployeeCard
	for rows.Next() {
		var (
			c           EmployeeCard
			presetID    sql.NullInt64
			createdAt   string
			dismissedAt sql.NullString
			numberID    sql.NullInt64
		)
		if err := rows.Scan(&c.ID, &c.Name, &presetID, &createdAt, &dismissedAt,
			&numberID, &c.Number, &c.PresetName); err != nil {
			return nil, fmt.Errorf("прочитать строку сотрудника: %w", err)
		}
		c.PresetID = readNullInt64(presetID)
		c.CreatedAt = readTime(createdAt)
		c.DismissedAt = readNullTime(dismissedAt)
		c.NumberID = readNullInt64(numberID)
		out = append(out, c)
	}
	return out, rows.Err()
}

// AssignNumber закрепляет номер за сотрудником.
//
// Прежний номер сотрудника освобождается сам — это пересадка, обычное дело.
// А вот занятый номер отдаётся отказом, а не молчаливым отбором: за ним стоит
// живой человек, который прямо сейчас снимает по нему звонки.
func (db *DB) AssignNumber(ctx context.Context, actor *int64, employeeID, numberID int64) error {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("закрепить номер: %w", err)
	}
	defer tx.Rollback()

	var dismissedAt sql.NullString
	err = tx.QueryRowContext(ctx, `SELECT dismissed_at FROM employees WHERE id = ?`, employeeID).Scan(&dismissedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("прочитать сотрудника %d: %w", employeeID, err)
	}
	if dismissedAt.Valid {
		return ErrEmployeeDismissed
	}

	var (
		number    string
		retiredAt sql.NullString
	)
	err = tx.QueryRowContext(ctx, `SELECT number, retired_at FROM numbers WHERE id = ?`, numberID).
		Scan(&number, &retiredAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("прочитать номер %d: %w", numberID, err)
	}
	if retiredAt.Valid {
		return ErrNumberRetired
	}

	var holder int64
	err = tx.QueryRowContext(ctx,
		`SELECT employee_id FROM number_assignments WHERE number_id = ? AND released_at IS NULL`, numberID).
		Scan(&holder)
	switch {
	case err == nil && holder == employeeID:
		// Уже закреплён за ним же — делать нечего, и это не ошибка.
		return tx.Commit()
	case err == nil:
		return ErrNumberTaken
	case !errors.Is(err, sql.ErrNoRows):
		return fmt.Errorf("проверить занятость номера %d: %w", numberID, err)
	}

	if _, err := tx.ExecContext(ctx,
		`UPDATE number_assignments SET released_at = ? WHERE employee_id = ? AND released_at IS NULL`,
		formatTime(now), employeeID); err != nil {
		return fmt.Errorf("освободить прежний номер сотрудника %d: %w", employeeID, err)
	}

	if _, err := tx.ExecContext(ctx,
		`INSERT INTO number_assignments (number_id, employee_id, assigned_at) VALUES (?, ?, ?)`,
		numberID, employeeID, formatTime(now)); err != nil {
		return fmt.Errorf("закрепить номер %d за сотрудником %d: %w", numberID, employeeID, err)
	}

	if err := logAction(ctx, tx, now, actor, "номер закреплён", "employee", &employeeID, number); err != nil {
		return err
	}
	return tx.Commit()
}

// ReleaseNumber снимает с сотрудника его номер.
func (db *DB) ReleaseNumber(ctx context.Context, actor *int64, employeeID int64) error {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("освободить номер: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`UPDATE number_assignments SET released_at = ? WHERE employee_id = ? AND released_at IS NULL`,
		formatTime(now), employeeID)
	if err != nil {
		return fmt.Errorf("освободить номер сотрудника %d: %w", employeeID, err)
	}
	if affected, _ := res.RowsAffected(); affected == 0 {
		return ErrNotFound
	}
	if err := logAction(ctx, tx, now, actor, "номер освобождён", "employee", &employeeID, ""); err != nil {
		return err
	}
	return tx.Commit()
}

// DismissEmployee увольняет сотрудника.
//
// Одним действием: номер освобождается, все его активации отзываются. Порознь
// это три разных дела, о двух из которых в спешке забывают, — а забытая
// активация означает машину, которая продолжает регистрироваться.
//
// Отзыв здесь — учётная запись, а не техническое действие: приложение после
// активации к панели не ходит. Машину останавливает смена SIP-пароля пира на
// АТС, и напоминание об этом — забота интерфейса.
func (db *DB) DismissEmployee(ctx context.Context, actor *int64, employeeID int64) error {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("уволить сотрудника: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`UPDATE employees SET dismissed_at = ? WHERE id = ? AND dismissed_at IS NULL`,
		formatTime(now), employeeID)
	if err != nil {
		return fmt.Errorf("уволить сотрудника %d: %w", employeeID, err)
	}
	if affected, _ := res.RowsAffected(); affected == 0 {
		return ErrNotFound
	}

	if _, err := tx.ExecContext(ctx,
		`UPDATE number_assignments SET released_at = ? WHERE employee_id = ? AND released_at IS NULL`,
		formatTime(now), employeeID); err != nil {
		return fmt.Errorf("освободить номер сотрудника %d: %w", employeeID, err)
	}

	if _, err := tx.ExecContext(ctx,
		`UPDATE activations SET revoked_at = ? WHERE employee_id = ? AND revoked_at IS NULL`,
		formatTime(now), employeeID); err != nil {
		return fmt.Errorf("отозвать активации сотрудника %d: %w", employeeID, err)
	}

	if err := logAction(ctx, tx, now, actor, "сотрудник уволен", "employee", &employeeID, ""); err != nil {
		return err
	}
	return tx.Commit()
}
