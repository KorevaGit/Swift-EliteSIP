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

// EmployeeCard — сотрудник вместе с тем, что о нём спрашивают в списке.
//
// Всё, кроме имени предустановки, лежит в самой строке: номер стал полем, и
// джойн остался ровно один.
type EmployeeCard struct {
	model.Employee
	PresetName string
}

// EmployeeFilter — чем сужают список.
//
// Заведён сразу, а не когда станет тесно: главный экран панели — список людей,
// и на тридцати строках поиск уже нужен.
type EmployeeFilter struct {
	// Query ищет по имени и по номеру одновременно: администратор помнит либо
	// одно, либо другое, и заставлять его выбирать поле незачем.
	Query string

	// PresetID отбирает по предустановке. Пустое — все.
	PresetID *int64
}

// CreateEmployee заводит сотрудника целиком: имя, номер, SIP-пароль,
// предустановка.
//
// Одним действием, а не тремя сохранениями подряд: заведение стажёра —
// еженедельное дело, и каждый лишний шаг в нём оплачивается каждую неделю.
func (db *DB) CreateEmployee(ctx context.Context, actor *int64, e model.Employee) (model.Employee, error) {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return model.Employee{}, fmt.Errorf("завести сотрудника: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`INSERT INTO employees (name, number, sip_password, preset_id, created_at)
		 VALUES (?, ?, ?, ?, ?)`,
		e.Name, e.Number, e.SIPPassword, nullInt64(e.PresetID), formatTime(now))
	if err != nil {
		return model.Employee{}, wrapNumberConflict(err, fmt.Errorf("завести сотрудника %q: %w", e.Name, err))
	}
	id, err := res.LastInsertId()
	if err != nil {
		return model.Employee{}, fmt.Errorf("завести сотрудника %q: %w", e.Name, err)
	}

	// Пароль в журнал не идёт: журнал читают чаще, чем карточку, и секрет в
	// нём разошёлся бы по экранам и снимкам.
	if err := logAction(ctx, tx, now, actor, "сотрудник заведён", "employee", &id,
		describe(e.Name, e.Number)); err != nil {
		return model.Employee{}, err
	}
	if err := tx.Commit(); err != nil {
		return model.Employee{}, fmt.Errorf("завести сотрудника %q: %w", e.Name, err)
	}

	e.ID = id
	e.CreatedAt = now.UTC().Truncate(time.Second)
	return e, nil
}

// EmployeeByID возвращает сотрудника.
func (db *DB) EmployeeByID(ctx context.Context, id int64) (model.Employee, error) {
	var (
		e         model.Employee
		presetID  sql.NullInt64
		createdAt string
	)
	err := db.QueryRowContext(ctx,
		`SELECT id, name, number, sip_password, preset_id, created_at
		   FROM employees WHERE id = ?`, id).
		Scan(&e.ID, &e.Name, &e.Number, &e.SIPPassword, &presetID, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return model.Employee{}, ErrNotFound
	}
	if err != nil {
		return model.Employee{}, fmt.Errorf("прочитать сотрудника %d: %w", id, err)
	}
	e.PresetID = readNullInt64(presetID)
	e.CreatedAt = readTime(createdAt)
	return e, nil
}

// ListEmployees перечисляет сотрудников с их предустановками.
func (db *DB) ListEmployees(ctx context.Context, filter EmployeeFilter) ([]EmployeeCard, error) {
	query := `
		SELECT e.id, e.name, e.number, e.sip_password, e.preset_id, e.created_at,
		       COALESCE(p.name, '')
		  FROM employees e
		  LEFT JOIN presets p ON p.id = e.preset_id`

	var (
		where []string
		args  []any
	)
	if q := strings.TrimSpace(filter.Query); q != "" {
		// Поиск подстрокой, а не с начала: людей ищут по фамилии, а она стоит
		// второй. LIKE без ESCAPE хватает — % и _ в имени и номере не бывает.
		where = append(where, `(e.name LIKE ? OR e.number LIKE ?)`)
		args = append(args, "%"+q+"%", "%"+q+"%")
	}
	if filter.PresetID != nil {
		where = append(where, `e.preset_id = ?`)
		args = append(args, *filter.PresetID)
	}
	if len(where) > 0 {
		query += ` WHERE ` + strings.Join(where, ` AND `)
	}
	query += ` ORDER BY e.name`

	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("перечислить сотрудников: %w", err)
	}
	defer rows.Close()

	var out []EmployeeCard
	for rows.Next() {
		var (
			c         EmployeeCard
			presetID  sql.NullInt64
			createdAt string
		)
		if err := rows.Scan(&c.ID, &c.Name, &c.Number, &c.SIPPassword,
			&presetID, &createdAt, &c.PresetName); err != nil {
			return nil, fmt.Errorf("прочитать строку сотрудника: %w", err)
		}
		c.PresetID = readNullInt64(presetID)
		c.CreatedAt = readTime(createdAt)
		out = append(out, c)
	}
	return out, rows.Err()
}

// UpdateEmployee сохраняет карточку целиком.
//
// Целиком, а не полями по одному: карточку правят редко, зато сразу — человек
// переехал на другой номер и заодно сменил предустановку. Три отдельных
// сохранения на одном экране — это три способа уйти, сохранив половину.
func (db *DB) UpdateEmployee(ctx context.Context, actor *int64, e model.Employee) error {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("сохранить сотрудника: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`UPDATE employees SET name = ?, number = ?, sip_password = ?, preset_id = ?
		  WHERE id = ?`,
		e.Name, e.Number, e.SIPPassword, nullInt64(e.PresetID), e.ID)
	if err != nil {
		return wrapNumberConflict(err, fmt.Errorf("сохранить сотрудника %d: %w", e.ID, err))
	}
	if affected, _ := res.RowsAffected(); affected == 0 {
		return ErrNotFound
	}

	if err := logAction(ctx, tx, now, actor, "карточка изменена", "employee", &e.ID,
		describe(e.Name, e.Number)); err != nil {
		return err
	}
	return tx.Commit()
}

// DeleteEmployee стирает сотрудника целиком.
//
// Вместо увольнения: гашение оставляло бы карточку с номером и SIP-паролем в
// базе навсегда, а нужна она ровно до конца испытательного срока стажёра —
// решение 24 августа 2026, docs/UI.md.
//
// Активации и отметки о связи уходят каскадом. Единственное, что переживает
// удаление, — строка журнала с именем и номером: именно на неё опирается
// разбор жалобы через неделю после ухода человека, и CDR на АТС на это не
// отвечает — там только номер.
//
// Панель при этом ничего не делает с АТС. Пока пароль пира там не сменят,
// машина продолжает регистрироваться, и напомнить об этом — забота интерфейса.
func (db *DB) DeleteEmployee(ctx context.Context, actor *int64, id int64) error {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("удалить сотрудника: %w", err)
	}
	defer tx.Rollback()

	// Имя и номер читаются до удаления: после него их взять неоткуда, а без
	// них строка журнала не отвечает ни на один вопрос, ради которого заведена.
	var name, number string
	err = tx.QueryRowContext(ctx, `SELECT name, number FROM employees WHERE id = ?`, id).
		Scan(&name, &number)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("прочитать сотрудника %d: %w", id, err)
	}

	if _, err := tx.ExecContext(ctx, `DELETE FROM employees WHERE id = ?`, id); err != nil {
		return fmt.Errorf("удалить сотрудника %d: %w", id, err)
	}

	// entity_id не ставится: строки, на которую он бы указывал, больше нет, и
	// ссылка вела бы в ничто.
	if err := logAction(ctx, tx, now, actor, "сотрудник удалён", "employee", nil,
		describe(name, number)); err != nil {
		return err
	}
	return tx.Commit()
}

// describe собирает то, что остаётся в журнале от карточки.
func describe(name, number string) string {
	if number == "" {
		return name
	}
	return name + ", номер " + number
}

// wrapNumberConflict отличает занятый номер от прочих отказов базы.
//
// Отдельной ошибкой, потому что разбирается он не так, как опечатка в форме:
// за занятым номером стоит живой человек, который прямо сейчас снимает по нему
// звонки.
//
// Разбором текста, потому что modernc.org/sqlite не даёт типизированной ошибки
// с именем нарушенного ограничения. Текст закреплён проверкой рядом —
// TestNumberIsTakenByOneEmployee: сменится он при обновлении драйвера, и она
// это поймает.
func wrapNumberConflict(err error, fallback error) error {
	if strings.Contains(err.Error(), "UNIQUE constraint failed: employees.number") {
		return ErrNumberTaken
	}
	return fallback
}
