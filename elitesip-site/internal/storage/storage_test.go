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
		"admins", "sessions", "numbers", "employees", "number_assignments",
		"presets", "preset_revisions", "activations", "checkins",
		"worker_log_cursor", "audit_log",
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

// Два действующих владельца одного номера — это двое, снимающих звонки друг
// друга. Правило держит база, и проверяется оно здесь.
func TestNumberHasSingleHolder(t *testing.T) {
	db := openTemp(t)
	seedTwoEmployeesOneNumber(t, db)

	_, err := db.Exec(`INSERT INTO number_assignments
		(number_id, employee_id, assigned_at) VALUES (1, 1, '2026-08-24T10:00:00Z')`)
	if err != nil {
		t.Fatalf("первое назначение: %v", err)
	}

	_, err = db.Exec(`INSERT INTO number_assignments
		(number_id, employee_id, assigned_at) VALUES (1, 2, '2026-08-24T11:00:00Z')`)
	if err == nil {
		t.Fatal("номер достался двоим одновременно")
	}
}

// Передача номера новому сотруднику после освобождения проходить обязана —
// иначе правило выше запрещало бы не двойное владение, а саму передачу.
func TestNumberCanBeHandedOver(t *testing.T) {
	db := openTemp(t)
	seedTwoEmployeesOneNumber(t, db)

	if _, err := db.Exec(`INSERT INTO number_assignments
		(number_id, employee_id, assigned_at, released_at)
		VALUES (1, 1, '2026-03-01T10:00:00Z', '2026-08-01T10:00:00Z')`); err != nil {
		t.Fatalf("прошлое назначение: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO number_assignments
		(number_id, employee_id, assigned_at) VALUES (1, 2, '2026-08-24T10:00:00Z')`); err != nil {
		t.Fatalf("передача номера: %v", err)
	}

	var holder int
	err := db.QueryRow(`SELECT employee_id FROM number_assignments
		WHERE number_id = 1 AND released_at IS NULL`).Scan(&holder)
	if err != nil {
		t.Fatalf("действующий владелец: %v", err)
	}
	if holder != 2 {
		t.Errorf("номер у сотрудника %d, ожидался 2", holder)
	}
}

// У сотрудника один действующий номер — обратная половина того же правила.
func TestEmployeeHasSingleNumber(t *testing.T) {
	db := openTemp(t)
	seedTwoEmployeesOneNumber(t, db)

	if _, err := db.Exec(`INSERT INTO numbers (id, number, sip_password, created_at)
		VALUES (2, '173', 'secret-173', '2026-08-24T09:00:00Z')`); err != nil {
		t.Fatalf("второй номер: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO number_assignments
		(number_id, employee_id, assigned_at) VALUES (1, 1, '2026-08-24T10:00:00Z')`); err != nil {
		t.Fatalf("первое назначение: %v", err)
	}

	_, err := db.Exec(`INSERT INTO number_assignments
		(number_id, employee_id, assigned_at) VALUES (2, 1, '2026-08-24T11:00:00Z')`)
	if err == nil {
		t.Fatal("у сотрудника оказалось два действующих номера")
	}
}

// Ссылочная целостность включена: назначение несуществующему сотруднику
// должно отвергаться базой, а не обнаруживаться потом пустым экраном.
func TestForeignKeysAreEnforced(t *testing.T) {
	db := openTemp(t)
	seedTwoEmployeesOneNumber(t, db)

	_, err := db.Exec(`INSERT INTO number_assignments
		(number_id, employee_id, assigned_at) VALUES (1, 99, '2026-08-24T10:00:00Z')`)
	if err == nil {
		t.Fatal("назначение несуществующему сотруднику прошло")
	}
}

func seedTwoEmployeesOneNumber(t *testing.T, db *DB) {
	t.Helper()

	if _, err := db.Exec(`INSERT INTO numbers (id, number, sip_password, created_at)
		VALUES (1, '172', 'secret-172', '2026-08-24T09:00:00Z')`); err != nil {
		t.Fatalf("номер: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO employees (id, name, created_at) VALUES
		(1, 'Первый', '2026-08-24T09:00:00Z'),
		(2, 'Второй', '2026-08-24T09:00:00Z')`); err != nil {
		t.Fatalf("сотрудники: %v", err)
	}
}
