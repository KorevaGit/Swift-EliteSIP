package storage

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
)

// SessionLifetime — сколько живёт вход в панель.
//
// Рабочий день с запасом. Дольше держать незачем: панель стоит внутри сети, но
// открытая вкладка на чужой машине — это доступ к SIP-паролям конторы.
const SessionLifetime = 12 * time.Hour

// ErrDisabled — администратор погашен.
var ErrDisabled = errors.New("администратор отключён")

// CreateAdmin заводит администратора с уже подготовленным хешем пароля.
//
// Хеш приходит готовым, а не считается здесь: разбор пароля — не дело слоя
// хранения, и держать его тут значило бы тащить криптографию в каждый тест
// базы.
func (db *DB) CreateAdmin(ctx context.Context, actor *int64, login, passwordHash string) (model.Admin, error) {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return model.Admin{}, fmt.Errorf("завести администратора: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`INSERT INTO admins (login, password_hash, created_at) VALUES (?, ?, ?)`,
		login, passwordHash, formatTime(now))
	if err != nil {
		return model.Admin{}, fmt.Errorf("завести администратора %q: %w", login, err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return model.Admin{}, fmt.Errorf("завести администратора %q: %w", login, err)
	}
	if err := logAction(ctx, tx, now, actor, "администратор заведён", "admin", &id, login); err != nil {
		return model.Admin{}, err
	}
	if err := tx.Commit(); err != nil {
		return model.Admin{}, fmt.Errorf("завести администратора %q: %w", login, err)
	}

	return model.Admin{
		ID: id, Login: login, PasswordHash: passwordHash,
		CreatedAt: now.UTC().Truncate(time.Second),
	}, nil
}

// AdminByLogin находит администратора по входному имени.
func (db *DB) AdminByLogin(ctx context.Context, login string) (model.Admin, error) {
	var (
		a          model.Admin
		createdAt  string
		disabledAt sql.NullString
	)
	err := db.QueryRowContext(ctx,
		`SELECT id, login, password_hash, created_at, disabled_at FROM admins WHERE login = ?`, login).
		Scan(&a.ID, &a.Login, &a.PasswordHash, &createdAt, &disabledAt)
	if errors.Is(err, sql.ErrNoRows) {
		return model.Admin{}, ErrNotFound
	}
	if err != nil {
		return model.Admin{}, fmt.Errorf("прочитать администратора %q: %w", login, err)
	}
	a.CreatedAt = readTime(createdAt)
	a.DisabledAt = readNullTime(disabledAt)
	return a, nil
}

// AdminCount говорит, есть ли в панели хоть кто-то.
//
// Нужен первому запуску: панель без администраторов должна предложить завести
// первого, а не показать форму входа, в которую нечего вводить.
func (db *DB) AdminCount(ctx context.Context) (int, error) {
	var count int
	if err := db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM admins WHERE disabled_at IS NULL`).Scan(&count); err != nil {
		return 0, fmt.Errorf("посчитать администраторов: %w", err)
	}
	return count, nil
}

// StartSession заводит сеанс и возвращает токен.
//
// Токен возвращается один раз: в базе лежит только его хеш, поэтому украденная
// база не даёт готовых входов.
func (db *DB) StartSession(ctx context.Context, adminID int64) (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("случайные байты для сеанса: %w", err)
	}
	token := base64.RawURLEncoding.EncodeToString(raw)
	now := time.Now()

	_, err := db.ExecContext(ctx,
		`INSERT INTO sessions (token_hash, admin_id, created_at, expires_at) VALUES (?, ?, ?, ?)`,
		hashToken(token), adminID, formatTime(now), formatTime(now.Add(SessionLifetime)))
	if err != nil {
		return "", fmt.Errorf("завести сеанс: %w", err)
	}
	return token, nil
}

// AdminBySession возвращает администратора по токену сеанса.
func (db *DB) AdminBySession(ctx context.Context, token string) (model.Admin, error) {
	var (
		a          model.Admin
		createdAt  string
		disabledAt sql.NullString
		expiresAt  string
	)
	err := db.QueryRowContext(ctx, `
		SELECT a.id, a.login, a.password_hash, a.created_at, a.disabled_at, s.expires_at
		  FROM sessions s JOIN admins a ON a.id = s.admin_id
		 WHERE s.token_hash = ?`, hashToken(token)).
		Scan(&a.ID, &a.Login, &a.PasswordHash, &createdAt, &disabledAt, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return model.Admin{}, ErrNotFound
	}
	if err != nil {
		return model.Admin{}, fmt.Errorf("прочитать сеанс: %w", err)
	}

	if time.Now().After(readTime(expiresAt)) {
		return model.Admin{}, ErrNotFound
	}
	a.CreatedAt = readTime(createdAt)
	a.DisabledAt = readNullTime(disabledAt)
	if !a.Active() {
		// Погашенный администратор не должен доживать сеанс до конца: гасят
		// его обычно ровно затем, чтобы он перестал входить прямо сейчас.
		return model.Admin{}, ErrDisabled
	}
	return a, nil
}

// EndSession завершает сеанс.
func (db *DB) EndSession(ctx context.Context, token string) error {
	if _, err := db.ExecContext(ctx, `DELETE FROM sessions WHERE token_hash = ?`, hashToken(token)); err != nil {
		return fmt.Errorf("завершить сеанс: %w", err)
	}
	return nil
}

// PurgeExpiredSessions убирает истёкшие сеансы.
func (db *DB) PurgeExpiredSessions(ctx context.Context) error {
	if _, err := db.ExecContext(ctx,
		`DELETE FROM sessions WHERE expires_at < ?`, formatTime(time.Now())); err != nil {
		return fmt.Errorf("убрать истёкшие сеансы: %w", err)
	}
	return nil
}

// DisableAdmin гасит администратора и обрывает его сеансы.
func (db *DB) DisableAdmin(ctx context.Context, actor *int64, id int64) error {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("отключить администратора: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`UPDATE admins SET disabled_at = ? WHERE id = ? AND disabled_at IS NULL`, formatTime(now), id)
	if err != nil {
		return fmt.Errorf("отключить администратора %d: %w", id, err)
	}
	if affected, _ := res.RowsAffected(); affected == 0 {
		return ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM sessions WHERE admin_id = ?`, id); err != nil {
		return fmt.Errorf("оборвать сеансы администратора %d: %w", id, err)
	}
	if err := logAction(ctx, tx, now, actor, "администратор отключён", "admin", &id, ""); err != nil {
		return err
	}
	return tx.Commit()
}

// SetAdminPassword меняет пароль администратора и обрывает его сеансы.
func (db *DB) SetAdminPassword(ctx context.Context, actor *int64, id int64, passwordHash string) error {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("сменить пароль администратора: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx, `UPDATE admins SET password_hash = ? WHERE id = ?`, passwordHash, id)
	if err != nil {
		return fmt.Errorf("сменить пароль администратора %d: %w", id, err)
	}
	if affected, _ := res.RowsAffected(); affected == 0 {
		return ErrNotFound
	}
	// Сеансы обрываются вместе с паролем: пароль меняют и потому, что он утёк,
	// и оставленный жить сеанс сделал бы смену бессмысленной.
	if _, err := tx.ExecContext(ctx, `DELETE FROM sessions WHERE admin_id = ?`, id); err != nil {
		return fmt.Errorf("оборвать сеансы администратора %d: %w", id, err)
	}
	if err := logAction(ctx, tx, now, actor, "пароль администратора сменён", "admin", &id, ""); err != nil {
		return err
	}
	return tx.Commit()
}

// hashToken — что лежит в базе вместо токена.
//
// Голый SHA-256 без растягивания: токен — это 32 случайных байта, а не
// придуманный человеком пароль, и перебирать там нечего.
func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
