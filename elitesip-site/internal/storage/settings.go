package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Ключи настроек панели.
const (
	// SettingLastPreset — предустановка, выбранная в прошлый раз. Подставляется
	// в форму заведения сотрудника.
	//
	// Хранится здесь, а не угадывается по последнему заведённому: иначе после
	// единственного заведения секретаря все следующие стажёры молча поехали бы
	// по её предустановке.
	SettingLastPreset = "last_preset_id"

	// SettingAppLink — откуда сотруднику качать приложение. Уезжает в готовое
	// сообщение, которое администратор копирует и шлёт.
	//
	// Хранится здесь, а не вшито в панель: канал раздачи может смениться, а
	// выпускать ради этого новую сборку панели незачем.
	SettingAppLink = "app_link"
)

// Setting возвращает значение настройки. Отсутствующая настройка — пустая
// строка без ошибки: панель на свежей базе должна открываться, а не падать.
func (db *DB) Setting(ctx context.Context, key string) (string, error) {
	var value string
	err := db.QueryRowContext(ctx, `SELECT value FROM settings WHERE key = ?`, key).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("прочитать настройку %q: %w", key, err)
	}
	return value, nil
}

// SetSetting записывает настройку.
func (db *DB) SetSetting(ctx context.Context, actor *int64, key, value string) error {
	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("записать настройку: %w", err)
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx,
		`INSERT INTO settings (key, value) VALUES (?, ?)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value); err != nil {
		return fmt.Errorf("записать настройку %q: %w", key, err)
	}

	// Значение в журнал не идёт: под этим ключом лежит пароль.
	if err := logAction(ctx, tx, now, actor, "настройка изменена", "setting", nil, key); err != nil {
		return err
	}
	return tx.Commit()
}
