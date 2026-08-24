package storage

import (
	"context"
	"errors"
	"testing"
)

func TestCreateAndListNumbers(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	if _, err := db.CreateNumber(ctx, nil, "172", "secret-172", "Первая линия"); err != nil {
		t.Fatalf("CreateNumber: %v", err)
	}
	if _, err := db.CreateNumber(ctx, nil, "173", "secret-173", ""); err != nil {
		t.Fatalf("CreateNumber: %v", err)
	}

	list, err := db.ListNumbers(ctx, false)
	if err != nil {
		t.Fatalf("ListNumbers: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("номеров %d, ожидалось 2", len(list))
	}
	if list[0].Number != "172" || list[0].HolderID != nil {
		t.Errorf("первый номер %q, владелец %v", list[0].Number, list[0].HolderID)
	}
}

func TestNumberIsUnique(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	if _, err := db.CreateNumber(ctx, nil, "172", "secret", ""); err != nil {
		t.Fatalf("CreateNumber: %v", err)
	}
	if _, err := db.CreateNumber(ctx, nil, "172", "other", ""); err == nil {
		t.Fatal("номер 172 завёлся дважды")
	}
}

func TestAssignNumberShowsHolder(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	number, _ := db.CreateNumber(ctx, nil, "172", "secret", "")
	employee, _ := db.CreateEmployee(ctx, nil, "Пётр", nil)

	if err := db.AssignNumber(ctx, nil, employee.ID, number.ID); err != nil {
		t.Fatalf("AssignNumber: %v", err)
	}

	list, err := db.ListNumbers(ctx, false)
	if err != nil {
		t.Fatalf("ListNumbers: %v", err)
	}
	if list[0].HolderName != "Пётр" {
		t.Errorf("владелец %q, ожидался Пётр", list[0].HolderName)
	}

	people, err := db.ListEmployees(ctx, false)
	if err != nil {
		t.Fatalf("ListEmployees: %v", err)
	}
	if people[0].Number != "172" {
		t.Errorf("у сотрудника номер %q, ожидался 172", people[0].Number)
	}
}

// За занятым номером стоит живой человек, снимающий по нему звонки. Отобрать
// его молча нельзя.
func TestAssignTakenNumberFails(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	number, _ := db.CreateNumber(ctx, nil, "172", "secret", "")
	first, _ := db.CreateEmployee(ctx, nil, "Первый", nil)
	second, _ := db.CreateEmployee(ctx, nil, "Второй", nil)

	if err := db.AssignNumber(ctx, nil, first.ID, number.ID); err != nil {
		t.Fatalf("AssignNumber: %v", err)
	}
	err := db.AssignNumber(ctx, nil, second.ID, number.ID)
	if !errors.Is(err, ErrNumberTaken) {
		t.Fatalf("ошибка %v, ожидалась ErrNumberTaken", err)
	}
}

// Повторное закрепление того же номера за тем же человеком — не ошибка:
// администратор мог нажать дважды.
func TestAssignSameNumberTwiceIsFine(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	number, _ := db.CreateNumber(ctx, nil, "172", "secret", "")
	employee, _ := db.CreateEmployee(ctx, nil, "Пётр", nil)

	if err := db.AssignNumber(ctx, nil, employee.ID, number.ID); err != nil {
		t.Fatalf("первое закрепление: %v", err)
	}
	if err := db.AssignNumber(ctx, nil, employee.ID, number.ID); err != nil {
		t.Fatalf("повторное закрепление: %v", err)
	}
}

// Пересадка сотрудника на другой номер освобождает прежний сама.
func TestAssignReleasesPreviousNumber(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	first, _ := db.CreateNumber(ctx, nil, "172", "secret", "")
	second, _ := db.CreateNumber(ctx, nil, "173", "secret", "")
	employee, _ := db.CreateEmployee(ctx, nil, "Пётр", nil)

	if err := db.AssignNumber(ctx, nil, employee.ID, first.ID); err != nil {
		t.Fatalf("первое закрепление: %v", err)
	}
	if err := db.AssignNumber(ctx, nil, employee.ID, second.ID); err != nil {
		t.Fatalf("пересадка: %v", err)
	}

	list, err := db.ListNumbers(ctx, false)
	if err != nil {
		t.Fatalf("ListNumbers: %v", err)
	}
	byNumber := map[string]NumberWithHolder{}
	for _, n := range list {
		byNumber[n.Number] = n
	}
	if byNumber["172"].HolderID != nil {
		t.Error("прежний номер остался закреплённым")
	}
	if byNumber["173"].HolderID == nil {
		t.Error("новый номер не закрепился")
	}
}

// Номер переживает сотрудника: история назначений остаётся.
func TestNumberKeepsAssignmentHistory(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	number, _ := db.CreateNumber(ctx, nil, "172", "secret", "")
	first, _ := db.CreateEmployee(ctx, nil, "Первый", nil)
	second, _ := db.CreateEmployee(ctx, nil, "Второй", nil)

	if err := db.AssignNumber(ctx, nil, first.ID, number.ID); err != nil {
		t.Fatalf("закрепление: %v", err)
	}
	if err := db.DismissEmployee(ctx, nil, first.ID); err != nil {
		t.Fatalf("увольнение: %v", err)
	}
	if err := db.AssignNumber(ctx, nil, second.ID, number.ID); err != nil {
		t.Fatalf("передача номера: %v", err)
	}

	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM number_assignments WHERE number_id = ?`, number.ID).
		Scan(&count); err != nil {
		t.Fatalf("история: %v", err)
	}
	if count != 2 {
		t.Errorf("записей в истории %d, ожидалось 2", count)
	}
}

// Увольнение — одно действие: номер освобождён, активации отозваны.
func TestDismissReleasesNumberAndRevokesActivations(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	number, _ := db.CreateNumber(ctx, nil, "172", "secret", "")
	employee, _ := db.CreateEmployee(ctx, nil, "Пётр", nil)
	if err := db.AssignNumber(ctx, nil, employee.ID, number.ID); err != nil {
		t.Fatalf("закрепление: %v", err)
	}

	if _, err := db.Exec(`INSERT INTO presets (id, public_id, name, created_at)
		VALUES (1, '6D1F5A20-0000-4000-8000-000000000001', 'Менеджер', '2026-08-24T09:00:00Z')`); err != nil {
		t.Fatalf("предустановка: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO activations
		(employee_id, preset_id, key_hash, key_prefix, object_key, installation_id, issued_at, expires_at)
		VALUES (?, 1, 'hash', 'K7M2', 'obj', 'inst', '2026-08-24T09:00:00Z', '2026-08-26T09:00:00Z')`,
		employee.ID); err != nil {
		t.Fatalf("активация: %v", err)
	}

	if err := db.DismissEmployee(ctx, nil, employee.ID); err != nil {
		t.Fatalf("DismissEmployee: %v", err)
	}

	var revoked int
	if err := db.QueryRow(`SELECT COUNT(*) FROM activations WHERE revoked_at IS NOT NULL`).Scan(&revoked); err != nil {
		t.Fatalf("активации: %v", err)
	}
	if revoked != 1 {
		t.Errorf("отозвано активаций %d, ожидалась 1", revoked)
	}

	list, _ := db.ListNumbers(ctx, false)
	if list[0].HolderID != nil {
		t.Error("номер уволенного остался закреплённым")
	}
}

func TestAssignToDismissedFails(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	number, _ := db.CreateNumber(ctx, nil, "172", "secret", "")
	employee, _ := db.CreateEmployee(ctx, nil, "Пётр", nil)
	if err := db.DismissEmployee(ctx, nil, employee.ID); err != nil {
		t.Fatalf("увольнение: %v", err)
	}

	err := db.AssignNumber(ctx, nil, employee.ID, number.ID)
	if !errors.Is(err, ErrEmployeeDismissed) {
		t.Fatalf("ошибка %v, ожидалась ErrEmployeeDismissed", err)
	}
}

func TestRetiredNumberIsNotAssignable(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	number, _ := db.CreateNumber(ctx, nil, "172", "secret", "")
	employee, _ := db.CreateEmployee(ctx, nil, "Пётр", nil)

	if err := db.RetireNumber(ctx, nil, number.ID); err != nil {
		t.Fatalf("RetireNumber: %v", err)
	}
	err := db.AssignNumber(ctx, nil, employee.ID, number.ID)
	if !errors.Is(err, ErrNumberRetired) {
		t.Fatalf("ошибка %v, ожидалась ErrNumberRetired", err)
	}
}

// Каждое действие оставляет строку в журнале — на этом держится ответ на
// «кто это сделал» при равных администраторах.
func TestActionsAreLogged(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	if _, err := db.Exec(`INSERT INTO admins (id, login, password_hash, created_at)
		VALUES (7, 'eugene', 'hash', '2026-08-24T09:00:00Z')`); err != nil {
		t.Fatalf("администратор: %v", err)
	}
	actor := int64(7)

	number, _ := db.CreateNumber(ctx, &actor, "172", "secret", "")
	employee, _ := db.CreateEmployee(ctx, &actor, "Пётр", nil)
	if err := db.AssignNumber(ctx, &actor, employee.ID, number.ID); err != nil {
		t.Fatalf("закрепление: %v", err)
	}

	entries, err := db.AuditPage(ctx, 10)
	if err != nil {
		t.Fatalf("AuditPage: %v", err)
	}
	if len(entries) != 3 {
		t.Fatalf("строк журнала %d, ожидалось 3", len(entries))
	}
	if entries[0].Action != "номер закреплён" {
		t.Errorf("свежая строка %q", entries[0].Action)
	}
	if entries[0].AdminID == nil || *entries[0].AdminID != actor {
		t.Errorf("автор строки %v, ожидался %d", entries[0].AdminID, actor)
	}
}

// Пароль номера в журнал не попадает: журнал читают чаще, чем карточку.
func TestPasswordsStayOutOfAuditLog(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	number, _ := db.CreateNumber(ctx, nil, "172", "очень-секретный-пароль", "")
	if err := db.SetNumberPassword(ctx, nil, number.ID, "новый-секрет"); err != nil {
		t.Fatalf("SetNumberPassword: %v", err)
	}

	entries, err := db.AuditPage(ctx, 10)
	if err != nil {
		t.Fatalf("AuditPage: %v", err)
	}
	for _, e := range entries {
		if e.Details == "очень-секретный-пароль" || e.Details == "новый-секрет" {
			t.Fatalf("пароль попал в журнал: %q", e.Details)
		}
	}

	stored, err := db.NumberByID(ctx, number.ID)
	if err != nil {
		t.Fatalf("NumberByID: %v", err)
	}
	if stored.SIPPassword != "новый-секрет" {
		t.Errorf("пароль %q, ожидался новый-секрет", stored.SIPPassword)
	}
}
