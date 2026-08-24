package storage

import (
	"context"
	"fmt"
	"time"
)

// Overview — то, что видно на первом экране после входа.
//
// Считается одним походом в базу, а не пятью из шаблона: экран открывают
// каждый раз при входе, и пять отдельных запросов из разметки — верный способ
// однажды не заметить шестой.
type Overview struct {
	Employees int

	// Machines — активации, которые не отозваны. Панель узнаёт о живых машинах
	// только из журнала раздачи, а его пока нет (этап 5), поэтому здесь именно
	// выданные ключи, а не подтверждённые рабочие места. Разница честно
	// написана рядом на экране.
	Machines int

	Loose []LooseEnd
}

// LooseEnd — незакрытое дело со ссылкой на то место, где оно чинится.
//
// Ссылка обязательна: хвост без неё сообщает о беде и оставляет искать, где её
// править, — а панель открывает человек, который её устройства не знает.
type LooseEnd struct {
	Kind  string // preset, key, employee
	Text  string
	Href  string
	Since time.Time
}

// Overview собирает первый экран.
func (db *DB) Overview(ctx context.Context, now time.Time) (Overview, error) {
	var o Overview

	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM employees`).Scan(&o.Employees); err != nil {
		return Overview{}, fmt.Errorf("посчитать сотрудников: %w", err)
	}
	if err := db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM activations WHERE revoked_at IS NULL`).Scan(&o.Machines); err != nil {
		return Overview{}, fmt.Errorf("посчитать машины: %w", err)
	}

	for _, collect := range []func(context.Context, time.Time) ([]LooseEnd, error){
		db.unpublishedRevisions,
		db.pendingKeys,
		db.incompleteEmployees,
	} {
		ends, err := collect(ctx, now)
		if err != nil {
			return Overview{}, err
		}
		o.Loose = append(o.Loose, ends...)
	}
	return o, nil
}

// unpublishedRevisions — ревизия сохранена, но наружу не уехала.
//
// Самый дорогой из хвостов: правка сделана, администратор считает дело
// закрытым, а на машинах по-прежнему прежнее.
func (db *DB) unpublishedRevisions(ctx context.Context, _ time.Time) ([]LooseEnd, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT p.id, p.name, r.revision, r.created_at
		  FROM presets p
		  JOIN preset_revisions r ON r.preset_id = p.id
		 WHERE p.archived_at IS NULL
		   AND r.published_at IS NULL
		   AND r.revision = (SELECT MAX(revision) FROM preset_revisions WHERE preset_id = p.id)
		 ORDER BY r.created_at`)
	if err != nil {
		return nil, fmt.Errorf("найти невыложенные ревизии: %w", err)
	}
	defer rows.Close()

	var out []LooseEnd
	for rows.Next() {
		var (
			id        int64
			name      string
			revision  int
			createdAt string
		)
		if err := rows.Scan(&id, &name, &revision, &createdAt); err != nil {
			return nil, fmt.Errorf("прочитать невыложенную ревизию: %w", err)
		}
		out = append(out, LooseEnd{
			Kind:  "preset",
			Text:  fmt.Sprintf("«%s»: ревизия %d сохранена, но не выложена — на машинах пока прежняя", name, revision),
			Href:  fmt.Sprintf("/presets/%d", id),
			Since: readTime(createdAt),
		})
	}
	return out, rows.Err()
}

// pendingKeys — ключ выдан, а машина ещё не отметилась.
//
// Просроченные сюда не попадают: они уже не сработают, и чинить в них нечего —
// выпускается новый. Поэтому хвост убирается сам, даже пока журнала раздачи
// нет и «забран» ставить некому.
func (db *DB) pendingKeys(ctx context.Context, now time.Time) ([]LooseEnd, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT a.employee_id, e.name, a.key_prefix, a.issued_at
		  FROM activations a
		  JOIN employees e ON e.id = a.employee_id
		 WHERE a.fetched_at IS NULL
		   AND a.revoked_at IS NULL
		   AND a.expires_at > ?
		 ORDER BY a.issued_at`, formatTime(now))
	if err != nil {
		return nil, fmt.Errorf("найти невостребованные ключи: %w", err)
	}
	defer rows.Close()

	var out []LooseEnd
	for rows.Next() {
		var (
			employeeID int64
			name       string
			prefix     string
			issuedAt   string
		)
		if err := rows.Scan(&employeeID, &name, &prefix, &issuedAt); err != nil {
			return nil, fmt.Errorf("прочитать невостребованный ключ: %w", err)
		}
		out = append(out, LooseEnd{
			Kind:  "key",
			Text:  fmt.Sprintf("%s: ключ %s… выдан, машина ещё не отметилась", name, prefix),
			Href:  fmt.Sprintf("/employees/%d", employeeID),
			Since: readTime(issuedAt),
		})
	}
	return out, rows.Err()
}

// incompleteEmployees — сотрудник, которому ключ не выпустится.
func (db *DB) incompleteEmployees(ctx context.Context, _ time.Time) ([]LooseEnd, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT e.id, e.name, e.number, e.sip_password, e.preset_id, e.created_at
		  FROM employees e
		 WHERE e.number = '' OR e.sip_password = '' OR e.preset_id IS NULL
		 ORDER BY e.created_at`)
	if err != nil {
		return nil, fmt.Errorf("найти незаполненных сотрудников: %w", err)
	}
	defer rows.Close()

	var out []LooseEnd
	for rows.Next() {
		var (
			id        int64
			name      string
			number    string
			password  string
			presetID  any
			createdAt string
		)
		if err := rows.Scan(&id, &name, &number, &password, &presetID, &createdAt); err != nil {
			return nil, fmt.Errorf("прочитать незаполненного сотрудника: %w", err)
		}

		// Чего именно не хватает, говорится прямо: «карточка заполнена не до
		// конца» отправляет человека сравнивать поля глазами.
		lack := "не хватает: "
		switch {
		case number == "" || password == "":
			lack += "номера и SIP-пароля"
			if presetID == nil {
				lack += ", предустановки"
			}
		default:
			lack += "предустановки"
		}

		out = append(out, LooseEnd{
			Kind:  "employee",
			Text:  name + " — " + lack + "; ключ такому не выпустится",
			Href:  fmt.Sprintf("/employees/%d", id),
			Since: readTime(createdAt),
		})
	}
	return out, rows.Err()
}
