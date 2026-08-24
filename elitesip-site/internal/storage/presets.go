package storage

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/preset"
)

// PresetSummary — предустановка и состояние её последней ревизии.
type PresetSummary struct {
	model.Preset
	Revision      int
	RevisionAt    time.Time
	Published     bool
	EmployeeCount int
}

// CreatePreset заводит предустановку без ревизий.
func (db *DB) CreatePreset(ctx context.Context, actor *int64, name string) (model.Preset, error) {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return model.Preset{}, fmt.Errorf("завести предустановку: %w", err)
	}
	defer tx.Rollback()

	publicID, err := preset.NewID()
	if err != nil {
		return model.Preset{}, err
	}

	res, err := tx.ExecContext(ctx,
		`INSERT INTO presets (public_id, name, created_at) VALUES (?, ?, ?)`,
		publicID, name, formatTime(now))
	if err != nil {
		return model.Preset{}, fmt.Errorf("завести предустановку %q: %w", name, err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return model.Preset{}, fmt.Errorf("завести предустановку %q: %w", name, err)
	}
	if err := logAction(ctx, tx, now, actor, "предустановка заведена", "preset", &id, name); err != nil {
		return model.Preset{}, err
	}
	if err := tx.Commit(); err != nil {
		return model.Preset{}, fmt.Errorf("завести предустановку %q: %w", name, err)
	}
	return model.Preset{
		ID: id, PublicID: publicID, Name: name,
		CreatedAt: now.UTC().Truncate(time.Second),
	}, nil
}

// ListPresets перечисляет предустановки с последней ревизией каждой.
func (db *DB) ListPresets(ctx context.Context, includeArchived bool) ([]PresetSummary, error) {
	query := `
		SELECT p.id, p.public_id, p.name, p.created_at, p.archived_at,
		       COALESCE(r.revision, 0), COALESCE(r.created_at, ''),
		       CASE WHEN r.published_at IS NULL THEN 0 ELSE 1 END,
		       (SELECT COUNT(*) FROM employees e WHERE e.preset_id = p.id)
		  FROM presets p
		  LEFT JOIN preset_revisions r
		         ON r.preset_id = p.id
		        AND r.revision = (SELECT MAX(revision) FROM preset_revisions
		                           WHERE preset_id = p.id)`
	if !includeArchived {
		query += ` WHERE p.archived_at IS NULL`
	}
	query += ` ORDER BY p.name`

	rows, err := db.QueryContext(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("перечислить предустановки: %w", err)
	}
	defer rows.Close()

	var out []PresetSummary
	for rows.Next() {
		var (
			s          PresetSummary
			createdAt  string
			archivedAt sql.NullString
			revisionAt string
			published  int
		)
		if err := rows.Scan(&s.ID, &s.PublicID, &s.Name, &createdAt, &archivedAt,
			&s.Revision, &revisionAt, &published, &s.EmployeeCount); err != nil {
			return nil, fmt.Errorf("прочитать строку предустановки: %w", err)
		}
		s.CreatedAt = readTime(createdAt)
		s.ArchivedAt = readNullTime(archivedAt)
		if revisionAt != "" {
			s.RevisionAt = readTime(revisionAt)
		}
		s.Published = published == 1
		out = append(out, s)
	}
	return out, rows.Err()
}

// SaveRevision добавляет предустановке новую ревизию.
//
// Правка не меняет прошлое: ревизия уезжает на все рабочие места и применяется
// обязательно, без возможности отложить, поэтому «откатить на предыдущую»
// должно быть действием в одно нажатие — а для этого предыдущая должна лежать
// целиком.
//
// Номер ревизии считается здесь же, внутри транзакции: два администратора,
// сохранившие правку одновременно, иначе получили бы один номер на двоих.
func (db *DB) SaveRevision(ctx context.Context, actor *int64, presetID int64, schemaVersion int, payload json.RawMessage, note string) (model.PresetRevision, error) {
	if !json.Valid(payload) {
		return model.PresetRevision{}, errors.New("содержимое ревизии не является JSON")
	}
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return model.PresetRevision{}, fmt.Errorf("сохранить ревизию: %w", err)
	}
	defer tx.Rollback()

	var exists int
	err = tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM presets WHERE id = ?`, presetID).Scan(&exists)
	if err != nil {
		return model.PresetRevision{}, fmt.Errorf("проверить предустановку %d: %w", presetID, err)
	}
	if exists == 0 {
		return model.PresetRevision{}, ErrNotFound
	}

	var next int
	if err := tx.QueryRowContext(ctx,
		`SELECT COALESCE(MAX(revision), 0) + 1 FROM preset_revisions WHERE preset_id = ?`, presetID).
		Scan(&next); err != nil {
		return model.PresetRevision{}, fmt.Errorf("номер следующей ревизии: %w", err)
	}

	res, err := tx.ExecContext(ctx,
		`INSERT INTO preset_revisions
		 (preset_id, revision, schema_version, payload, note, author_id, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		presetID, next, schemaVersion, string(payload), note, nullInt64(actor), formatTime(now))
	if err != nil {
		return model.PresetRevision{}, fmt.Errorf("сохранить ревизию %d: %w", next, err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return model.PresetRevision{}, fmt.Errorf("сохранить ревизию %d: %w", next, err)
	}

	if err := logAction(ctx, tx, now, actor, "ревизия предустановки сохранена", "preset", &presetID,
		fmt.Sprintf("ревизия %d", next)); err != nil {
		return model.PresetRevision{}, err
	}
	if err := tx.Commit(); err != nil {
		return model.PresetRevision{}, fmt.Errorf("сохранить ревизию %d: %w", next, err)
	}

	return model.PresetRevision{
		ID: id, PresetID: presetID, Revision: next, SchemaVersion: schemaVersion,
		Payload: payload, Note: note, AuthorID: actor,
		CreatedAt: now.UTC().Truncate(time.Second),
	}, nil
}

// LatestRevision возвращает последнюю ревизию предустановки.
func (db *DB) LatestRevision(ctx context.Context, presetID int64) (model.PresetRevision, error) {
	return db.scanRevision(db.QueryRowContext(ctx,
		`SELECT id, preset_id, revision, schema_version, payload, note, author_id, created_at, published_at
		   FROM preset_revisions WHERE preset_id = ?
		  ORDER BY revision DESC LIMIT 1`, presetID))
}

// RevisionRow — ревизия для списка: с именем автора вместо его номера.
type RevisionRow struct {
	model.PresetRevision

	// AuthorLogin пуст у ревизий, автор которых не записан, — так бывает у
	// сделанных из командной строки и у погашенных администраторов.
	AuthorLogin string
}

// ListRevisions перечисляет ревизии предустановки, свежие первыми.
//
// Они и так хранятся целиком — осталось показать. Список нужен ради отката:
// правка уезжает на все машины обязательным обновлением, и «вернуть как было»
// должно быть действием в одно нажатие.
func (db *DB) ListRevisions(ctx context.Context, presetID int64) ([]RevisionRow, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT r.id, r.preset_id, r.revision, r.schema_version, r.payload, r.note,
		       r.author_id, r.created_at, r.published_at, COALESCE(a.login, '')
		  FROM preset_revisions r
		  LEFT JOIN admins a ON a.id = r.author_id
		 WHERE r.preset_id = ?
		 ORDER BY r.revision DESC`, presetID)
	if err != nil {
		return nil, fmt.Errorf("перечислить ревизии предустановки %d: %w", presetID, err)
	}
	defer rows.Close()

	var out []RevisionRow
	for rows.Next() {
		var (
			r           RevisionRow
			payload     string
			authorID    sql.NullInt64
			createdAt   string
			publishedAt sql.NullString
		)
		if err := rows.Scan(&r.ID, &r.PresetID, &r.Revision, &r.SchemaVersion, &payload,
			&r.Note, &authorID, &createdAt, &publishedAt, &r.AuthorLogin); err != nil {
			return nil, fmt.Errorf("прочитать строку ревизии: %w", err)
		}
		r.Payload = json.RawMessage(payload)
		r.AuthorID = readNullInt64(authorID)
		r.CreatedAt = readTime(createdAt)
		r.PublishedAt = readNullTime(publishedAt)
		out = append(out, r)
	}
	return out, rows.Err()
}

// LastPublishedRevision возвращает последнюю ревизию, которая уехала наружу.
//
// По ней считается список изменений перед выкладкой: сравнивать надо с тем,
// что сейчас на машинах, а не с предыдущей сохранённой. Между ними бывает
// несколько несохранённых заходов подряд, и человеку важно, что уедет всё
// разом.
func (db *DB) LastPublishedRevision(ctx context.Context, presetID int64) (model.PresetRevision, error) {
	return db.scanRevision(db.QueryRowContext(ctx,
		`SELECT id, preset_id, revision, schema_version, payload, note, author_id, created_at, published_at
		   FROM preset_revisions WHERE preset_id = ? AND published_at IS NOT NULL
		  ORDER BY revision DESC LIMIT 1`, presetID))
}

// RevisionByID возвращает ревизию по её идентификатору.
func (db *DB) RevisionByID(ctx context.Context, id int64) (model.PresetRevision, error) {
	return db.scanRevision(db.QueryRowContext(ctx,
		`SELECT id, preset_id, revision, schema_version, payload, note, author_id, created_at, published_at
		   FROM preset_revisions WHERE id = ?`, id))
}

func (db *DB) scanRevision(row *sql.Row) (model.PresetRevision, error) {
	var (
		r           model.PresetRevision
		payload     string
		authorID    sql.NullInt64
		createdAt   string
		publishedAt sql.NullString
	)
	err := row.Scan(&r.ID, &r.PresetID, &r.Revision, &r.SchemaVersion, &payload,
		&r.Note, &authorID, &createdAt, &publishedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return model.PresetRevision{}, ErrNotFound
	}
	if err != nil {
		return model.PresetRevision{}, fmt.Errorf("прочитать ревизию: %w", err)
	}
	r.Payload = json.RawMessage(payload)
	r.AuthorID = readNullInt64(authorID)
	r.CreatedAt = readTime(createdAt)
	r.PublishedAt = readNullTime(publishedAt)
	return r, nil
}

// MarkPublished отмечает, что ревизия уехала в R2.
//
// Отдельным действием после выкладки, а не при сохранении: между «сохранил на
// сайте» и «файл лежит снаружи» проходит выкладка, и в интерфейсе эта разница
// должна быть видна честно — иначе администратор считает уехавшим то, чего на
// машинах ещё нет.
func (db *DB) MarkPublished(ctx context.Context, actor *int64, revisionID int64) error {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("отметить ревизию выложенной: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`UPDATE preset_revisions SET published_at = ? WHERE id = ? AND published_at IS NULL`,
		formatTime(now), revisionID)
	if err != nil {
		return fmt.Errorf("отметить ревизию %d выложенной: %w", revisionID, err)
	}
	if affected, _ := res.RowsAffected(); affected == 0 {
		return ErrNotFound
	}
	if err := logAction(ctx, tx, now, actor, "ревизия выложена", "preset_revision", &revisionID, ""); err != nil {
		return err
	}
	return tx.Commit()
}

// BundleEntry — предустановка с её последней ревизией, как она уедет в файл.
type BundleEntry struct {
	PresetID      int64
	PublicID      string
	Name          string
	RevisionID    int64
	Revision      int
	SchemaVersion int
	Payload       json.RawMessage
}

// BundleEntries собирает то, что должно лежать в файле на R2.
//
// Архивные предустановки не берутся: файл описывает то, чем управляют сейчас.
// Предустановка без единой ревизии тоже не берётся — управлять ею пока нечем,
// а пустая запись в файле заставила бы машину применить пустоту.
func (db *DB) BundleEntries(ctx context.Context) ([]BundleEntry, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT p.id, p.public_id, p.name, r.id, r.revision, r.schema_version, r.payload
		  FROM presets p
		  JOIN preset_revisions r
		    ON r.preset_id = p.id
		   AND r.revision = (SELECT MAX(revision) FROM preset_revisions WHERE preset_id = p.id)
		 WHERE p.archived_at IS NULL
		 ORDER BY p.name`)
	if err != nil {
		return nil, fmt.Errorf("собрать содержимое файла предустановок: %w", err)
	}
	defer rows.Close()

	var out []BundleEntry
	for rows.Next() {
		var (
			e       BundleEntry
			payload string
		)
		if err := rows.Scan(&e.PresetID, &e.PublicID, &e.Name,
			&e.RevisionID, &e.Revision, &e.SchemaVersion, &payload); err != nil {
			return nil, fmt.Errorf("прочитать строку файла предустановок: %w", err)
		}
		e.Payload = json.RawMessage(payload)
		out = append(out, e)
	}
	return out, rows.Err()
}
