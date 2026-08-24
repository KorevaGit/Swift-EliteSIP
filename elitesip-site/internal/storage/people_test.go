package storage

import (
	"context"
	"errors"
	"testing"

	"github.com/koreva/elitesip-site/internal/model"
)

func person(name, number, password string) model.Employee {
	return model.Employee{Name: name, Number: number, SIPPassword: password}
}

// Сотрудник заводится одной записью — вместе с номером и паролем.
func TestCreateEmployeeWithNumber(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	created, err := db.CreateEmployee(ctx, nil, person("Пётр Смирнов", "172", "секрет-172"))
	if err != nil {
		t.Fatalf("CreateEmployee: %v", err)
	}
	if created.ID == 0 || created.CreatedAt.IsZero() {
		t.Fatalf("вернулась пустая запись: %+v", created)
	}

	stored, err := db.EmployeeByID(ctx, created.ID)
	if err != nil {
		t.Fatalf("EmployeeByID: %v", err)
	}
	if stored.Number != "172" || stored.SIPPassword != "секрет-172" {
		t.Errorf("номер %q, пароль %q", stored.Number, stored.SIPPassword)
	}
}

// Двое на одном добавочном — это двое, снимающих звонки друг друга.
func TestNumberIsTakenByOneEmployee(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	if _, err := db.CreateEmployee(ctx, nil, person("Первый", "172", "секрет")); err != nil {
		t.Fatalf("первый: %v", err)
	}
	_, err := db.CreateEmployee(ctx, nil, person("Второй", "172", "другой"))
	if !errors.Is(err, ErrNumberTaken) {
		t.Fatalf("ошибка %v, ожидалась ErrNumberTaken", err)
	}
}

// Незаполненных номеров может быть сколько угодно: пустая строка — это «пир на
// АТС ещё не подняли», а не значение.
func TestEmptyNumbersDoNotCollide(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	if _, err := db.CreateEmployee(ctx, nil, person("Первый", "", "")); err != nil {
		t.Fatalf("первый: %v", err)
	}
	if _, err := db.CreateEmployee(ctx, nil, person("Второй", "", "")); err != nil {
		t.Fatalf("второй без номера не завёлся: %v", err)
	}
}

// Номер освобождается вместе с человеком: удалили — можно отдавать следующему.
func TestNumberIsFreeAfterDeletion(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	first, err := db.CreateEmployee(ctx, nil, person("Первый", "172", "секрет"))
	if err != nil {
		t.Fatalf("первый: %v", err)
	}
	if err := db.DeleteEmployee(ctx, nil, first.ID); err != nil {
		t.Fatalf("DeleteEmployee: %v", err)
	}
	if _, err := db.CreateEmployee(ctx, nil, person("Второй", "172", "новый")); err != nil {
		t.Fatalf("номер не освободился: %v", err)
	}
}

// Удаление стирает карточку, активации и отметки о связи разом. Порознь это
// три дела, о двух из которых в спешке забывают.
func TestDeleteEmployeeTakesActivationsWithIt(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	employee, _ := db.CreateEmployee(ctx, nil, person("Пётр", "172", "секрет"))
	seedActivation(t, db, employee.ID)

	if err := db.DeleteEmployee(ctx, nil, employee.ID); err != nil {
		t.Fatalf("DeleteEmployee: %v", err)
	}

	for _, table := range []string{"employees", "activations", "checkins"} {
		var count int
		if err := db.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&count); err != nil {
			t.Fatalf("%s: %v", table, err)
		}
		if count != 0 {
			t.Errorf("в %s осталось строк: %d", table, count)
		}
	}

	if _, err := db.EmployeeByID(ctx, employee.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("карточка читается после удаления: %v", err)
	}
}

// Единственное, что переживает удаление, — строка журнала с именем и номером.
// На неё опирается разбор жалобы через неделю после ухода человека.
func TestDeletionLeavesNameAndNumberInAudit(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	employee, _ := db.CreateEmployee(ctx, nil, person("Пётр Смирнов", "172", "секрет"))
	if err := db.DeleteEmployee(ctx, nil, employee.ID); err != nil {
		t.Fatalf("DeleteEmployee: %v", err)
	}

	entries, err := db.AuditPage(ctx, 10)
	if err != nil {
		t.Fatalf("AuditPage: %v", err)
	}
	if entries[0].Action != "сотрудник удалён" {
		t.Fatalf("свежая строка %q", entries[0].Action)
	}
	if entries[0].Details != "Пётр Смирнов, номер 172" {
		t.Errorf("подробности %q — по ним не ответить, кто сидел на 172", entries[0].Details)
	}
	// Ссылаться некуда: строки, на которую указывал бы entity_id, больше нет.
	if entries[0].EntityID != nil {
		t.Errorf("строка журнала ссылается на удалённую карточку: %v", *entries[0].EntityID)
	}
}

func TestUpdateEmployee(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	employee, _ := db.CreateEmployee(ctx, nil, person("Пётр", "172", "секрет"))
	employee.Name = "Пётр Смирнов"
	employee.Number = "173"
	employee.SIPPassword = "новый-секрет"

	if err := db.UpdateEmployee(ctx, nil, employee); err != nil {
		t.Fatalf("UpdateEmployee: %v", err)
	}

	stored, _ := db.EmployeeByID(ctx, employee.ID)
	if stored.Name != "Пётр Смирнов" || stored.Number != "173" || stored.SIPPassword != "новый-секрет" {
		t.Errorf("сохранилось не всё: %+v", stored)
	}
}

// Пересадка на чужой номер отвергается: за ним стоит живой человек.
func TestUpdateToTakenNumberFails(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	db.CreateEmployee(ctx, nil, person("Первый", "172", "секрет"))
	second, _ := db.CreateEmployee(ctx, nil, person("Второй", "173", "секрет"))

	second.Number = "172"
	if err := db.UpdateEmployee(ctx, nil, second); !errors.Is(err, ErrNumberTaken) {
		t.Fatalf("ошибка %v, ожидалась ErrNumberTaken", err)
	}
}

// Поиск идёт по имени и по номеру сразу: администратор помнит либо одно, либо
// другое, и заставлять его выбирать поле незачем.
func TestListEmployeesSearchesNameAndNumber(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	db.CreateEmployee(ctx, nil, person("Пётр Смирнов", "172", "секрет"))
	db.CreateEmployee(ctx, nil, person("Анна Иванова", "173", "секрет"))

	byName, err := db.ListEmployees(ctx, EmployeeFilter{Query: "Смирнов"})
	if err != nil {
		t.Fatalf("ListEmployees: %v", err)
	}
	if len(byName) != 1 || byName[0].Name != "Пётр Смирнов" {
		t.Errorf("поиск по части фамилии нашёл %d строк", len(byName))
	}

	byNumber, _ := db.ListEmployees(ctx, EmployeeFilter{Query: "173"})
	if len(byNumber) != 1 || byNumber[0].Name != "Анна Иванова" {
		t.Errorf("поиск по номеру нашёл %d строк", len(byNumber))
	}
}

func TestListEmployeesFiltersByPreset(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	with := person("С предустановкой", "172", "секрет")
	with.PresetID = &preset.ID
	db.CreateEmployee(ctx, nil, with)
	db.CreateEmployee(ctx, nil, person("Без предустановки", "173", "секрет"))

	list, err := db.ListEmployees(ctx, EmployeeFilter{PresetID: &preset.ID})
	if err != nil {
		t.Fatalf("ListEmployees: %v", err)
	}
	if len(list) != 1 || list[0].PresetName != "Менеджер" {
		t.Errorf("отбор по предустановке дал %d строк", len(list))
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

	employee, err := db.CreateEmployee(ctx, &actor, person("Пётр", "172", "секрет"))
	if err != nil {
		t.Fatalf("CreateEmployee: %v", err)
	}
	employee.Number = "173"
	if err := db.UpdateEmployee(ctx, &actor, employee); err != nil {
		t.Fatalf("UpdateEmployee: %v", err)
	}

	entries, err := db.AuditPage(ctx, 10)
	if err != nil {
		t.Fatalf("AuditPage: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("строк журнала %d, ожидалось 2", len(entries))
	}
	if entries[0].Action != "карточка изменена" {
		t.Errorf("свежая строка %q", entries[0].Action)
	}
	if entries[0].AdminID == nil || *entries[0].AdminID != actor {
		t.Errorf("автор строки %v, ожидался %d", entries[0].AdminID, actor)
	}
}

// SIP-пароль в журнал не попадает: журнал читают чаще, чем карточку.
func TestPasswordsStayOutOfAuditLog(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	employee, _ := db.CreateEmployee(ctx, nil, person("Пётр", "172", "очень-секретный-пароль"))
	employee.SIPPassword = "новый-секрет"
	if err := db.UpdateEmployee(ctx, nil, employee); err != nil {
		t.Fatalf("UpdateEmployee: %v", err)
	}
	if err := db.DeleteEmployee(ctx, nil, employee.ID); err != nil {
		t.Fatalf("DeleteEmployee: %v", err)
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
}

// seedActivation кладёт активацию с отметкой о связи — то, что при удалении
// сотрудника обязано уйти каскадом.
func seedActivation(t *testing.T, db *DB, employeeID int64) {
	t.Helper()

	if _, err := db.Exec(`INSERT INTO presets (id, public_id, name, created_at)
		VALUES (1, '6D1F5A20-0000-4000-8000-000000000001', 'Менеджер', '2026-08-24T09:00:00Z')`); err != nil {
		t.Fatalf("предустановка: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO activations
		(employee_id, preset_id, key_hash, key_prefix, object_key, installation_id, issued_at, expires_at)
		VALUES (?, 1, 'hash', 'K7M2', 'obj', 'inst', '2026-08-24T09:00:00Z', '2026-08-26T09:00:00Z')`,
		employeeID); err != nil {
		t.Fatalf("активация: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO checkins (installation_id, last_seen_at)
		VALUES ('inst', '2026-08-24T10:00:00Z')`); err != nil {
		t.Fatalf("отметка о связи: %v", err)
	}
}
