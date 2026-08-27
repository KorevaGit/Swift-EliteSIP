package sand

import (
	"bytes"
	"context"
	"testing"
	"time"
)

func TestXLSXRoundTripCreatesCleanSandbox(t *testing.T) {
	rows := []EmployeeExchange{{Name: "Петров Пётр", Login: "petrov", Password: "secret", BitrixID: "12817", Extension: "301"}, {Name: "Иванова Анна"}}
	var file bytes.Buffer
	if err := WriteEmployeesXLSX(&file, rows); err != nil {
		t.Fatal(err)
	}
	read, err := ReadEmployeesXLSX(bytes.NewReader(file.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	db := openTemp(t)
	created, err := db.ImportSandbox(context.Background(), support(), "Кочура", Office, read)
	if err != nil {
		t.Fatal(err)
	}
	detail, err := db.GetSandbox(context.Background(), created.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(detail.Workbench) != 2 || detail.Workbench[0].BitrixID != "12817" || detail.Workbench[0].Extension != "301" {
		t.Fatalf("импорт разошёлся: %#v", detail.Workbench)
	}
	if len(detail.Marks) != 0 || detail.Workbench[0].Outcome != "" || len(detail.Workbench[0].Marks) != 0 {
		t.Error("импорт перенёс историю или отметки")
	}
}

func TestCSVExportContainsPassword(t *testing.T) {
	var out bytes.Buffer
	err := WriteEmployeesCSV(&out, []EmployeeExchange{{Name: "Пётр", Password: "secret"}})
	if err != nil {
		t.Fatal(err)
	}
	if got := out.String(); !bytes.Contains([]byte(got), []byte("Пароль")) || !bytes.Contains([]byte(got), []byte("secret")) {
		t.Fatalf("CSV: %q", got)
	}
}

func TestPurgeRejectedAnonymizesPersonalData(t *testing.T) {
	db, s, eid := employeeFixture(t, 2)
	ctx := context.Background()
	db.SaveEmployeeBitrix(ctx, support(), s.ID, eid, "p", "secret", "91", false)
	db.AssignEmployeeExtension(ctx, support(), s.ID, eid, "301")
	db.SetEmployeeOutcome(ctx, support(), s.ID, eid, OutcomeRejected)
	old := time.Now().Add(-40 * 24 * time.Hour)
	db.Exec(`UPDATE sand_employees SET outcome_at=? WHERE id=?`, formatTime(old), eid)
	n, err := db.PurgeRejected(ctx, time.Now())
	if err != nil || n != 1 {
		t.Fatalf("purge=%d %v", n, err)
	}
	d, err := db.GetEmployee(ctx, s.ID, eid)
	if err != nil {
		t.Fatal(err)
	}
	if d.Name != "Удалённый сотрудник" || d.BitrixID != "" || d.BitrixPass != "" || d.Outcome != OutcomeRejected {
		t.Fatalf("обезличено неверно: %#v", d)
	}
}
