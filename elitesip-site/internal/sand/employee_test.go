package sand

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"testing"
)

func employeeFixture(t *testing.T, deals int) (*DB, Sandbox, int64) {
	t.Helper()
	db := openTemp(t)
	in := office("Кочура", "Пётр")
	in.Extensions = []string{"301", "302"}
	for i := 1; i <= deals; i++ {
		in.Deals = append(in.Deals, fmt.Sprint(1000+i))
	}
	s, e := db.CreateSandbox(context.Background(), support(), in)
	if e != nil {
		t.Fatal(e)
	}
	d, _ := db.GetSandbox(context.Background(), s.ID)
	return db, s, d.Employees[0].ID
}

func TestEmployeeSourcesOfTruthAndDependencies(t *testing.T) {
	db, s, eid := employeeFixture(t, 0)
	ctx := context.Background()
	if _, e := db.ToggleEmployeeMark(ctx, support(), s.ID, eid, "libra", false); !errors.Is(e, ErrTaskBlocked) {
		t.Fatalf("libra без аккаунта: %v", e)
	}
	if e := db.SaveEmployeeBitrix(ctx, support(), s.ID, eid, "petya", "secret", "12817", false); e != nil {
		t.Fatal(e)
	}
	if e := db.AssignEmployeeExtension(ctx, support(), s.ID, eid, "301"); e != nil {
		t.Fatal(e)
	}
	if e := db.SetEmployeeOutcome(ctx, support(), s.ID, eid, OutcomeHired); e != nil {
		t.Fatal(e)
	}
	d, e := db.GetEmployee(ctx, s.ID, eid)
	if e != nil {
		t.Fatal(e)
	}
	for _, key := range []string{"bitrix", "extension", "outcome"} {
		if !d.Done(key) {
			t.Errorf("%s не вычислен из данных", key)
		}
	}
	if d.LibraSQL() == "" {
		t.Error("SQL Libra не собран")
	}
}

func TestEmployeeUnmarkRequiresCascadeConfirmation(t *testing.T) {
	db, s, eid := employeeFixture(t, 0)
	ctx := context.Background()
	db.SaveEmployeeBitrix(ctx, support(), s.ID, eid, "p", "x", "12", false)
	db.ToggleEmployeeMark(ctx, support(), s.ID, eid, "libra", false)
	if e := db.SaveEmployeeBitrix(ctx, support(), s.ID, eid, "", "", "", false); e == nil {
		t.Fatal("аккаунт очищен без подтверждения")
	}
	if e := db.SaveEmployeeBitrix(ctx, support(), s.ID, eid, "", "", "", true); e != nil {
		t.Fatal(e)
	}
	d, _ := db.GetEmployee(ctx, s.ID, eid)
	if d.Done("bitrix") || d.Done("libra") {
		t.Error("каскад снят не полностью")
	}
}

func TestDealBatchesRepeatUntilImportedAndNeverOverlap(t *testing.T) {
	db, s, eid := employeeFixture(t, 450)
	ctx := context.Background()
	db.SaveEmployeeBitrix(ctx, support(), s.ID, eid, "p", "x", "77", false)
	a, e := db.IssueDeals(ctx, support(), s.ID, eid, 300)
	if e != nil {
		t.Fatal(e)
	}
	again, e := db.IssueDeals(ctx, support(), s.ID, eid, 100)
	if e != nil {
		t.Fatal(e)
	}
	if a.ID != again.ID || !reflect.DeepEqual(a.Deals, again.Deals) {
		t.Fatal("повтор отдал другую порцию")
	}
	if e := db.MarkBatchImported(ctx, support(), s.ID, eid, a.ID); e != nil {
		t.Fatal(e)
	}
	b, e := db.IssueDeals(ctx, support(), s.ID, eid, 100)
	if e != nil || len(b.Deals) != 100 {
		t.Fatalf("вторая порция: %d, %v", len(b.Deals), e)
	}
	seen := map[string]bool{}
	for _, id := range a.Deals {
		seen[id] = true
	}
	for _, id := range b.Deals {
		if seen[id] {
			t.Fatalf("сделка %s попала в обе порции", id)
		}
	}
	if a.Size != 300 || b.Size != 100 {
		t.Fatalf("размеры порций %d и %d", a.Size, b.Size)
	}
}

func TestRejectedEmployeeReleasesExtension(t *testing.T) {
	db, s, eid := employeeFixture(t, 0)
	ctx := context.Background()
	db.SaveEmployeeBitrix(ctx, support(), s.ID, eid, "p", "x", "99", false)
	db.AssignEmployeeExtension(ctx, support(), s.ID, eid, "301")
	if e := db.SetEmployeeOutcome(ctx, support(), s.ID, eid, OutcomeRejected); e != nil {
		t.Fatal(e)
	}
	d, _ := db.GetEmployee(ctx, s.ID, eid)
	if d.Extension != "" {
		t.Error("номер не освобождён")
	}
	if !d.Done("outcome") {
		t.Error("увольнение не завершено")
	}
}
