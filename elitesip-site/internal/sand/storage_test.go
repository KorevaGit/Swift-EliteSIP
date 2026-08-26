package sand

import (
	"path/filepath"
	"testing"
)

const testTime = "2026-08-26T09:00:00Z"

func openTemp(t *testing.T) *DB {
	t.Helper()
	db, err := Open(filepath.Join(t.TempDir(), "sand.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func addSandbox(t *testing.T, db *DB, rop string) int64 {
	t.Helper()
	res, err := db.Exec(`INSERT INTO sandboxes (rop, format, created_at) VALUES (?, 'office', ?)`, rop, testTime)
	if err != nil {
		t.Fatalf("создать песок %s: %v", rop, err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("ID песка: %v", err)
	}
	return id
}

func addEmployee(t *testing.T, db *DB, sandboxID int64, name, bitrixID string) int64 {
	t.Helper()
	res, err := db.Exec(`INSERT INTO sand_employees (sandbox_id, name, bitrix_id) VALUES (?, ?, ?)`,
		sandboxID, name, bitrixID)
	if err != nil {
		t.Fatalf("создать сотрудника %s: %v", name, err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("ID сотрудника: %v", err)
	}
	return id
}

func TestOpenCreatesSchema(t *testing.T) {
	db := openTemp(t)
	want := []string{
		"sandboxes", "sandbox_marks", "sandbox_extensions", "sand_employees",
		"employee_marks", "sandbox_deals", "deal_batches", "sandbox_comments",
	}
	for _, table := range want {
		var name string
		if err := db.QueryRow(
			"SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", table,
		).Scan(&name); err != nil {
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

func TestOpenIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sand.db")
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

func TestOpenRefusesNewerSchema(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sand.db")
	db, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if _, err := db.Exec("PRAGMA user_version = 999"); err != nil {
		t.Fatalf("подмена версии: %v", err)
	}
	db.Close()

	if _, err := Open(path); err == nil {
		t.Fatal("база песочницы из будущего открылась без ошибки")
	}
}

func TestOneActiveSandboxPerROP(t *testing.T) {
	db := openTemp(t)
	first := addSandbox(t, db, "Кочура")
	if _, err := db.Exec(`INSERT INTO sandboxes (rop, format, created_at) VALUES ('Кочура', 'remote', ?)`, testTime); err == nil {
		t.Fatal("второй активный песок одного РОПа создан")
	}
	if _, err := db.Exec(`UPDATE sandboxes SET closed_at = ? WHERE id = ?`, testTime, first); err != nil {
		t.Fatalf("закрыть первый песок: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO sandboxes (rop, format, created_at) VALUES ('Кочура', 'remote', ?)`, testTime); err != nil {
		t.Fatalf("новый песок после закрытия прежнего не создан: %v", err)
	}
}

func TestOneExtensionPerEmployee(t *testing.T) {
	db := openTemp(t)
	sandboxID := addSandbox(t, db, "Власов")
	employeeID := addEmployee(t, db, sandboxID, "Иван Петров", "1001")
	if _, err := db.Exec(`INSERT INTO sandbox_extensions (sandbox_id, number, employee_id) VALUES (?, '301', ?)`, sandboxID, employeeID); err != nil {
		t.Fatalf("назначить первый номер: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO sandbox_extensions (sandbox_id, number, employee_id) VALUES (?, '302', ?)`, sandboxID, employeeID); err == nil {
		t.Fatal("одному сотруднику назначены два номера")
	}
}

func TestOneActivePoolPerExtension(t *testing.T) {
	db := openTemp(t)
	first := addSandbox(t, db, "Макаренко")
	second := addSandbox(t, db, "Шахалиева")
	if _, err := db.Exec(`INSERT INTO sandbox_extensions (sandbox_id, number) VALUES (?, '401')`, first); err != nil {
		t.Fatalf("добавить номер в первый пул: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO sandbox_extensions (sandbox_id, number) VALUES (?, '401')`, second); err == nil {
		t.Fatal("один номер попал в два активных пула")
	}
	if _, err := db.Exec(`UPDATE sandbox_extensions SET released_at = ? WHERE sandbox_id = ? AND number = '401'`, testTime, first); err != nil {
		t.Fatalf("освободить номер: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO sandbox_extensions (sandbox_id, number) VALUES (?, '401')`, second); err != nil {
		t.Fatalf("освобождённый номер не попал в новый пул: %v", err)
	}
}

func TestBitrixIDIsUnique(t *testing.T) {
	db := openTemp(t)
	first := addSandbox(t, db, "Марк")
	second := addSandbox(t, db, "Скрылева")
	addEmployee(t, db, first, "Анна Первая", "12817")
	if _, err := db.Exec(`INSERT INTO sand_employees (sandbox_id, name, bitrix_id) VALUES (?, 'Анна Вторая', '12817')`, second); err == nil {
		t.Fatal("один ID Битрикса появился у двух сотрудников")
	}
	if _, err := db.Exec(`INSERT INTO sand_employees (sandbox_id, name, bitrix_id) VALUES (?, 'Без аккаунта', '')`, second); err != nil {
		t.Fatalf("первый пустой ID запрещён: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO sand_employees (sandbox_id, name, bitrix_id) VALUES (?, 'Тоже без аккаунта', '')`, second); err != nil {
		t.Fatalf("повторный пустой ID запрещён: %v", err)
	}
}

func TestForeignKeysAreEnforced(t *testing.T) {
	db := openTemp(t)
	if _, err := db.Exec(`INSERT INTO sand_employees (sandbox_id, name) VALUES (999, 'Нет песка')`); err == nil {
		t.Fatal("сотрудник несуществующего песка создан")
	}
}
