package storage

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
)

// SaveCheckin запоминает, что панель узнала о машине.
//
// Возвращает false, если такой машины в базе нет. Это не ошибка и не
// небрежность: машина удалённого сотрудника продолжает тянуть файл
// предустановок — она о людях ничего не знает, а файл лежит на R2. Отказ здесь
// означал бы ошибку в журнале панели при каждом заходе такой машины, а
// молчаливый пропуск без ответа — невозможность их сосчитать.
func (db *DB) SaveCheckin(ctx context.Context, c model.Checkin) (bool, error) {
	res, err := db.ExecContext(ctx, `
		INSERT INTO checkins (installation_id, last_seen_at, app_version, schema_version, preset_revision)
		     SELECT ?, ?, ?, ?, ?
		      WHERE EXISTS (SELECT 1 FROM activations WHERE installation_id = ?)
		ON CONFLICT(installation_id) DO UPDATE SET
		     last_seen_at    = excluded.last_seen_at,
		     app_version     = excluded.app_version,
		     schema_version  = excluded.schema_version,
		     preset_revision = excluded.preset_revision`,
		c.InstallationID, formatTime(c.LastSeenAt), c.AppVersion,
		nullInt(c.SchemaVersion), nullInt(c.PresetRevision), c.InstallationID)
	if err != nil {
		return false, fmt.Errorf("записать отметку машины %s: %w", c.InstallationID, err)
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("записать отметку машины %s: %w", c.InstallationID, err)
	}
	return affected > 0, nil
}

// MachineRow — машина глазами списка: активация вместе с тем, что о ней
// известно из отметок.
type MachineRow struct {
	model.Activation
	Checkin *model.Checkin
}

// Machines перечисляет машины сотрудника вместе с отметками.
func (db *DB) Machines(ctx context.Context, employeeID int64) ([]MachineRow, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT a.id, a.employee_id, a.preset_id, a.key_hash, a.key_prefix, a.object_key,
		       a.installation_id, a.issued_by, a.issued_at, a.expires_at,
		       a.fetched_at, a.revoked_at, a.note,
		       c.last_seen_at, c.app_version, c.schema_version, c.preset_revision
		  FROM activations a
		  LEFT JOIN checkins c ON c.installation_id = a.installation_id
		 WHERE a.employee_id = ?
		 ORDER BY a.id DESC`, employeeID)
	if err != nil {
		return nil, fmt.Errorf("перечислить машины сотрудника %d: %w", employeeID, err)
	}
	defer rows.Close()

	var out []MachineRow
	for rows.Next() {
		var (
			m          MachineRow
			issuedBy   sql.NullInt64
			issuedAt   string
			expiresAt  string
			fetchedAt  sql.NullString
			revokedAt  sql.NullString
			lastSeenAt sql.NullString
			appVersion sql.NullString
			schema     sql.NullInt64
			revision   sql.NullInt64
		)
		if err := rows.Scan(&m.ID, &m.EmployeeID, &m.PresetID, &m.KeyFingerprint, &m.KeyPrefix,
			&m.ObjectKey, &m.InstallationID, &issuedBy, &issuedAt, &expiresAt,
			&fetchedAt, &revokedAt, &m.Note,
			&lastSeenAt, &appVersion, &schema, &revision); err != nil {
			return nil, fmt.Errorf("прочитать строку машины: %w", err)
		}
		m.IssuedBy = readNullInt64(issuedBy)
		m.IssuedAt = readTime(issuedAt)
		m.ExpiresAt = readTime(expiresAt)
		m.FetchedAt = readNullTime(fetchedAt)
		m.RevokedAt = readNullTime(revokedAt)

		if lastSeenAt.Valid {
			m.Checkin = &model.Checkin{
				InstallationID: m.InstallationID,
				LastSeenAt:     readTime(lastSeenAt.String),
				AppVersion:     appVersion.String,
				SchemaVersion:  readNullInt(schema),
				PresetRevision: readNullInt(revision),
			}
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// PendingObjectKeys перечисляет адреса пакетов, о которых панель ещё не знает,
// забрали их или нет.
//
// Только они и читаются из бакета при разборе отметок: перечень отметок
// перечисляется целиком, но забирать содержимое каждой при каждом заходе
// незачем — отметка не меняется после того, как её поставили.
func (db *DB) PendingObjectKeys(ctx context.Context) (map[string]bool, error) {
	// Погашенные не в счёт: их пакеты уборка уже унесла, и отметка по ним, если
	// она вдруг найдётся, — это чужой промах, а не выдача.
	rows, err := db.QueryContext(ctx,
		`SELECT object_key FROM activations
		  WHERE fetched_at IS NULL AND superseded_at IS NULL`)
	if err != nil {
		return nil, fmt.Errorf("перечислить незабранные пакеты: %w", err)
	}
	defer rows.Close()

	out := map[string]bool{}
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			return nil, fmt.Errorf("прочитать адрес пакета: %w", err)
		}
		out[key] = true
	}
	return out, rows.Err()
}

// BehindVersion считает машины, отставшие от последней ревизии своей
// предустановки.
//
// Машины без отметки сюда не идут: о них панель не знает ничего, и считать их
// отставшими значило бы показывать поломку там, где просто нет сведений.
func (db *DB) BehindVersion(ctx context.Context) (int, error) {
	var count int
	err := db.QueryRowContext(ctx, `
		SELECT COUNT(*)
		  FROM checkins c
		  JOIN activations a ON a.installation_id = c.installation_id
		 WHERE c.preset_revision IS NOT NULL
		   AND c.preset_revision < (SELECT MAX(r.revision) FROM preset_revisions r
		                             WHERE r.preset_id = a.preset_id
		                               AND r.published_at IS NOT NULL)`).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("посчитать отставшие машины: %w", err)
	}
	return count, nil
}

// KnownCheckins возвращает отметки, уже лежащие в базе, — чтобы не переписывать
// те, что не менялись.
func (db *DB) KnownCheckins(ctx context.Context) (map[string]time.Time, error) {
	rows, err := db.QueryContext(ctx, `SELECT installation_id, last_seen_at FROM checkins`)
	if err != nil {
		return nil, fmt.Errorf("перечислить отметки: %w", err)
	}
	defer rows.Close()

	out := map[string]time.Time{}
	for rows.Next() {
		var (
			id   string
			seen string
		)
		if err := rows.Scan(&id, &seen); err != nil {
			return nil, fmt.Errorf("прочитать отметку: %w", err)
		}
		out[id] = readTime(seen)
	}
	return out, rows.Err()
}

// MachineState — что показывать в колонке «Машины» списка сотрудников.
//
// Колонка заведена 25 августа 2026: до неё на вопрос «а у Петрова-то что?»
// нельзя было ответить, не открыв Петрова. Считается здесь, а не в шаблоне:
// молчание — это арифметика со временем.
type MachineState struct {
	Live    int  // активированные машины, о которых есть отметка и она свежая
	Silent  int  // отметка есть, но старше срока молчания
	Waiting bool // есть выпущенный ключ, который ещё не забрали
}

// MachineStates собирает состояние машин по всем сотрудникам разом.
//
// Одним запросом на весь список, а не по запросу на строку: тридцать строк —
// это тридцать походов в базу, и растёт оно вместе с конторой.
func (db *DB) MachineStates(ctx context.Context, now time.Time) (map[int64]MachineState, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT a.employee_id, a.fetched_at, a.revoked_at, a.expires_at, c.last_seen_at
		  FROM activations a
		  LEFT JOIN checkins c ON c.installation_id = a.installation_id`)
	if err != nil {
		return nil, fmt.Errorf("собрать состояние машин: %w", err)
	}
	defer rows.Close()

	out := make(map[int64]MachineState)
	for rows.Next() {
		var (
			employeeID int64
			fetchedAt  sql.NullString
			revokedAt  sql.NullString
			expiresAt  string
			lastSeenAt sql.NullString
		)
		if err := rows.Scan(&employeeID, &fetchedAt, &revokedAt, &expiresAt, &lastSeenAt); err != nil {
			return nil, fmt.Errorf("прочитать строку состояния машин: %w", err)
		}

		state := out[employeeID]
		switch {
		case revokedAt.Valid:
			// Отозванная активация в колонку не попадает вовсе: машина по ней
			// живёт до смены пароля пира на АТС, но это не то состояние, о
			// котором список должен рапортовать одним словом.
		case !fetchedAt.Valid:
			if readTime(expiresAt).After(now) {
				state.Waiting = true
			}
		case lastSeenAt.Valid && (&model.Checkin{LastSeenAt: readTime(lastSeenAt.String)}).Silent(now):
			state.Silent++
		default:
			state.Live++
		}
		out[employeeID] = state
	}
	return out, rows.Err()
}
