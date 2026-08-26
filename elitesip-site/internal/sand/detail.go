package sand

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

var (
	ErrClosed       = errors.New("закрытый песок менять нельзя")
	ErrUnknownTask  = errors.New("такой работы нет в шаблоне песка")
	ErrTaskBlocked  = errors.New("сначала выполните работы, от которых зависит эта")
	ErrTaskRequired = errors.New("сначала снимите зависящие от этой отметки")
	ErrEmptyComment = errors.New("комментарий не может быть пустым")
)

const maxCommentLength = 4000

// Mark — выполненная работа с неизменяемым снимком исполнителя.
type Mark struct {
	Task      string
	DoneAt    time.Time
	DoneBy    int64
	DoneLogin string
}

// EmployeeRow — сотрудник в таблице карточки песка.
type EmployeeRow struct {
	ID       int64
	Name     string
	Outcome  Outcome
	Progress []SectionProgress
}

// Comment — одна запись общего обсуждения песка.
type Comment struct {
	ID          int64
	AuthorID    int64
	AuthorLogin string
	CreatedAt   time.Time
	Text        string
}

// SandboxDetail — всё, что нужно составному экрану песка.
type SandboxDetail struct {
	Sandbox
	Status Status

	Tasks     []Task
	Marks     map[string]Mark
	Progress  []SectionProgress
	Employees []EmployeeRow
	Comments  []Comment

	ExtensionsTotal int
	ExtensionsFree  int
	DealsTotal      int
	DealsFree       int
}

// GetSandbox собирает карточку несколькими плоскими запросами. В базе один
// writer и одно соединение, поэтому каждый rows закрывается до следующего.
func (db *DB) GetSandbox(ctx context.Context, id int64) (SandboxDetail, error) {
	var (
		detail    SandboxDetail
		format    string
		createdAt string
		closedAt  sql.NullString
		closedBy  sql.NullInt64
	)
	err := db.QueryRowContext(ctx,
		`SELECT id, rop, format, created_at, closed_at, closed_by
		   FROM sandboxes WHERE id = ?`, id).
		Scan(&detail.ID, &detail.ROP, &format, &createdAt, &closedAt, &closedBy)
	if errors.Is(err, sql.ErrNoRows) {
		return SandboxDetail{}, ErrNotFound
	}
	if err != nil {
		return SandboxDetail{}, fmt.Errorf("прочитать песок: %w", err)
	}
	detail.Format = Format(format)
	detail.CreatedAt, err = readTime(createdAt)
	if err != nil {
		return SandboxDetail{}, err
	}
	if closedAt.Valid {
		at, err := readTime(closedAt.String)
		if err != nil {
			return SandboxDetail{}, err
		}
		detail.ClosedAt = &at
	}
	detail.ClosedBy = readNullInt64(closedBy)
	detail.Tasks = SandboxTasks(detail.Format)

	detail.Marks, err = db.sandboxMarks(ctx, id)
	if err != nil {
		return SandboxDetail{}, err
	}
	detail.Employees, err = db.sandboxEmployees(ctx, id, detail.Format)
	if err != nil {
		return SandboxDetail{}, err
	}
	detail.Comments, err = db.sandboxComments(ctx, id)
	if err != nil {
		return SandboxDetail{}, err
	}
	if err := db.QueryRowContext(ctx,
		`SELECT COUNT(*),
		        COALESCE(SUM(CASE WHEN employee_id IS NULL AND released_at IS NULL THEN 1 ELSE 0 END), 0)
		   FROM sandbox_extensions WHERE sandbox_id = ?`, id).
		Scan(&detail.ExtensionsTotal, &detail.ExtensionsFree); err != nil {
		return SandboxDetail{}, fmt.Errorf("посчитать номера песка: %w", err)
	}
	if err := db.QueryRowContext(ctx,
		`SELECT COUNT(*), COALESCE(SUM(CASE WHEN employee_id IS NULL THEN 1 ELSE 0 END), 0)
		   FROM sandbox_deals WHERE sandbox_id = ?`, id).
		Scan(&detail.DealsTotal, &detail.DealsFree); err != nil {
		return SandboxDetail{}, fmt.Errorf("посчитать сделки песка: %w", err)
	}

	done := make(map[string]bool, len(detail.Marks))
	for key := range detail.Marks {
		done[key] = true
	}
	detail.Progress = Progress(detail.Tasks, done)
	for _, employee := range detail.Employees {
		for _, employeeProgress := range employee.Progress {
			for i := range detail.Progress {
				if detail.Progress[i].Section == employeeProgress.Section {
					detail.Progress[i].Done += employeeProgress.Done
					detail.Progress[i].Total += employeeProgress.Total
					goto nextEmployeeSection
				}
			}
			detail.Progress = append(detail.Progress, employeeProgress)
		nextEmployeeSection:
		}
	}
	detail.Status = detailStatus(detail)
	return detail, nil
}

func (db *DB) sandboxMarks(ctx context.Context, id int64) (map[string]Mark, error) {
	rows, err := db.QueryContext(ctx,
		`SELECT task, done_at, done_by, done_login
		   FROM sandbox_marks WHERE sandbox_id = ?`, id)
	if err != nil {
		return nil, fmt.Errorf("прочитать работы песка: %w", err)
	}
	defer rows.Close()

	marks := map[string]Mark{}
	for rows.Next() {
		var mark Mark
		var doneAt string
		if err := rows.Scan(&mark.Task, &doneAt, &mark.DoneBy, &mark.DoneLogin); err != nil {
			return nil, fmt.Errorf("прочитать работу песка: %w", err)
		}
		mark.DoneAt, err = readTime(doneAt)
		if err != nil {
			return nil, err
		}
		marks[mark.Task] = mark
	}
	return marks, rows.Err()
}

func (db *DB) sandboxEmployees(ctx context.Context, sandboxID int64, format Format) ([]EmployeeRow, error) {
	rows, err := db.QueryContext(ctx,
		`SELECT e.id, e.name, COALESCE(e.outcome, ''),
		        CASE WHEN COALESCE(e.bitrix_login, '') <> ''
		                   AND COALESCE(e.bitrix_pass, '') <> ''
		                   AND COALESCE(e.bitrix_id, '') <> '' THEN 1 ELSE 0 END,
		        CASE WHEN x.number IS NOT NULL THEN 1 ELSE 0 END
		   FROM sand_employees e
		   LEFT JOIN sandbox_extensions x
		          ON x.employee_id = e.id AND x.released_at IS NULL
		  WHERE e.sandbox_id = ?
		  ORDER BY e.id`, sandboxID)
	if err != nil {
		return nil, fmt.Errorf("прочитать сотрудников песка: %w", err)
	}

	var employees []EmployeeRow
	structured := map[int64]map[string]bool{}
	for rows.Next() {
		var employee EmployeeRow
		var outcome string
		var bitrix, extension bool
		if err := rows.Scan(&employee.ID, &employee.Name, &outcome, &bitrix, &extension); err != nil {
			rows.Close()
			return nil, fmt.Errorf("прочитать сотрудника песка: %w", err)
		}
		employee.Outcome = Outcome(outcome)
		structured[employee.ID] = map[string]bool{
			"bitrix": bitrix, "extension": extension, "outcome": outcome != "",
		}
		employees = append(employees, employee)
	}
	if err := rows.Close(); err != nil {
		return nil, fmt.Errorf("закрыть список сотрудников: %w", err)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("прочитать сотрудников песка: %w", err)
	}

	manual := map[int64]map[string]bool{}
	markRows, err := db.QueryContext(ctx,
		`SELECT m.employee_id, m.task
		   FROM employee_marks m
		   JOIN sand_employees e ON e.id = m.employee_id
		  WHERE e.sandbox_id = ?`, sandboxID)
	if err != nil {
		return nil, fmt.Errorf("прочитать работы сотрудников: %w", err)
	}
	for markRows.Next() {
		var employeeID int64
		var task string
		if err := markRows.Scan(&employeeID, &task); err != nil {
			markRows.Close()
			return nil, fmt.Errorf("прочитать работу сотрудника: %w", err)
		}
		if manual[employeeID] == nil {
			manual[employeeID] = map[string]bool{}
		}
		manual[employeeID][task] = true
	}
	if err := markRows.Close(); err != nil {
		return nil, fmt.Errorf("закрыть работы сотрудников: %w", err)
	}
	if err := markRows.Err(); err != nil {
		return nil, fmt.Errorf("прочитать работы сотрудников: %w", err)
	}

	for i := range employees {
		done := manual[employees[i].ID]
		if done == nil {
			done = map[string]bool{}
		}
		for key, value := range structured[employees[i].ID] {
			done[key] = value
		}
		employees[i].Progress = Progress(EmployeeTasksFor(format, employees[i].Outcome), done)
	}
	return employees, nil
}

func (db *DB) sandboxComments(ctx context.Context, sandboxID int64) ([]Comment, error) {
	rows, err := db.QueryContext(ctx,
		`SELECT id, author_id, author_login, created_at, text
		   FROM sandbox_comments WHERE sandbox_id = ? ORDER BY id DESC`, sandboxID)
	if err != nil {
		return nil, fmt.Errorf("прочитать комментарии песка: %w", err)
	}
	defer rows.Close()

	var comments []Comment
	for rows.Next() {
		var comment Comment
		var createdAt string
		if err := rows.Scan(&comment.ID, &comment.AuthorID, &comment.AuthorLogin, &createdAt, &comment.Text); err != nil {
			return nil, fmt.Errorf("прочитать комментарий песка: %w", err)
		}
		comment.CreatedAt, err = readTime(createdAt)
		if err != nil {
			return nil, err
		}
		comments = append(comments, comment)
	}
	return comments, rows.Err()
}

func detailStatus(detail SandboxDetail) Status {
	// Список считает по ключам для многих песков сразу; карточке надёжнее
	// сложить уже собранные прогрессы своего песка и людей.
	if detail.ClosedAt != nil {
		return StatusClosed
	}
	total, done := 0, 0
	for _, p := range detail.Progress {
		total, done = total+p.Total, done+p.Done
	}
	if total > 0 && total == done {
		return StatusDone
	}
	if done > 0 {
		return StatusRunning
	}
	return StatusStarted
}

// ToggleSandboxMark переключает общую работу, сохраняя зависимости и аудит.
func (db *DB) ToggleSandboxMark(ctx context.Context, actor Actor, sandboxID int64, key string) (bool, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return false, fmt.Errorf("переключить работу песка: %w", err)
	}
	defer tx.Rollback()

	format, err := openSandboxFormat(ctx, tx, sandboxID)
	if err != nil {
		return false, err
	}
	tasks := SandboxTasks(format)
	task, ok := TaskByKey(tasks, key)
	if !ok {
		return false, ErrUnknownTask
	}

	var exists int
	err = tx.QueryRowContext(ctx,
		`SELECT 1 FROM sandbox_marks WHERE sandbox_id = ? AND task = ?`, sandboxID, key).Scan(&exists)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, fmt.Errorf("проверить работу песка: %w", err)
	}
	now := time.Now()
	marked := errors.Is(err, sql.ErrNoRows)
	if marked {
		for _, need := range task.Needs {
			var present int
			if err := tx.QueryRowContext(ctx,
				`SELECT 1 FROM sandbox_marks WHERE sandbox_id = ? AND task = ?`, sandboxID, need).
				Scan(&present); errors.Is(err, sql.ErrNoRows) {
				return false, ErrTaskBlocked
			} else if err != nil {
				return false, fmt.Errorf("проверить зависимость работы: %w", err)
			}
		}
		_, err = tx.ExecContext(ctx,
			`INSERT INTO sandbox_marks (sandbox_id, task, done_at, done_by, done_login)
			 VALUES (?, ?, ?, ?, ?)`, sandboxID, key, formatTime(now), actor.ID, actor.Login)
	} else {
		for _, candidate := range tasks {
			if !contains(candidate.Needs, key) {
				continue
			}
			var present int
			if err := tx.QueryRowContext(ctx,
				`SELECT 1 FROM sandbox_marks WHERE sandbox_id = ? AND task = ?`, sandboxID, candidate.Key).
				Scan(&present); err == nil {
				return false, ErrTaskRequired
			} else if !errors.Is(err, sql.ErrNoRows) {
				return false, fmt.Errorf("проверить зависимую работу: %w", err)
			}
		}
		_, err = tx.ExecContext(ctx,
			`DELETE FROM sandbox_marks WHERE sandbox_id = ? AND task = ?`, sandboxID, key)
	}
	if err != nil {
		return false, fmt.Errorf("переключить работу %q: %w", key, err)
	}

	action := "sandbox.unmark"
	if marked {
		action = "sandbox.mark"
	}
	if _, err := QueueAudit(ctx, tx, AuditEvent{
		At: now, ActorID: &actor.ID, ActorLogin: actor.Login,
		Action: action, Entity: "sandbox", EntityID: &sandboxID,
		Details: task.Title,
	}); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("сохранить работу песка: %w", err)
	}
	return marked, nil
}

// AddSandboxEmployee добавляет человека в незакрытый песок.
func (db *DB) AddSandboxEmployee(ctx context.Context, actor Actor, sandboxID int64, name string) (int64, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return 0, ErrNoEmployees
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("добавить сотрудника: %w", err)
	}
	defer tx.Rollback()
	if _, err := openSandboxFormat(ctx, tx, sandboxID); err != nil {
		return 0, err
	}
	res, err := tx.ExecContext(ctx,
		`INSERT INTO sand_employees (sandbox_id, name) VALUES (?, ?)`, sandboxID, name)
	if err != nil {
		return 0, fmt.Errorf("добавить сотрудника %q: %w", name, err)
	}
	id, _ := res.LastInsertId()
	if _, err := QueueAudit(ctx, tx, AuditEvent{
		At: time.Now(), ActorID: &actor.ID, ActorLogin: actor.Login,
		Action: "employee.create", Entity: "sand_employee", EntityID: &id,
		Details: name,
	}); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("сохранить сотрудника %q: %w", name, err)
	}
	return id, nil
}

// AddSandboxComment дописывает неизменяемый комментарий в общий пул.
func (db *DB) AddSandboxComment(ctx context.Context, actor Actor, sandboxID int64, text string) error {
	text = strings.TrimSpace(text)
	if text == "" {
		return ErrEmptyComment
	}
	if len([]rune(text)) > maxCommentLength {
		return fmt.Errorf("комментарий длиннее %d знаков", maxCommentLength)
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("добавить комментарий: %w", err)
	}
	defer tx.Rollback()
	if _, err := openSandboxFormat(ctx, tx, sandboxID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sandbox_comments (sandbox_id, author_id, author_login, created_at, text)
		 VALUES (?, ?, ?, ?, ?)`, sandboxID, actor.ID, actor.Login, formatTime(time.Now()), text); err != nil {
		return fmt.Errorf("добавить комментарий: %w", err)
	}
	return tx.Commit()
}

// CloseSandbox закрывает песок и освобождает его пул номеров.
func (db *DB) CloseSandbox(ctx context.Context, actor Actor, sandboxID int64) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("закрыть песок: %w", err)
	}
	defer tx.Rollback()
	if _, err := openSandboxFormat(ctx, tx, sandboxID); err != nil {
		return err
	}
	now := time.Now()
	res, err := tx.ExecContext(ctx,
		`UPDATE sandboxes SET closed_at = ?, closed_by = ? WHERE id = ? AND closed_at IS NULL`,
		formatTime(now), actor.ID, sandboxID)
	if err != nil {
		return fmt.Errorf("закрыть песок: %w", err)
	}
	changed, _ := res.RowsAffected()
	if changed != 1 {
		return ErrClosed
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE sandbox_extensions SET released_at = ?
		  WHERE sandbox_id = ? AND released_at IS NULL`, formatTime(now), sandboxID); err != nil {
		return fmt.Errorf("освободить номера песка: %w", err)
	}
	if _, err := QueueAudit(ctx, tx, AuditEvent{
		At: now, ActorID: &actor.ID, ActorLogin: actor.Login,
		Action: "sandbox.close", Entity: "sandbox", EntityID: &sandboxID,
		Details: "песок закрыт администратором",
	}); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("сохранить закрытие песка: %w", err)
	}
	return nil
}

func openSandboxFormat(ctx context.Context, tx *sql.Tx, sandboxID int64) (Format, error) {
	var format string
	var closedAt sql.NullString
	err := tx.QueryRowContext(ctx,
		`SELECT format, closed_at FROM sandboxes WHERE id = ?`, sandboxID).Scan(&format, &closedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", fmt.Errorf("прочитать песок: %w", err)
	}
	if closedAt.Valid {
		return "", ErrClosed
	}
	return Format(format), nil
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
