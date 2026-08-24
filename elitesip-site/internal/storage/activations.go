package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
)

// ErrNoNumber — сотруднику не закреплён номер.
var ErrNoNumber = errors.New("сотруднику не закреплён номер")

// ErrNoPreset — сотруднику не назначена предустановка или у неё нет ревизий.
var ErrNoPreset = errors.New("сотруднику не назначена предустановка с ревизией")

// IssueSubject — всё, что нужно собрать в пакет активации.
//
// Собирается одним запросом, а не тремя: между «прочитали номер» и «прочитали
// предустановку» администратор в соседнем окне может уволить этого сотрудника,
// и в пакет уехало бы состояние, которого уже нет.
type IssueSubject struct {
	EmployeeID     int64
	EmployeeName   string
	NumberID       int64
	Number         string
	SIPPassword    string
	PresetID       int64
	PresetPublicID string
	PresetName     string
	RevisionID     int64
	Revision       int
}

// IssueRecord — запись об активации, готовая к сохранению.
type IssueRecord struct {
	EmployeeID     int64
	PresetID       int64
	KeyFingerprint string
	KeyPrefix      string
	ObjectKey      string
	InstallationID string
	ExpiresAt      time.Time
	Note           string
}

// SubjectForIssue читает состояние сотрудника на момент выпуска ключа.
func (db *DB) SubjectForIssue(ctx context.Context, employeeID int64) (IssueSubject, error) {
	var (
		s           IssueSubject
		dismissedAt sql.NullString
		numberID    sql.NullInt64
		presetID    sql.NullInt64
		presetPub   sql.NullString
		revisionID  sql.NullInt64
		revision    sql.NullInt64
		number      sql.NullString
		password    sql.NullString
		presetName  sql.NullString
	)
	err := db.QueryRowContext(ctx, `
		SELECT e.id, e.name, e.dismissed_at,
		       n.id, n.number, n.sip_password,
		       p.id, p.public_id, p.name,
		       r.id, r.revision
		  FROM employees e
		  LEFT JOIN number_assignments a
		         ON a.employee_id = e.id AND a.released_at IS NULL
		  LEFT JOIN numbers n ON n.id = a.number_id AND n.retired_at IS NULL
		  LEFT JOIN presets p ON p.id = e.preset_id AND p.archived_at IS NULL
		  LEFT JOIN preset_revisions r
		         ON r.preset_id = p.id
		        AND r.revision = (SELECT MAX(revision) FROM preset_revisions WHERE preset_id = p.id)
		 WHERE e.id = ?`, employeeID).
		Scan(&s.EmployeeID, &s.EmployeeName, &dismissedAt,
			&numberID, &number, &password,
			&presetID, &presetPub, &presetName,
			&revisionID, &revision)
	if errors.Is(err, sql.ErrNoRows) {
		return IssueSubject{}, ErrNotFound
	}
	if err != nil {
		return IssueSubject{}, fmt.Errorf("прочитать состояние сотрудника %d: %w", employeeID, err)
	}

	if dismissedAt.Valid {
		return IssueSubject{}, ErrEmployeeDismissed
	}
	if !numberID.Valid {
		return IssueSubject{}, ErrNoNumber
	}
	if !revisionID.Valid {
		return IssueSubject{}, ErrNoPreset
	}

	s.NumberID = numberID.Int64
	s.Number = number.String
	s.SIPPassword = password.String
	s.PresetID = presetID.Int64
	s.PresetPublicID = presetPub.String
	s.PresetName = presetName.String
	s.RevisionID = revisionID.Int64
	s.Revision = int(revision.Int64)
	return s, nil
}

// SaveActivation записывает выпущенную активацию.
func (db *DB) SaveActivation(ctx context.Context, actor *int64, rec IssueRecord) (model.Activation, error) {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return model.Activation{}, fmt.Errorf("записать активацию: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx, `
		INSERT INTO activations
		 (employee_id, preset_id, key_hash, key_prefix, object_key, installation_id,
		  issued_by, issued_at, expires_at, note)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		rec.EmployeeID, rec.PresetID, rec.KeyFingerprint, rec.KeyPrefix,
		rec.ObjectKey, rec.InstallationID,
		nullInt64(actor), formatTime(now), formatTime(rec.ExpiresAt), rec.Note)
	if err != nil {
		return model.Activation{}, fmt.Errorf("записать активацию: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return model.Activation{}, fmt.Errorf("записать активацию: %w", err)
	}

	// Ни ключа, ни его отпечатка в журнале нет: журнал читают чаще, чем
	// карточку, а ключ — это рабочее место целиком.
	if err := logAction(ctx, tx, now, actor, "ключ выпущен", "employee", &rec.EmployeeID,
		"активация "+rec.KeyPrefix+"…"); err != nil {
		return model.Activation{}, err
	}
	if err := tx.Commit(); err != nil {
		return model.Activation{}, fmt.Errorf("записать активацию: %w", err)
	}

	return model.Activation{
		ID: id, EmployeeID: rec.EmployeeID, PresetID: rec.PresetID,
		KeyFingerprint: rec.KeyFingerprint, KeyPrefix: rec.KeyPrefix,
		ObjectKey: rec.ObjectKey, InstallationID: rec.InstallationID,
		IssuedBy: actor, IssuedAt: now.UTC().Truncate(time.Second),
		ExpiresAt: rec.ExpiresAt.UTC().Truncate(time.Second), Note: rec.Note,
	}, nil
}

// ListActivations перечисляет активации сотрудника, свежие первыми.
func (db *DB) ListActivations(ctx context.Context, employeeID int64) ([]model.Activation, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT id, employee_id, preset_id, key_hash, key_prefix, object_key, installation_id,
		       issued_by, issued_at, expires_at, fetched_at, revoked_at, note
		  FROM activations WHERE employee_id = ? ORDER BY id DESC`, employeeID)
	if err != nil {
		return nil, fmt.Errorf("перечислить активации сотрудника %d: %w", employeeID, err)
	}
	defer rows.Close()

	var out []model.Activation
	for rows.Next() {
		var (
			a         model.Activation
			issuedBy  sql.NullInt64
			issuedAt  string
			expiresAt string
			fetchedAt sql.NullString
			revokedAt sql.NullString
		)
		if err := rows.Scan(&a.ID, &a.EmployeeID, &a.PresetID, &a.KeyFingerprint, &a.KeyPrefix,
			&a.ObjectKey, &a.InstallationID, &issuedBy, &issuedAt, &expiresAt,
			&fetchedAt, &revokedAt, &a.Note); err != nil {
			return nil, fmt.Errorf("прочитать строку активации: %w", err)
		}
		a.IssuedBy = readNullInt64(issuedBy)
		a.IssuedAt = readTime(issuedAt)
		a.ExpiresAt = readTime(expiresAt)
		a.FetchedAt = readNullTime(fetchedAt)
		a.RevokedAt = readNullTime(revokedAt)
		out = append(out, a)
	}
	return out, rows.Err()
}

// ActivationByFingerprint находит активацию по отпечатку ключа.
//
// Существует ради одного случая: сотрудник прислал ключ, и надо понять, что
// это за активация и жива ли она.
func (db *DB) ActivationByFingerprint(ctx context.Context, fingerprint string) (model.Activation, error) {
	var (
		a         model.Activation
		issuedBy  sql.NullInt64
		issuedAt  string
		expiresAt string
		fetchedAt sql.NullString
		revokedAt sql.NullString
	)
	err := db.QueryRowContext(ctx, `
		SELECT id, employee_id, preset_id, key_hash, key_prefix, object_key, installation_id,
		       issued_by, issued_at, expires_at, fetched_at, revoked_at, note
		  FROM activations WHERE key_hash = ?`, fingerprint).
		Scan(&a.ID, &a.EmployeeID, &a.PresetID, &a.KeyFingerprint, &a.KeyPrefix,
			&a.ObjectKey, &a.InstallationID, &issuedBy, &issuedAt, &expiresAt,
			&fetchedAt, &revokedAt, &a.Note)
	if errors.Is(err, sql.ErrNoRows) {
		return model.Activation{}, ErrNotFound
	}
	if err != nil {
		return model.Activation{}, fmt.Errorf("найти активацию по отпечатку: %w", err)
	}
	a.IssuedBy = readNullInt64(issuedBy)
	a.IssuedAt = readTime(issuedAt)
	a.ExpiresAt = readTime(expiresAt)
	a.FetchedAt = readNullTime(fetchedAt)
	a.RevokedAt = readNullTime(revokedAt)
	return a, nil
}

// RevokeActivation отзывает активацию.
//
// Отзыв здесь — учётная запись, а не техническое действие: после активации
// приложение к панели не ходит, и остановить машину может только смена
// SIP-пароля пира на АТС. Напомнить об этом — забота интерфейса.
func (db *DB) RevokeActivation(ctx context.Context, actor *int64, id int64) error {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("отозвать активацию: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`UPDATE activations SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`,
		formatTime(now), id)
	if err != nil {
		return fmt.Errorf("отозвать активацию %d: %w", id, err)
	}
	if affected, _ := res.RowsAffected(); affected == 0 {
		return ErrNotFound
	}
	if err := logAction(ctx, tx, now, actor, "активация отозвана", "activation", &id, ""); err != nil {
		return err
	}
	return tx.Commit()
}

// MarkFetched отмечает, что пакет активации забрали.
//
// Приходит из разбора журнала Worker'а, а не от приложения. Здесь же кончается
// одноразовость ключа: второй раз Worker пакет не отдаёт.
func (db *DB) MarkFetched(ctx context.Context, objectKey string, at time.Time) error {
	_, err := db.ExecContext(ctx,
		`UPDATE activations SET fetched_at = ? WHERE object_key = ? AND fetched_at IS NULL`,
		formatTime(at), objectKey)
	if err != nil {
		return fmt.Errorf("отметить пакет %s забранным: %w", objectKey, err)
	}
	return nil
}
