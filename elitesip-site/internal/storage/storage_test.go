package storage

import (
	"path/filepath"
	"testing"
)

func openTemp(t *testing.T) *DB {
	t.Helper()
	db, err := Open(filepath.Join(t.TempDir(), "panel.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

// Схема применяется целиком: в файле несколько десятков команд, и драйвер
// обязан выполнить их все, а не только первую.
func TestOpenCreatesSchema(t *testing.T) {
	db := openTemp(t)

	want := []string{
		"admins", "sessions", "employees",
		"presets", "preset_revisions", "activations", "checkins", "audit_log",
	}
	for _, table := range want {
		var name string
		err := db.QueryRow(
			"SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", table,
		).Scan(&name)
		if err != nil {
			t.Errorf("таблицы %s нет: %v", table, err)
		}
	}

	var version int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		t.Fatalf("PRAGMA user_version: %v", err)
	}
	if version != schemaVersion {
		t.Errorf("версия схемы %d, ожидалась %d", version, schemaVersion)
	}
}

// Повторное открытие уже настроенной базы миграцию не повторяет.
func TestOpenIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "panel.db")

	first, err := Open(path)
	if err != nil {
		t.Fatalf("первое открытие: %v", err)
	}
	first.Close()

	second, err := Open(path)
	if err != nil {
		t.Fatalf("второе открытие: %v", err)
	}
	second.Close()
}

// Сборка старее базы должна отказываться работать, а не портить данные тише.
func TestOpenRefusesNewerSchema(t *testing.T) {
	path := filepath.Join(t.TempDir(), "panel.db")

	db, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if _, err := db.Exec("PRAGMA user_version = 999"); err != nil {
		t.Fatalf("подмена версии: %v", err)
	}
	db.Close()

	if _, err := Open(path); err == nil {
		t.Fatal("база из будущего открылась без ошибки")
	}
}

// Ссылочная целостность включена: активация несуществующему сотруднику должна
// отвергаться базой, а не обнаруживаться потом пустым экраном.
func TestForeignKeysAreEnforced(t *testing.T) {
	db := openTemp(t)

	if _, err := db.Exec(`INSERT INTO presets (id, public_id, name, created_at)
		VALUES (1, '6D1F5A20-0000-4000-8000-000000000001', 'Менеджер', '2026-08-24T09:00:00Z')`); err != nil {
		t.Fatalf("предустановка: %v", err)
	}

	_, err := db.Exec(`INSERT INTO activations
		(employee_id, preset_id, key_hash, key_prefix, object_key, installation_id, issued_at, expires_at)
		VALUES (99, 1, 'hash', 'K7M2', 'obj', 'inst', '2026-08-24T09:00:00Z', '2026-08-26T09:00:00Z')`)
	if err == nil {
		t.Fatal("активация несуществующему сотруднику прошла")
	}
}
