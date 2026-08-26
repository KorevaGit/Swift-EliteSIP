package sand

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Отказы, о которых форма обязана сказать человеческими словами.
//
// Все они, кроме первых трёх, живут запретами в базе: форма их дублирует ради
// внятного сообщения, но полагаться на неё нельзя — две открытые вкладки её
// обойдут, а запрет в базе нет.
var (
	ErrNoEmployees = errors.New("в песке должен быть хотя бы один человек")
	ErrUnknownROP  = errors.New("РОП выбирается из справочника")
	ErrBadFormat   = errors.New("песок бывает офисным или удалённым")
	ErrROPBusy     = errors.New("у этого РОПа уже есть незакрытый песок")
	ErrNumberBusy  = errors.New("номер лежит в пуле другого незакрытого песка")
	ErrNotFound    = errors.New("песок не найден")
)

// Actor — кто совершает действие.
//
// Логин носится рядом с идентификатором и оседает снимком в отметках и
// журнале: администраторы живут в другом файле базы, и история не должна
// зависеть от того, что станет с учётной записью потом.
type Actor struct {
	ID    int64
	Login string
}

// Sandbox — песок: один РОП и вся его группа стажёров разом.
type Sandbox struct {
	ID        int64
	ROP       string
	Format    Format
	CreatedAt time.Time
	ClosedAt  *time.Time
	ClosedBy  *int64
}

// Remote — удалённый ли песок. Пригождается шаблонам, которым нужен не
// строковый формат, а ответ «да/нет».
func (s Sandbox) Remote() bool { return s.Format == Remote }

// Status — состояние песка. Вычисляется и нигде не хранится, кроме closed_at:
// сохранённый статус разошёлся бы с работами при первой же отметке.
type Status string

const (
	StatusStarted Status = "начат"
	StatusRunning Status = "в процессе"
	StatusDone    Status = "завершён"
	StatusClosed  Status = "закрыт"
)

// NewSandbox — что приходит из формы создания.
//
// Всё сразу и одной транзакцией: черновиков и пустых песков нет, а песок без
// людей — это строка, о существовании которой потом спрашивают в чате.
type NewSandbox struct {
	ROP        string
	Format     Format
	Employees  []string // ФИО как ввели; хотя бы одно
	Extensions []string // пул номеров, может быть пуст
	Deals      []string // ID сделок холодной базы, может быть пуст
}

// SandboxCard — строка списка: песок и всё, что о нём спрашивают в таблице.
type SandboxCard struct {
	Sandbox
	Employees int

	// Отметки в виде чисел, а не списков: таблице нужны проценты, а разбирать
	// их обратно из строк на каждый показ незачем.
	sandboxDone  map[string]bool
	employeeDone map[string]int

	// touched — у скольких людей заполнено хоть что-то рабочее. Отдельно от
	// отметок: наполовину заведённый аккаунт ещё не закрывает работу, но песок
	// уже не «начат» — кто-то в нём сидел.
	touched int
}

// Progress — процент по каждому разделу на весь песок.
//
// Работы песка и работы каждого человека складываются в один знаменатель:
// раздел «техника» — это выданная на группу техника плюс инвентаризация по
// каждому. Иначе процент показывал бы пять закрытых работ песка как готовность
// там, где не тронут ни один человек.
func (c SandboxCard) Progress() []SectionProgress {
	sandboxTasks := SandboxTasks(c.Format)
	employeeTasks := EmployeeTasks(c.Format)

	out := make([]SectionProgress, 0, len(Sections()))
	for _, section := range Sections() {
		counted := SectionProgress{Section: section}
		for _, task := range sandboxTasks {
			if task.Section != section {
				continue
			}
			counted.Total++
			if c.sandboxDone[task.Key] {
				counted.Done++
			}
		}
		for _, task := range employeeTasks {
			if task.Section != section {
				continue
			}
			counted.Total += c.Employees
			counted.Done += c.employeeDone[task.Key]
		}
		if counted.Total > 0 {
			out = append(out, counted)
		}
	}
	return out
}

// Status — состояние по MODEL.md.
func (c SandboxCard) Status() Status {
	if c.ClosedAt != nil {
		return StatusClosed
	}

	total, done := 0, 0
	for _, section := range c.Progress() {
		total += section.Total
		done += section.Done
	}

	switch {
	case total > 0 && done == total:
		return StatusDone
	case done > 0 || c.touched > 0:
		return StatusRunning
	default:
		return StatusStarted
	}
}

// CreateSandbox заводит песок вместе с людьми, пулом номеров и холодной базой.
//
// Одной транзакцией целиком, вместе с событием журнала: песок без людей не
// должен существовать даже мгновение между двумя запросами — на него уже
// сошлётся список, а закрыть его будет нечем.
func (db *DB) CreateSandbox(ctx context.Context, actor Actor, in NewSandbox) (Sandbox, error) {
	rop := strings.TrimSpace(in.ROP)
	if !KnownROP(rop) {
		return Sandbox{}, ErrUnknownROP
	}
	if in.Format != Office && in.Format != Remote {
		return Sandbox{}, ErrBadFormat
	}

	names := trimmed(in.Employees)
	if len(names) == 0 {
		return Sandbox{}, ErrNoEmployees
	}
	numbers := unique(trimmed(in.Extensions))
	deals := unique(trimmed(in.Deals))

	now := time.Now()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return Sandbox{}, fmt.Errorf("завести песок: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`INSERT INTO sandboxes (rop, format, created_at) VALUES (?, ?, ?)`,
		rop, string(in.Format), formatTime(now))
	if err != nil {
		return Sandbox{}, conflict(err, fmt.Errorf("завести песок РОПа %q: %w", rop, err))
	}
	id, err := res.LastInsertId()
	if err != nil {
		return Sandbox{}, fmt.Errorf("завести песок РОПа %q: %w", rop, err)
	}

	for _, name := range names {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO sand_employees (sandbox_id, name) VALUES (?, ?)`, id, name); err != nil {
			return Sandbox{}, conflict(err, fmt.Errorf("завести сотрудника %q: %w", name, err))
		}
	}
	for _, number := range numbers {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO sandbox_extensions (sandbox_id, number) VALUES (?, ?)`, id, number); err != nil {
			return Sandbox{}, conflict(err, fmt.Errorf("добавить номер %q в пул: %w", number, err))
		}
	}
	for _, deal := range deals {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO sandbox_deals (sandbox_id, deal_id) VALUES (?, ?)`, id, deal); err != nil {
			return Sandbox{}, conflict(err, fmt.Errorf("добавить сделку %q в пул: %w", deal, err))
		}
	}

	if _, err := QueueAudit(ctx, tx, AuditEvent{
		At: now, ActorID: &actor.ID, ActorLogin: actor.Login,
		Action: "sandbox.create", Entity: "sandbox", EntityID: &id,
		Details: describeNew(rop, in.Format, len(names), len(numbers), len(deals)),
	}); err != nil {
		return Sandbox{}, err
	}

	if err := tx.Commit(); err != nil {
		return Sandbox{}, conflict(err, fmt.Errorf("завести песок РОПа %q: %w", rop, err))
	}

	return Sandbox{
		ID: id, ROP: rop, Format: in.Format,
		CreatedAt: now.UTC(),
	}, nil
}

// ListSandboxes отдаёт активные пески или архив закрытых.
//
// Счётчики и отметки собираются тремя запросами на весь список, а не по одному
// на песок: активных песков до пяти, а архив растёт годами, и запрос в цикле
// там разошёлся бы незаметно.
func (db *DB) ListSandboxes(ctx context.Context, closed bool) ([]SandboxCard, error) {
	where := "closed_at IS NULL"
	if closed {
		where = "closed_at IS NOT NULL"
	}

	rows, err := db.QueryContext(ctx,
		`SELECT id, rop, format, created_at, closed_at, closed_by
		   FROM sandboxes
		  WHERE `+where+`
		  ORDER BY created_at DESC, id DESC`)
	if err != nil {
		return nil, fmt.Errorf("прочитать список песков: %w", err)
	}
	defer rows.Close()

	var (
		cards = []SandboxCard{}
		byID  = map[int64]int{}
	)
	for rows.Next() {
		var (
			card      SandboxCard
			format    string
			createdAt string
			closedAt  sql.NullString
			closedBy  sql.NullInt64
		)
		if err := rows.Scan(&card.ID, &card.ROP, &format, &createdAt, &closedAt, &closedBy); err != nil {
			return nil, fmt.Errorf("прочитать песок: %w", err)
		}
		card.Format = Format(format)
		if card.CreatedAt, err = readTime(createdAt); err != nil {
			return nil, err
		}
		if closedAt.Valid {
			at, err := readTime(closedAt.String)
			if err != nil {
				return nil, err
			}
			card.ClosedAt = &at
		}
		card.ClosedBy = readNullInt64(closedBy)
		card.sandboxDone = map[string]bool{}
		card.employeeDone = map[string]int{}

		byID[card.ID] = len(cards)
		cards = append(cards, card)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("прочитать список песков: %w", err)
	}
	if len(cards) == 0 {
		return cards, nil
	}

	if err := db.fillPeople(ctx, cards, byID); err != nil {
		return nil, err
	}
	if err := db.fillMarks(ctx, cards, byID); err != nil {
		return nil, err
	}
	return cards, nil
}

// fillPeople считает людей и выводит три отметки, у которых нет собственного
// состояния: аккаунт, номер и исход выводятся из данных, а не из флажков.
func (db *DB) fillPeople(ctx context.Context, cards []SandboxCard, byID map[int64]int) error {
	rows, err := db.QueryContext(ctx,
		`SELECT e.sandbox_id,
		        COUNT(*),
		        SUM(CASE WHEN COALESCE(e.bitrix_login, '') <> ''
		                  AND COALESCE(e.bitrix_pass, '')  <> ''
		                  AND COALESCE(e.bitrix_id, '')    <> '' THEN 1 ELSE 0 END),
		        SUM(CASE WHEN x.number IS NOT NULL THEN 1 ELSE 0 END),
		        SUM(CASE WHEN e.outcome IS NOT NULL THEN 1 ELSE 0 END),
		        SUM(CASE WHEN COALESCE(e.bitrix_login, '') <> ''
		                   OR COALESCE(e.bitrix_pass, '')  <> ''
		                   OR COALESCE(e.bitrix_id, '')    <> ''
		                   OR e.outcome IS NOT NULL
		                   OR x.number IS NOT NULL THEN 1 ELSE 0 END)
		   FROM sand_employees e
		   LEFT JOIN sandbox_extensions x
		          ON x.employee_id = e.id AND x.released_at IS NULL
		  GROUP BY e.sandbox_id`)
	if err != nil {
		return fmt.Errorf("посчитать людей в песках: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var sandboxID int64
		var people, withAccount, withNumber, withOutcome, touched int
		if err := rows.Scan(&sandboxID, &people, &withAccount, &withNumber, &withOutcome, &touched); err != nil {
			return fmt.Errorf("посчитать людей в песках: %w", err)
		}
		at, ok := byID[sandboxID]
		if !ok {
			continue
		}
		cards[at].Employees = people
		cards[at].employeeDone["bitrix"] = withAccount
		cards[at].employeeDone["extension"] = withNumber
		cards[at].employeeDone["outcome"] = withOutcome
		cards[at].touched = touched
	}
	return rows.Err()
}

// fillMarks добавляет отметки, которые ставятся руками.
func (db *DB) fillMarks(ctx context.Context, cards []SandboxCard, byID map[int64]int) error {
	sandboxMarks, err := db.QueryContext(ctx, `SELECT sandbox_id, task FROM sandbox_marks`)
	if err != nil {
		return fmt.Errorf("прочитать отметки песков: %w", err)
	}
	defer sandboxMarks.Close()

	for sandboxMarks.Next() {
		var sandboxID int64
		var task string
		if err := sandboxMarks.Scan(&sandboxID, &task); err != nil {
			return fmt.Errorf("прочитать отметку песка: %w", err)
		}
		if at, ok := byID[sandboxID]; ok {
			cards[at].sandboxDone[task] = true
		}
	}
	if err := sandboxMarks.Err(); err != nil {
		return fmt.Errorf("прочитать отметки песков: %w", err)
	}

	employeeMarks, err := db.QueryContext(ctx,
		`SELECT e.sandbox_id, m.task, COUNT(*)
		   FROM employee_marks m
		   JOIN sand_employees e ON e.id = m.employee_id
		  GROUP BY e.sandbox_id, m.task`)
	if err != nil {
		return fmt.Errorf("прочитать отметки сотрудников: %w", err)
	}
	defer employeeMarks.Close()

	for employeeMarks.Next() {
		var sandboxID int64
		var task string
		var count int
		if err := employeeMarks.Scan(&sandboxID, &task, &count); err != nil {
			return fmt.Errorf("прочитать отметку сотрудника: %w", err)
		}
		if at, ok := byID[sandboxID]; ok {
			cards[at].employeeDone[task] = count
		}
	}
	return employeeMarks.Err()
}

// CountActive — сколько песков идёт прямо сейчас. Для счётчика на обзоре.
func (db *DB) CountActive(ctx context.Context) (int, error) {
	var count int
	if err := db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM sandboxes WHERE closed_at IS NULL`).Scan(&count); err != nil {
		return 0, fmt.Errorf("посчитать активные пески: %w", err)
	}
	return count, nil
}

// conflict переводит запрет базы в отказ, который можно показать человеку.
//
// SQLite называет столбец, а не индекс, поэтому сверяемся с ним. Разойдясь с
// формулировкой драйвера, проверка тихо вернула бы «внутреннюю ошибку» вместо
// внятного «у РОПа уже есть песок» — на это есть отдельный тест.
func conflict(err error, fallback error) error {
	text := err.Error()
	switch {
	case strings.Contains(text, "UNIQUE constraint failed: sandboxes.rop"):
		return ErrROPBusy
	case strings.Contains(text, "UNIQUE constraint failed: sandbox_extensions.number"):
		return ErrNumberBusy
	case strings.Contains(text, "CHECK constraint failed: format"):
		return ErrBadFormat
	}
	return fallback
}

func describeNew(rop string, format Format, people, numbers, deals int) string {
	where := "офис"
	if format == Remote {
		where = "удалёнка"
	}
	return fmt.Sprintf("РОП %s, %s, людей %d, номеров %d, сделок %d",
		rop, where, people, numbers, deals)
}

func trimmed(in []string) []string {
	out := make([]string, 0, len(in))
	for _, value := range in {
		if value = strings.TrimSpace(value); value != "" {
			out = append(out, value)
		}
	}
	return out
}

// unique убирает повторы, сохраняя порядок ввода.
//
// Повтор в одной форме — не злой умысел, а разложенный диапазон, куда рядом
// дописали тот же номер руками. Отказывать из-за этого незачем.
func unique(in []string) []string {
	seen := make(map[string]bool, len(in))
	out := make([]string, 0, len(in))
	for _, value := range in {
		if seen[value] {
			continue
		}
		seen[value] = true
		out = append(out, value)
	}
	return out
}
