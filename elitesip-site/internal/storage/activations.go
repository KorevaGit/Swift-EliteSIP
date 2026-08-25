package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
)

// ErrNoNumber — у сотрудника не заполнены номер и SIP-пароль.
var ErrNoNumber = errors.New("у сотрудника не заполнены номер и SIP-пароль")

// ErrNoPreset — сотруднику не назначена предустановка или у неё нет ревизий.
var ErrNoPreset = errors.New("сотруднику не назначена предустановка с ревизией")

// IssueSubject — всё, что нужно собрать в пакет активации.
//
// Собирается одним запросом, а не двумя: между «прочитали карточку» и
// «прочитали предустановку» администратор в соседнем окне может удалить этого
// сотрудника, и в пакет уехало бы состояние, которого уже нет.
type IssueSubject struct {
	EmployeeID     int64
	EmployeeName   string
	Number         string
	SIPPassword    string
	PresetID       int64
	PresetPublicID string
	PresetName     string
	AdminPassword  string
	RevisionID     int64
	Revision       int

	// InstallationID — машина, для которой выпускается ключ перепрошивки.
	// Пустой у ключа активации: машины ещё нет.
	InstallationID string
}

// IssueRecord — запись об активации, готовая к сохранению.
type IssueRecord struct {
	EmployeeID     int64
	PresetID       int64
	Kind           string
	KeyFingerprint string
	KeyPrefix      string
	ObjectKey      string
	InstallationID string
	ChannelKeyHash string
	ExpiresAt      time.Time
	Note           string
}

// SubjectForIssue читает состояние сотрудника на момент выпуска ключа.
func (db *DB) SubjectForIssue(ctx context.Context, employeeID int64) (IssueSubject, error) {
	var (
		s             IssueSubject
		presetID      sql.NullInt64
		presetPub     sql.NullString
		presetName    sql.NullString
		adminPassword sql.NullString
		revisionID    sql.NullInt64
		revision      sql.NullInt64
	)
	err := db.QueryRowContext(ctx, `
		SELECT e.id, e.name, e.number, e.sip_password,
		       p.id, p.public_id, p.name, p.admin_password,
		       r.id, r.revision
		  FROM employees e
		  LEFT JOIN presets p ON p.id = e.preset_id AND p.archived_at IS NULL
		  LEFT JOIN preset_revisions r
		         ON r.preset_id = p.id
		        AND r.revision = (SELECT MAX(revision) FROM preset_revisions WHERE preset_id = p.id)
		 WHERE e.id = ?`, employeeID).
		Scan(&s.EmployeeID, &s.EmployeeName, &s.Number, &s.SIPPassword,
			&presetID, &presetPub, &presetName, &adminPassword,
			&revisionID, &revision)
	if errors.Is(err, sql.ErrNoRows) {
		return IssueSubject{}, ErrNotFound
	}
	if err != nil {
		return IssueSubject{}, fmt.Errorf("прочитать состояние сотрудника %d: %w", employeeID, err)
	}

	if s.Number == "" || s.SIPPassword == "" {
		return IssueSubject{}, ErrNoNumber
	}
	if !revisionID.Valid {
		return IssueSubject{}, ErrNoPreset
	}

	s.PresetID = presetID.Int64
	s.PresetPublicID = presetPub.String
	s.PresetName = presetName.String
	s.AdminPassword = adminPassword.String
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
		 (employee_id, preset_id, kind, key_hash, key_prefix, object_key,
		  installation_id, channel_key_hash, issued_by, issued_at, expires_at, note)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		rec.EmployeeID, rec.PresetID, rec.Kind, rec.KeyFingerprint, rec.KeyPrefix,
		rec.ObjectKey, rec.InstallationID, rec.ChannelKeyHash,
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
		Kind:           model.ActivationKind(rec.Kind),
		KeyFingerprint: rec.KeyFingerprint, KeyPrefix: rec.KeyPrefix,
		ObjectKey: rec.ObjectKey, InstallationID: rec.InstallationID,
		ChannelKeyHash: rec.ChannelKeyHash,
		IssuedBy:       actor, IssuedAt: now.UTC().Truncate(time.Second),
		ExpiresAt: rec.ExpiresAt.UTC().Truncate(time.Second), Note: rec.Note,
	}, nil
}

// ListActivations перечисляет активации сотрудника, свежие первыми.
func (db *DB) ListActivations(ctx context.Context, employeeID int64) ([]model.Activation, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT id, employee_id, preset_id, kind, key_hash, key_prefix, object_key,
		       installation_id, channel_key_hash,
		       issued_by, issued_at, expires_at, fetched_at, revoked_at, superseded_at, note
		  FROM activations WHERE employee_id = ? ORDER BY id DESC`, employeeID)
	if err != nil {
		return nil, fmt.Errorf("перечислить активации сотрудника %d: %w", employeeID, err)
	}
	defer rows.Close()

	var out []model.Activation
	for rows.Next() {
		var (
			a            model.Activation
			issuedBy     sql.NullInt64
			issuedAt     string
			expiresAt    string
			fetchedAt    sql.NullString
			revokedAt    sql.NullString
			supersededAt sql.NullString
		)
		if err := rows.Scan(&a.ID, &a.EmployeeID, &a.PresetID, &a.Kind, &a.KeyFingerprint,
			&a.KeyPrefix, &a.ObjectKey, &a.InstallationID, &a.ChannelKeyHash,
			&issuedBy, &issuedAt, &expiresAt,
			&fetchedAt, &revokedAt, &supersededAt, &a.Note); err != nil {
			return nil, fmt.Errorf("прочитать строку активации: %w", err)
		}
		a.IssuedBy = readNullInt64(issuedBy)
		a.IssuedAt = readTime(issuedAt)
		a.ExpiresAt = readTime(expiresAt)
		a.FetchedAt = readNullTime(fetchedAt)
		a.RevokedAt = readNullTime(revokedAt)
		a.SupersededAt = readNullTime(supersededAt)
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
		a            model.Activation
		issuedBy     sql.NullInt64
		issuedAt     string
		expiresAt    string
		fetchedAt    sql.NullString
		revokedAt    sql.NullString
		supersededAt sql.NullString
	)
	err := db.QueryRowContext(ctx, `
		SELECT id, employee_id, preset_id, kind, key_hash, key_prefix, object_key,
		       installation_id, channel_key_hash,
		       issued_by, issued_at, expires_at, fetched_at, revoked_at, superseded_at, note
		  FROM activations WHERE key_hash = ?`, fingerprint).
		Scan(&a.ID, &a.EmployeeID, &a.PresetID, &a.Kind, &a.KeyFingerprint, &a.KeyPrefix,
			&a.ObjectKey, &a.InstallationID, &a.ChannelKeyHash,
			&issuedBy, &issuedAt, &expiresAt,
			&fetchedAt, &revokedAt, &supersededAt, &a.Note)
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
	a.SupersededAt = readNullTime(supersededAt)
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

// UnfetchedActivations перечисляет живые невостребованные ключи сотрудника,
// старейшие первыми.
//
// Живые — это непогашенные и неотозванные. Просроченные сюда входят: они всё
// ещё занимают место в счёте «не больше трёх», пока их не вытеснили, и
// вытесняться должны первыми.
func (db *DB) UnfetchedActivations(ctx context.Context, employeeID int64) ([]model.Activation, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT id, installation_id, object_key, issued_at
		  FROM activations
		 WHERE employee_id = ?
		   AND fetched_at IS NULL
		   AND revoked_at IS NULL
		   AND superseded_at IS NULL
		 ORDER BY id ASC`, employeeID)
	if err != nil {
		return nil, fmt.Errorf("перечислить невостребованные ключи сотрудника %d: %w", employeeID, err)
	}
	defer rows.Close()

	var out []model.Activation
	for rows.Next() {
		var (
			a        model.Activation
			issuedAt string
		)
		if err := rows.Scan(&a.ID, &a.InstallationID, &a.ObjectKey, &issuedAt); err != nil {
			return nil, fmt.Errorf("прочитать строку невостребованного ключа: %w", err)
		}
		a.EmployeeID = employeeID
		a.IssuedAt = readTime(issuedAt)
		out = append(out, a)
	}
	return out, rows.Err()
}

// SupersedeActivation гасит активацию.
//
// Гашение, а не удаление: строка забранной активации — единственная привязка
// машины к сотруднику, а журнал действий указывает на активацию по номеру.
// Удаление и разорвало бы привязку, и оставило запись «ключ выпущен» висеть в
// пустоту.
//
// Причина уходит в журнал словами, потому что состояний два и различаются они
// только тем, была ли за строкой живая машина: «вытеснен новым ключом» у
// невостребованного и «перепрошита» у забранной.
func (db *DB) SupersedeActivation(ctx context.Context, actor *int64, id int64, by *int64, reason string) error {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("погасить активацию: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx, `
		UPDATE activations
		   SET superseded_at = ?, superseded_by = ?
		 WHERE id = ? AND superseded_at IS NULL`,
		formatTime(now), nullInt64(by), id)
	if err != nil {
		return fmt.Errorf("погасить активацию %d: %w", id, err)
	}
	if affected, _ := res.RowsAffected(); affected == 0 {
		return ErrNotFound
	}
	if err := logAction(ctx, tx, now, actor, reason, "activation", &id, ""); err != nil {
		return err
	}
	return tx.Commit()
}

// LiveActivationByInstallation находит непогашенную активацию машины.
//
// Существует ради перепрошивки: ключ выпускается на машину, а машина в базе —
// это её последняя живая строка. Забранная, потому что перепрошивать нечего
// там, где активацию ещё не забрали: сотруднику проще ввести уже выданный ключ.
func (db *DB) LiveActivationByInstallation(ctx context.Context, installationID string) (model.Activation, error) {
	var (
		a         model.Activation
		issuedAt  string
		expiresAt string
		fetchedAt sql.NullString
	)
	err := db.QueryRowContext(ctx, `
		SELECT id, employee_id, preset_id, installation_id, channel_key_hash,
		       issued_at, expires_at, fetched_at
		  FROM activations
		 WHERE installation_id = ?
		   AND superseded_at IS NULL
		   AND revoked_at IS NULL
		 ORDER BY id DESC LIMIT 1`, installationID).
		Scan(&a.ID, &a.EmployeeID, &a.PresetID, &a.InstallationID, &a.ChannelKeyHash,
			&issuedAt, &expiresAt, &fetchedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return model.Activation{}, ErrNotFound
	}
	if err != nil {
		return model.Activation{}, fmt.Errorf("найти машину %s: %w", installationID, err)
	}
	a.IssuedAt = readTime(issuedAt)
	a.ExpiresAt = readTime(expiresAt)
	a.FetchedAt = readNullTime(fetchedAt)
	return a, nil
}

// SweepTarget — пакет, которому в бакете делать больше нечего.
type SweepTarget struct {
	ID        int64
	ObjectKey string

	// Fetched — пакет успели забрать. Тогда вместе с ним уносится и парная
	// отметка taken/: она уже разобрана панелью и держать её незачем.
	//
	// У незабранного отметки нет вовсе, и «пара» вырождается в один объект.
	Fetched bool
}

// SweepablePackages перечисляет пакеты, которые пора унести из бакета.
//
// Четыре повода, и все они означают одно: ключ больше не сработает.
//
//   - забрали — пакет отдан, второй раз Worker его не отдаст;
//   - вытеснили — выпущен четвёртый ключ, этот погашен;
//   - отозвали — активация отменена;
//   - протух — прошли двое суток, и Worker откажет по возрасту сам.
//
// Последний повод важнее прочих: без уборки пакеты копились бы годами, и
// каждый из них — это SIP-пароль рабочего места, ждущий утечки ключа.
func (db *DB) SweepablePackages(ctx context.Context, now time.Time) ([]SweepTarget, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT id, object_key, CASE WHEN fetched_at IS NULL THEN 0 ELSE 1 END
		  FROM activations
		 WHERE package_removed_at IS NULL
		   AND (fetched_at IS NOT NULL
		     OR superseded_at IS NOT NULL
		     OR revoked_at IS NOT NULL
		     OR expires_at < ?)
		 ORDER BY id ASC`, formatTime(now))
	if err != nil {
		return nil, fmt.Errorf("перечислить пакеты под уборку: %w", err)
	}
	defer rows.Close()

	var out []SweepTarget
	for rows.Next() {
		var (
			t       SweepTarget
			fetched int
		)
		if err := rows.Scan(&t.ID, &t.ObjectKey, &fetched); err != nil {
			return nil, fmt.Errorf("прочитать строку уборки: %w", err)
		}
		t.Fetched = fetched == 1
		out = append(out, t)
	}
	return out, rows.Err()
}

// MarkPackageRemoved отмечает, что пакет унесён.
func (db *DB) MarkPackageRemoved(ctx context.Context, id int64, at time.Time) error {
	_, err := db.ExecContext(ctx,
		`UPDATE activations SET package_removed_at = ? WHERE id = ? AND package_removed_at IS NULL`,
		formatTime(at), id)
	if err != nil {
		return fmt.Errorf("отметить пакет активации %d унесённым: %w", id, err)
	}
	return nil
}

// KnownObjectNames — имена пакетов, о которых панель знает.
//
// Без приставки: уборка сверяет по ним отметки taken/, а те названы именем без
// раскладки. Нужны все, а не только живые: отметка забранного пакета уносится
// вместе с ним по строке базы, и трогать её проходом по сроку нельзя.
func (db *DB) KnownObjectNames(ctx context.Context) (map[string]bool, error) {
	rows, err := db.QueryContext(ctx, `SELECT object_key FROM activations`)
	if err != nil {
		return nil, fmt.Errorf("перечислить известные пакеты: %w", err)
	}
	defer rows.Close()

	out := make(map[string]bool)
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			return nil, fmt.Errorf("прочитать имя пакета: %w", err)
		}
		out[key] = true
	}
	return out, rows.Err()
}

// ActivationByID читает активацию по номеру.
//
// Существует ради отзыва: тот приходит из интерфейса с номером строки, а
// обрубать доступ надо машине, то есть по её installation_id.
func (db *DB) ActivationByID(ctx context.Context, id int64) (model.Activation, error) {
	var (
		a         model.Activation
		issuedAt  string
		expiresAt string
		fetchedAt sql.NullString
		revokedAt sql.NullString
	)
	err := db.QueryRowContext(ctx, `
		SELECT id, employee_id, preset_id, installation_id, object_key,
		       issued_at, expires_at, fetched_at, revoked_at
		  FROM activations WHERE id = ?`, id).
		Scan(&a.ID, &a.EmployeeID, &a.PresetID, &a.InstallationID, &a.ObjectKey,
			&issuedAt, &expiresAt, &fetchedAt, &revokedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return model.Activation{}, ErrNotFound
	}
	if err != nil {
		return model.Activation{}, fmt.Errorf("прочитать активацию %d: %w", id, err)
	}
	a.IssuedAt = readTime(issuedAt)
	a.ExpiresAt = readTime(expiresAt)
	a.FetchedAt = readNullTime(fetchedAt)
	a.RevokedAt = readNullTime(revokedAt)
	return a, nil
}

// ActivationByObjectKey находит активацию по адресу её пакета.
//
// Существует ради разбора отметок: Worker знает только адрес, а панели после
// «пакет забрали» надо понять, что именно забрали — первую активацию машины
// или её перепрошивку.
func (db *DB) ActivationByObjectKey(ctx context.Context, objectKey string) (model.Activation, error) {
	var (
		a        model.Activation
		issuedAt string
	)
	err := db.QueryRowContext(ctx, `
		SELECT id, employee_id, preset_id, kind, installation_id, channel_key_hash, issued_at
		  FROM activations WHERE object_key = ?`, objectKey).
		Scan(&a.ID, &a.EmployeeID, &a.PresetID, &a.Kind, &a.InstallationID,
			&a.ChannelKeyHash, &issuedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return model.Activation{}, ErrNotFound
	}
	if err != nil {
		return model.Activation{}, fmt.Errorf("найти активацию по адресу %s: %w", objectKey, err)
	}
	a.ObjectKey = objectKey
	a.IssuedAt = readTime(issuedAt)
	return a, nil
}

// SupersedePreviousOfMachine гасит прежние живые строки машины.
//
// Зовётся, когда панель узнала, что пакет перепрошивки забрали. До этого
// момента гасить нельзя: машина работает на старой предустановке, и её строка —
// это она сама.
//
// Гашение обязательно, а не для порядка: Machines склеивает активации с
// отметками по installation_id, и две живые строки с одним идентификатором
// показали бы одну физическую машину дважды, с одинаковой последней отметкой на
// обеих.
func (db *DB) SupersedePreviousOfMachine(ctx context.Context, installationID string, keepID int64) (int, error) {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("погасить прошлые строки машины: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx, `
		UPDATE activations
		   SET superseded_at = ?, superseded_by = ?
		 WHERE installation_id = ? AND id <> ? AND superseded_at IS NULL`,
		formatTime(now), keepID, installationID, keepID)
	if err != nil {
		return 0, fmt.Errorf("погасить прошлые строки машины %s: %w", installationID, err)
	}
	affected, _ := res.RowsAffected()
	if affected == 0 {
		return 0, tx.Commit()
	}

	if err := logAction(ctx, tx, now, nil, "машина перепрошита", "activation", &keepID, ""); err != nil {
		return 0, err
	}
	return int(affected), tx.Commit()
}
