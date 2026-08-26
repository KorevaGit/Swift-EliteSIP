package sand

import (
	"context"
	"errors"
	"testing"
)

func support() Actor { return Actor{ID: 3, Login: "olga"} }

func office(rop string, names ...string) NewSandbox {
	return NewSandbox{ROP: rop, Format: Office, Employees: names}
}

// Песок заводится целиком и одной транзакцией: люди, пул номеров, холодная
// база и событие журнала появляются вместе или не появляются вовсе.
func TestCreateSandboxWritesEverythingAtOnce(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	in := office("Кочура", "Пётр Смирнов", " Анна Иванова ", "")
	in.Extensions = []string{"301", "302"}
	in.Deals = []string{"2516934", "2517017"}

	created, err := db.CreateSandbox(ctx, support(), in)
	if err != nil {
		t.Fatalf("CreateSandbox: %v", err)
	}
	if created.ID == 0 || created.ROP != "Кочура" || created.Format != Office {
		t.Fatalf("вернулся не тот песок: %+v", created)
	}

	// Пустая строка в списке ФИО — это лишнее поле формы, а не человек.
	if got := count(t, db, `SELECT COUNT(*) FROM sand_employees WHERE sandbox_id = ?`, created.ID); got != 2 {
		t.Errorf("сотрудников записано %d, ожидалось 2", got)
	}
	if got := count(t, db, `SELECT COUNT(*) FROM sandbox_extensions WHERE sandbox_id = ?`, created.ID); got != 2 {
		t.Errorf("номеров в пуле %d, ожидалось 2", got)
	}
	if got := count(t, db, `SELECT COUNT(*) FROM sandbox_deals WHERE sandbox_id = ?`, created.ID); got != 2 {
		t.Errorf("сделок в пуле %d, ожидалось 2", got)
	}

	// Имя сохраняется как ввели, только без окружающих пробелов: разбирать ФИО
	// на части мы не беремся.
	var name string
	if err := db.QueryRow(
		`SELECT name FROM sand_employees WHERE sandbox_id = ? ORDER BY id DESC LIMIT 1`, created.ID,
	).Scan(&name); err != nil {
		t.Fatalf("прочитать имя: %v", err)
	}
	if name != "Анна Иванова" {
		t.Errorf("имя сохранено как %q", name)
	}

	var action, login, details string
	if err := db.QueryRow(
		`SELECT action, actor_login, details FROM audit_outbox`).Scan(&action, &login, &details); err != nil {
		t.Fatalf("событие журнала не поставлено в outbox: %v", err)
	}
	if action != "sandbox.create" || login != "olga" {
		t.Errorf("событие вышло такое: %s от %s", action, login)
	}
	if details == "" {
		t.Error("в журнале нет описания песка")
	}
}

// Пустой песок создать нельзя, и неудачная попытка не оставляет следов:
// иначе в базе появился бы песок без людей, который нечем закрыть.
func TestCreateSandboxRefusesWithoutPeople(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	for name, in := range map[string]NewSandbox{
		"списка нет вовсе": office("Кочура"),
		"одни пробелы":     office("Кочура", "   ", ""),
	} {
		if _, err := db.CreateSandbox(ctx, support(), in); !errors.Is(err, ErrNoEmployees) {
			t.Errorf("%s: ошибка %v, ожидалась ErrNoEmployees", name, err)
		}
	}

	if got := count(t, db, `SELECT COUNT(*) FROM sandboxes`); got != 0 {
		t.Errorf("в базе осталось песков: %d", got)
	}
	if got := count(t, db, `SELECT COUNT(*) FROM audit_outbox`); got != 0 {
		t.Errorf("в outbox осталось событий: %d", got)
	}
}

// РОП только из справочника, формат только из двух: свободный текст развалил
// бы и запрет «один активный песок на РОПа», и подсчёт по формату.
func TestCreateSandboxChecksROPAndFormat(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	if _, err := db.CreateSandbox(ctx, support(), office("Иванов", "Пётр")); !errors.Is(err, ErrUnknownROP) {
		t.Errorf("чужой РОП: %v", err)
	}
	if _, err := db.CreateSandbox(ctx, support(), office("кочура", "Пётр")); !errors.Is(err, ErrUnknownROP) {
		t.Errorf("РОП в другом регистре принят: %v", err)
	}

	odd := NewSandbox{ROP: "Кочура", Format: "гибрид", Employees: []string{"Пётр"}}
	if _, err := db.CreateSandbox(ctx, support(), odd); !errors.Is(err, ErrBadFormat) {
		t.Errorf("чужой формат: %v", err)
	}
}

// Второй активный песок тому же РОПу — запрет базы, а не формы, и наверх он
// обязан дойти человеческими словами, а не «внутренней ошибкой».
func TestSecondActiveSandboxIsRefusedInWords(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	first, err := db.CreateSandbox(ctx, support(), office("Кочура", "Пётр"))
	if err != nil {
		t.Fatalf("первый песок: %v", err)
	}

	_, err = db.CreateSandbox(ctx, support(), office("Кочура", "Анна"))
	if !errors.Is(err, ErrROPBusy) {
		t.Fatalf("второй активный песок: %v", err)
	}
	if got := count(t, db, `SELECT COUNT(*) FROM sandboxes`); got != 1 {
		t.Errorf("песков стало %d", got)
	}

	// После закрытия прежнего новый песок тому же РОПу заводится: пески идут
	// один за другим и друг на друга не ссылаются.
	if _, err := db.Exec(`UPDATE sandboxes SET closed_at = ? WHERE id = ?`, testTime, first.ID); err != nil {
		t.Fatalf("закрыть первый песок: %v", err)
	}
	if _, err := db.CreateSandbox(ctx, support(), office("Кочура", "Анна")); err != nil {
		t.Errorf("песок после закрытия прежнего: %v", err)
	}
}

// Один номер в двух незакрытых пулах — это два человека на одном добавочном.
func TestNumberFromAnotherActivePoolIsRefused(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	busy := office("Кочура", "Пётр")
	busy.Extensions = []string{"301", "302"}
	if _, err := db.CreateSandbox(ctx, support(), busy); err != nil {
		t.Fatalf("первый песок: %v", err)
	}

	clash := office("Власов", "Анна")
	clash.Extensions = []string{"302", "303"}
	if _, err := db.CreateSandbox(ctx, support(), clash); !errors.Is(err, ErrNumberBusy) {
		t.Fatalf("повтор номера: %v", err)
	}

	// Откат целиком: ни песка, ни свободного номера 303 от неудачной попытки.
	if got := count(t, db, `SELECT COUNT(*) FROM sandboxes`); got != 1 {
		t.Errorf("песков стало %d", got)
	}
	if got := count(t, db, `SELECT COUNT(*) FROM sandbox_extensions WHERE number = '303'`); got != 0 {
		t.Errorf("номер из отменённого песка остался: %d", got)
	}
}

// Повтор внутри одной формы — не отказ: обычно это развёрнутый диапазон, куда
// рядом дописали тот же номер руками.
func TestRepeatedNumberInOneFormIsKept(t *testing.T) {
	db := openTemp(t)

	in := office("Марк", "Пётр")
	in.Extensions = []string{"301", "301", "302"}
	in.Deals = []string{"7", "7"}

	created, err := db.CreateSandbox(context.Background(), support(), in)
	if err != nil {
		t.Fatalf("CreateSandbox: %v", err)
	}
	if got := count(t, db, `SELECT COUNT(*) FROM sandbox_extensions WHERE sandbox_id = ?`, created.ID); got != 2 {
		t.Errorf("номеров записано %d, ожидалось 2", got)
	}
	if got := count(t, db, `SELECT COUNT(*) FROM sandbox_deals WHERE sandbox_id = ?`, created.ID); got != 1 {
		t.Errorf("сделок записано %d, ожидалась 1", got)
	}
}

// Список показывает то, что спрашивают в таблице, и делит активные с архивом.
func TestListSeparatesActiveFromArchive(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	live, err := db.CreateSandbox(ctx, support(), office("Кочура", "Пётр", "Анна"))
	if err != nil {
		t.Fatalf("CreateSandbox: %v", err)
	}
	closed, err := db.CreateSandbox(ctx, support(), office("Власов", "Игорь"))
	if err != nil {
		t.Fatalf("CreateSandbox: %v", err)
	}
	if _, err := db.Exec(`UPDATE sandboxes SET closed_at = ?, closed_by = 1 WHERE id = ?`, testTime, closed.ID); err != nil {
		t.Fatalf("закрыть песок: %v", err)
	}

	active, err := db.ListSandboxes(ctx, false)
	if err != nil {
		t.Fatalf("ListSandboxes: %v", err)
	}
	if len(active) != 1 || active[0].ID != live.ID {
		t.Fatalf("в активных %d песков: %+v", len(active), active)
	}
	if active[0].Employees != 2 {
		t.Errorf("людей в песке %d, ожидалось 2", active[0].Employees)
	}
	if active[0].Status() != StatusStarted {
		t.Errorf("статус нетронутого песка: %q", active[0].Status())
	}

	archive, err := db.ListSandboxes(ctx, true)
	if err != nil {
		t.Fatalf("ListSandboxes(архив): %v", err)
	}
	if len(archive) != 1 || archive[0].ID != closed.ID {
		t.Fatalf("в архиве %d песков", len(archive))
	}
	if archive[0].Status() != StatusClosed {
		t.Errorf("статус закрытого песка: %q", archive[0].Status())
	}
	if archive[0].ClosedAt == nil || archive[0].ClosedBy == nil {
		t.Error("в архиве не видно, кто и когда закрыл")
	}
}

// Пустой список — не ошибка и не nil: шаблон обходит его так же, как полный.
func TestListOfNothingIsEmptyNotNil(t *testing.T) {
	db := openTemp(t)

	cards, err := db.ListSandboxes(context.Background(), false)
	if err != nil {
		t.Fatalf("ListSandboxes: %v", err)
	}
	if cards == nil || len(cards) != 0 {
		t.Errorf("пустой список вышел таким: %#v", cards)
	}
}

// Процент считается по разделам, и работы человека входят в тот же
// знаменатель: иначе закрытые работы песка показывали бы готовность там, где
// не тронут ни один стажёр.
func TestProgressCountsSandboxAndPeopleTogether(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	created, err := db.CreateSandbox(ctx, support(), office("Кочура", "Пётр", "Анна"))
	if err != nil {
		t.Fatalf("CreateSandbox: %v", err)
	}
	// Техника на песок выдана, но никто не проинвентаризирован.
	mark(t, db, created.ID, "hardware")

	cards, err := db.ListSandboxes(ctx, false)
	if err != nil {
		t.Fatalf("ListSandboxes: %v", err)
	}

	var hardware SectionProgress
	for _, section := range cards[0].Progress() {
		if section.Section == SectionHardware {
			hardware = section
		}
	}
	// Техника: три работы песка + инвентаризация у двоих.
	if hardware.Total != 5 || hardware.Done != 1 {
		t.Errorf("техника: %d из %d, ожидалось 1 из 5", hardware.Done, hardware.Total)
	}
	if cards[0].Status() != StatusRunning {
		t.Errorf("после первой отметки статус %q", cards[0].Status())
	}
}

// Заполненные рабочие данные двигают песок в «в процессе» даже без отметок:
// аккаунт, номер и исход отметок не имеют — они выводятся из самих данных.
func TestFilledEmployeeDataMovesStatusAndProgress(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	created, err := db.CreateSandbox(ctx, support(), office("Власов", "Пётр"))
	if err != nil {
		t.Fatalf("CreateSandbox: %v", err)
	}

	// Наполовину заведённый аккаунт: работу ещё не закрывает, но песок уже не
	// нетронутый — в нём кто-то сидел.
	if _, err := db.Exec(
		`UPDATE sand_employees SET bitrix_login = 'p.smirnov' WHERE sandbox_id = ?`, created.ID); err != nil {
		t.Fatalf("записать логин: %v", err)
	}
	cards, _ := db.ListSandboxes(ctx, false)
	if got := sectionOf(cards[0], SectionAccounts); got.Done != 0 {
		t.Errorf("половина аккаунта закрыла работу: %d из %d", got.Done, got.Total)
	}
	if cards[0].Status() != StatusRunning {
		t.Errorf("статус после начатого аккаунта: %q", cards[0].Status())
	}

	// Дозаполненный целиком — работа закрыта без всякого флажка.
	if _, err := db.Exec(
		`UPDATE sand_employees SET bitrix_pass = 'тайна', bitrix_id = '12817' WHERE sandbox_id = ?`,
		created.ID); err != nil {
		t.Fatalf("дозаполнить аккаунт: %v", err)
	}
	cards, _ = db.ListSandboxes(ctx, false)
	if got := sectionOf(cards[0], SectionAccounts); got.Done != 1 || got.Percent() != 100 {
		t.Errorf("аккаунты: %d из %d", got.Done, got.Total)
	}
}

// Формулировки запретов приходят от драйвера строкой. Разойдясь с ней, панель
// молча показала бы «внутреннюю ошибку» вместо внятного отказа — тест держит
// эту связку.
func TestConflictRecognisesDriverWording(t *testing.T) {
	fallback := errors.New("внутренняя ошибка")

	cases := map[string]error{
		"constraint failed: UNIQUE constraint failed: sandboxes.rop (2067)":             ErrROPBusy,
		"constraint failed: UNIQUE constraint failed: sandbox_extensions.number (2067)": ErrNumberBusy,
		"constraint failed: CHECK constraint failed: format IN ('office', 'remote')":    ErrBadFormat,
		"constraint failed: UNIQUE constraint failed: sand_employees.bitrix_id (2067)":  fallback,
		"database is locked": fallback,
	}
	for text, want := range cases {
		if got := conflict(errors.New(text), fallback); !errors.Is(got, want) {
			t.Errorf("%q → %v, ожидалось %v", text, got, want)
		}
	}
}

func TestCountActive(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	if got, _ := db.CountActive(ctx); got != 0 {
		t.Errorf("на пустой базе активных %d", got)
	}
	created, err := db.CreateSandbox(ctx, support(), office("Марк", "Пётр"))
	if err != nil {
		t.Fatalf("CreateSandbox: %v", err)
	}
	if got, _ := db.CountActive(ctx); got != 1 {
		t.Errorf("активных %d, ожидался 1", got)
	}

	db.Exec(`UPDATE sandboxes SET closed_at = ? WHERE id = ?`, testTime, created.ID)
	if got, _ := db.CountActive(ctx); got != 0 {
		t.Errorf("закрытый песок считается активным: %d", got)
	}
}

func sectionOf(card SandboxCard, section string) SectionProgress {
	for _, got := range card.Progress() {
		if got.Section == section {
			return got
		}
	}
	return SectionProgress{Section: section}
}

func mark(t *testing.T, db *DB, sandboxID int64, task string) {
	t.Helper()
	if _, err := db.Exec(
		`INSERT INTO sandbox_marks (sandbox_id, task, done_at, done_by, done_login)
		 VALUES (?, ?, ?, 3, 'olga')`, sandboxID, task, testTime); err != nil {
		t.Fatalf("отметить %s: %v", task, err)
	}
}

func count(t *testing.T, db *DB, query string, args ...any) int {
	t.Helper()
	var got int
	if err := db.QueryRow(query, args...).Scan(&got); err != nil {
		t.Fatalf("%s: %v", query, err)
	}
	return got
}
