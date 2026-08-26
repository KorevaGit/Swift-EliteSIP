package sand

import (
	"context"
	"errors"
	"testing"
)

func TestSandboxDetailContainsTasksPeopleAndComments(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()
	created, err := db.CreateSandbox(ctx, support(), office("Кочура", "Пётр", "Анна"))
	if err != nil {
		t.Fatalf("CreateSandbox: %v", err)
	}
	if err := db.AddSandboxComment(ctx, support(), created.ID, "  Ждём гарнитуры  "); err != nil {
		t.Fatalf("AddSandboxComment: %v", err)
	}

	detail, err := db.GetSandbox(ctx, created.ID)
	if err != nil {
		t.Fatalf("GetSandbox: %v", err)
	}
	if detail.ROP != "Кочура" || len(detail.Tasks) != len(SandboxTasks(Office)) {
		t.Fatalf("не та карточка: %#v", detail)
	}
	if len(detail.Employees) != 2 || detail.Employees[0].Name != "Пётр" {
		t.Fatalf("не те сотрудники: %#v", detail.Employees)
	}
	if len(detail.Comments) != 1 || detail.Comments[0].Text != "Ждём гарнитуры" || detail.Comments[0].AuthorLogin != "olga" {
		t.Fatalf("не тот комментарий: %#v", detail.Comments)
	}
	if detail.Status != StatusStarted {
		t.Errorf("статус %q, ожидался начат", detail.Status)
	}
}

func TestToggleSandboxMarkKeepsDependenciesAndAuthor(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()
	created, _ := db.CreateSandbox(ctx, support(), office("Власов", "Пётр"))

	if _, err := db.ToggleSandboxMark(ctx, support(), created.ID, "seized"); !errors.Is(err, ErrTaskBlocked) {
		t.Fatalf("зависимая работа отметилась первой: %v", err)
	}
	if marked, err := db.ToggleSandboxMark(ctx, support(), created.ID, "hardware"); err != nil || !marked {
		t.Fatalf("отметить технику: marked=%v err=%v", marked, err)
	}
	if marked, err := db.ToggleSandboxMark(ctx, support(), created.ID, "seized"); err != nil || !marked {
		t.Fatalf("отметить изъятие: marked=%v err=%v", marked, err)
	}
	if _, err := db.ToggleSandboxMark(ctx, support(), created.ID, "hardware"); !errors.Is(err, ErrTaskRequired) {
		t.Fatalf("основа снялась из-под зависимой работы: %v", err)
	}

	detail, _ := db.GetSandbox(ctx, created.ID)
	mark := detail.Marks["hardware"]
	if mark.DoneLogin != "olga" || mark.DoneBy != 3 || mark.DoneAt.IsZero() {
		t.Errorf("исполнитель отметки потерян: %#v", mark)
	}
	if count(t, db, `SELECT COUNT(*) FROM audit_outbox WHERE action = 'sandbox.mark'`) != 2 {
		t.Error("отметки не попали в outbox")
	}
}

func TestAddEmployeeAndCommentNeedOpenSandbox(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()
	created, _ := db.CreateSandbox(ctx, support(), office("Макаренко", "Пётр"))

	id, err := db.AddSandboxEmployee(ctx, support(), created.ID, "  Анна Иванова ")
	if err != nil || id == 0 {
		t.Fatalf("AddSandboxEmployee: id=%d err=%v", id, err)
	}
	if err := db.AddSandboxComment(ctx, support(), created.ID, ""); !errors.Is(err, ErrEmptyComment) {
		t.Fatalf("пустой комментарий принят: %v", err)
	}
	if err := db.CloseSandbox(ctx, support(), created.ID); err != nil {
		t.Fatalf("CloseSandbox: %v", err)
	}
	if _, err := db.AddSandboxEmployee(ctx, support(), created.ID, "Игорь"); !errors.Is(err, ErrClosed) {
		t.Fatalf("в закрытый песок добавлен человек: %v", err)
	}
	if err := db.AddSandboxComment(ctx, support(), created.ID, "поздно"); !errors.Is(err, ErrClosed) {
		t.Fatalf("в закрытый песок добавлен комментарий: %v", err)
	}
}

func TestCloseSandboxReleasesNumbersAndWritesAudit(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()
	in := office("Шахалиева", "Пётр")
	in.Extensions = []string{"301", "302"}
	created, err := db.CreateSandbox(ctx, support(), in)
	if err != nil {
		t.Fatalf("CreateSandbox: %v", err)
	}
	if err := db.CloseSandbox(ctx, support(), created.ID); err != nil {
		t.Fatalf("CloseSandbox: %v", err)
	}

	detail, err := db.GetSandbox(ctx, created.ID)
	if err != nil {
		t.Fatalf("GetSandbox: %v", err)
	}
	if detail.Status != StatusClosed || detail.ClosedAt == nil {
		t.Errorf("песок не закрыт: %#v", detail.Sandbox)
	}
	if count(t, db, `SELECT COUNT(*) FROM sandbox_extensions WHERE sandbox_id = ? AND released_at IS NOT NULL`, created.ID) != 2 {
		t.Error("номера не освобождены")
	}
	if count(t, db, `SELECT COUNT(*) FROM audit_outbox WHERE action = 'sandbox.close'`) != 1 {
		t.Error("закрытие не попало в outbox")
	}
	if err := db.CloseSandbox(ctx, support(), created.ID); !errors.Is(err, ErrClosed) {
		t.Fatalf("закрытый песок закрыт второй раз: %v", err)
	}
}

func TestUnknownSandboxTaskIsRejected(t *testing.T) {
	db := openTemp(t)
	created, _ := db.CreateSandbox(context.Background(), support(), office("Марк", "Пётр"))
	if _, err := db.ToggleSandboxMark(context.Background(), support(), created.ID, "invented"); !errors.Is(err, ErrUnknownTask) {
		t.Fatalf("чужая работа принята: %v", err)
	}
}
