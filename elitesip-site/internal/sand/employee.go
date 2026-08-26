package sand

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

var (
	ErrEmployeeNotFound = errors.New("сотрудник не найден в этом песке")
	ErrStructuredTask   = errors.New("эта работа меняется через свои данные")
	ErrBitrixRequired   = errors.New("сначала заполните ID Битрикса")
	ErrNoDeals          = errors.New("в песке не осталось свободных сделок")
	ErrBatchImported    = errors.New("эта порция уже отмечена налитой")
	ErrLoginExists      = errors.New("сотрудника с аккаунтом удалять нельзя")
	ErrBadOutcome       = errors.New("исход бывает только «выведен в ОП» или «увольнение»")
)

type CascadeRequired struct{ Count int }

func (e CascadeRequired) Error() string {
	return fmt.Sprintf("с отметкой снимется ещё %d", e.Count)
}

type ResolvedLink struct {
	Title string
	URL   string
	Ready bool
}

type EmployeeTask struct {
	Task
	LinksResolved []ResolvedLink
}

type DealBatch struct {
	ID            int64
	Size          int
	CreatedAt     time.Time
	ImportedAt    *time.Time
	ImportedLogin string
	Deals         []string
}

type EmployeeDetail struct {
	Sandbox
	EmployeeID          int64
	Name                string
	BitrixLogin         string
	BitrixPass          string
	BitrixID            string
	Outcome             Outcome
	OutcomeAt           *time.Time
	Extension           string
	AvailableExtensions []string
	Tasks               []EmployeeTask
	Marks               map[string]*Mark
	Progress            []SectionProgress
	Batches             []DealBatch
	DealsFree           int
}

func (d EmployeeDetail) LibraSQL() string {
	if strings.TrimSpace(d.BitrixID) == "" {
		return ""
	}
	return fmt.Sprintf("INSERT INTO [dbo].[ESLibra_UsersAccess]\n([USER_ID])\nVALUES\n(%s)\n\nSELECT * FROM [dbo].[ESLibra_UsersAccess]", d.BitrixID)
}

func (d EmployeeDetail) Done(key string) bool {
	if key == "bitrix" {
		return d.BitrixLogin != "" && d.BitrixPass != "" && d.BitrixID != ""
	}
	if key == "extension" {
		return d.Extension != ""
	}
	if key == "outcome" {
		return d.Outcome != ""
	}
	return d.Marks[key] != nil
}

func (d EmployeeDetail) OverallPercent() int {
	done, total := 0, 0
	for _, section := range d.Progress {
		done += section.Done
		total += section.Total
	}
	if total == 0 {
		return 0
	}
	return done * 100 / total
}

func (db *DB) GetEmployee(ctx context.Context, sandboxID, employeeID int64) (EmployeeDetail, error) {
	var d EmployeeDetail
	var format, created string
	var closed, outcomeAt sql.NullString
	var closedBy sql.NullInt64
	err := db.QueryRowContext(ctx, `SELECT s.id,s.rop,s.format,s.created_at,s.closed_at,s.closed_by,
		e.id,e.name,COALESCE(e.bitrix_login,''),COALESCE(e.bitrix_pass,''),COALESCE(e.bitrix_id,''),COALESCE(e.outcome,''),e.outcome_at
		FROM sandboxes s JOIN sand_employees e ON e.sandbox_id=s.id WHERE s.id=? AND e.id=?`, sandboxID, employeeID).
		Scan(&d.ID, &d.ROP, &format, &created, &closed, &closedBy, &d.EmployeeID, &d.Name, &d.BitrixLogin, &d.BitrixPass, &d.BitrixID, &d.Outcome, &outcomeAt)
	if errors.Is(err, sql.ErrNoRows) {
		return d, ErrEmployeeNotFound
	}
	if err != nil {
		return d, fmt.Errorf("прочитать сотрудника: %w", err)
	}
	d.Format = Format(format)
	d.CreatedAt, err = readTime(created)
	if err != nil {
		return d, err
	}
	if closed.Valid {
		t, e := readTime(closed.String)
		if e != nil {
			return d, e
		}
		d.ClosedAt = &t
	}
	d.ClosedBy = readNullInt64(closedBy)
	if outcomeAt.Valid {
		t, e := readTime(outcomeAt.String)
		if e != nil {
			return d, e
		}
		d.OutcomeAt = &t
	}
	d.Marks, err = db.employeeMarks(ctx, employeeID)
	if err != nil {
		return d, err
	}
	_ = db.QueryRowContext(ctx, `SELECT COALESCE(number,'') FROM sandbox_extensions WHERE sandbox_id=? AND employee_id=? AND released_at IS NULL`, sandboxID, employeeID).Scan(&d.Extension)
	rows, err := db.QueryContext(ctx, `SELECT number FROM sandbox_extensions WHERE sandbox_id=? AND employee_id IS NULL AND released_at IS NULL ORDER BY number`, sandboxID)
	if err != nil {
		return d, err
	}
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			rows.Close()
			return d, err
		}
		d.AvailableExtensions = append(d.AvailableExtensions, n)
	}
	rows.Close()
	d.Batches, err = db.employeeBatches(ctx, sandboxID, employeeID)
	if err != nil {
		return d, err
	}
	if err = db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sandbox_deals WHERE sandbox_id=? AND employee_id IS NULL`, sandboxID).Scan(&d.DealsFree); err != nil {
		return d, err
	}
	done := map[string]bool{}
	for k := range d.Marks {
		done[k] = true
	}
	done["bitrix"] = d.BitrixLogin != "" && d.BitrixPass != "" && d.BitrixID != ""
	done["extension"] = d.Extension != ""
	done["outcome"] = d.Outcome != ""
	for _, task := range EmployeeTasksFor(d.Format, d.Outcome) {
		et := EmployeeTask{Task: task}
		for _, l := range task.Links {
			v := ""
			if l.Needs == PlaceholderBitrix {
				v = d.BitrixID
			} else if l.Needs == PlaceholderExt {
				v = d.Extension
			}
			u, ok := l.For(v)
			et.LinksResolved = append(et.LinksResolved, ResolvedLink{l.Title, u, ok})
		}
		d.Tasks = append(d.Tasks, et)
	}
	d.Progress = Progress(EmployeeTasksFor(d.Format, d.Outcome), done)
	return d, nil
}

func (db *DB) employeeMarks(ctx context.Context, employeeID int64) (map[string]*Mark, error) {
	rows, err := db.QueryContext(ctx, `SELECT task,done_at,done_by,done_login FROM employee_marks WHERE employee_id=?`, employeeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]*Mark{}
	for rows.Next() {
		var m Mark
		var at string
		if err := rows.Scan(&m.Task, &at, &m.DoneBy, &m.DoneLogin); err != nil {
			return nil, err
		}
		m.DoneAt, err = readTime(at)
		if err != nil {
			return nil, err
		}
		out[m.Task] = &m
	}
	return out, rows.Err()
}

func (db *DB) employeeBatches(ctx context.Context, sandboxID, employeeID int64) ([]DealBatch, error) {
	rows, err := db.QueryContext(ctx, `SELECT id,size,created_at,imported_at,imported_login FROM deal_batches WHERE sandbox_id=? AND employee_id=? ORDER BY id DESC`, sandboxID, employeeID)
	if err != nil {
		return nil, err
	}
	var out []DealBatch
	for rows.Next() {
		var b DealBatch
		var at string
		var imported sql.NullString
		if err := rows.Scan(&b.ID, &b.Size, &at, &imported, &b.ImportedLogin); err != nil {
			rows.Close()
			return nil, err
		}
		b.CreatedAt, _ = readTime(at)
		if imported.Valid {
			t, _ := readTime(imported.String)
			b.ImportedAt = &t
		}
		out = append(out, b)
	}
	rows.Close()
	for i := range out {
		rs, err := db.QueryContext(ctx, `SELECT deal_id FROM sandbox_deals WHERE batch_id=? ORDER BY deal_id`, out[i].ID)
		if err != nil {
			return nil, err
		}
		for rs.Next() {
			var id string
			rs.Scan(&id)
			out[i].Deals = append(out[i].Deals, id)
		}
		rs.Close()
	}
	return out, nil
}

func employeeOpen(ctx context.Context, tx *sql.Tx, sid, eid int64) (Format, error) {
	f, err := openSandboxFormat(ctx, tx, sid)
	if err != nil {
		return "", err
	}
	var n int
	if err := tx.QueryRowContext(ctx, `SELECT 1 FROM sand_employees WHERE id=? AND sandbox_id=?`, eid, sid).Scan(&n); errors.Is(err, sql.ErrNoRows) {
		return "", ErrEmployeeNotFound
	} else if err != nil {
		return "", err
	}
	return f, nil
}

func (db *DB) SaveEmployeeBitrix(ctx context.Context, actor Actor, sid, eid int64, login, pass, id string, cascade bool) error {
	tx, e := db.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if _, e = employeeOpen(ctx, tx, sid, eid); e != nil {
		return e
	}
	login, pass, id = strings.TrimSpace(login), strings.TrimSpace(pass), strings.TrimSpace(id)
	var oldLogin, oldPass, oldID string
	if e = tx.QueryRowContext(ctx, `SELECT COALESCE(bitrix_login,''),COALESCE(bitrix_pass,''),COALESCE(bitrix_id,'') FROM sand_employees WHERE id=?`, eid).Scan(&oldLogin, &oldPass, &oldID); e != nil {
		return e
	}
	if oldLogin != "" && oldPass != "" && oldID != "" && (login == "" || pass == "" || id == "") {
		var dependent, structured int
		tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM employee_marks WHERE employee_id=? AND task IN ('libra','base_filled','base_drained')`, eid).Scan(&dependent)
		tx.QueryRowContext(ctx, `SELECT (CASE WHEN EXISTS(SELECT 1 FROM sandbox_extensions WHERE employee_id=? AND released_at IS NULL) THEN 1 ELSE 0 END) + (CASE WHEN COALESCE(outcome,'')<>'' THEN 1 ELSE 0 END) FROM sand_employees WHERE id=?`, eid, eid).Scan(&structured)
		dependent += structured
		if dependent > 0 && !cascade {
			return CascadeRequired{dependent}
		}
		if dependent > 0 {
			tx.ExecContext(ctx, `DELETE FROM employee_marks WHERE employee_id=? AND task IN ('libra','base_filled','base_drained')`, eid)
			tx.ExecContext(ctx, `UPDATE sandbox_extensions SET employee_id=NULL WHERE employee_id=? AND released_at IS NULL`, eid)
			tx.ExecContext(ctx, `UPDATE sand_employees SET outcome=NULL,outcome_at=NULL WHERE id=?`, eid)
		}
	}
	_, e = tx.ExecContext(ctx, `UPDATE sand_employees SET bitrix_login=?,bitrix_pass=?,bitrix_id=? WHERE id=?`, login, pass, id, eid)
	if e != nil {
		if strings.Contains(e.Error(), "UNIQUE") {
			return fmt.Errorf("ID Битрикса уже используется: %w", e)
		}
		return e
	}
	QueueAudit(ctx, tx, AuditEvent{At: time.Now(), ActorID: &actor.ID, ActorLogin: actor.Login, Action: "employee.bitrix", Entity: "sand_employee", EntityID: &eid, Details: "данные Битрикса сохранены"})
	return tx.Commit()
}

func (db *DB) AssignEmployeeExtension(ctx context.Context, actor Actor, sid, eid int64, number string) error {
	tx, e := db.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if _, e = employeeOpen(ctx, tx, sid, eid); e != nil {
		return e
	}
	var bitrix string
	if e = tx.QueryRowContext(ctx, `SELECT COALESCE(bitrix_id,'') FROM sand_employees WHERE id=?`, eid).Scan(&bitrix); e != nil {
		return e
	}
	if bitrix == "" {
		return ErrBitrixRequired
	}
	now := formatTime(time.Now())
	tx.ExecContext(ctx, `UPDATE sandbox_extensions SET employee_id=NULL,released_at=NULL WHERE sandbox_id=? AND employee_id=?`, sid, eid)
	res, e := tx.ExecContext(ctx, `UPDATE sandbox_extensions SET employee_id=?,released_at=NULL WHERE sandbox_id=? AND number=? AND employee_id IS NULL`, eid, sid, strings.TrimSpace(number))
	if e != nil {
		return e
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return errors.New("номер не свободен в пуле этого песка")
	}
	QueueAudit(ctx, tx, AuditEvent{At: time.Now(), ActorID: &actor.ID, ActorLogin: actor.Login, Action: "employee.extension", Entity: "sand_employee", EntityID: &eid, Details: number + " " + now})
	return tx.Commit()
}

func (db *DB) SetEmployeeOutcome(ctx context.Context, actor Actor, sid, eid int64, outcome Outcome) error {
	if outcome != OutcomeHired && outcome != OutcomeRejected {
		return ErrBadOutcome
	}
	tx, e := db.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if _, e = employeeOpen(ctx, tx, sid, eid); e != nil {
		return e
	}
	var bitrix string
	tx.QueryRowContext(ctx, `SELECT COALESCE(bitrix_id,'') FROM sand_employees WHERE id=?`, eid).Scan(&bitrix)
	if bitrix == "" {
		return ErrBitrixRequired
	}
	now := time.Now()
	_, e = tx.ExecContext(ctx, `UPDATE sand_employees SET outcome=?,outcome_at=? WHERE id=?`, outcome, formatTime(now), eid)
	if e != nil {
		return e
	}
	if outcome == OutcomeRejected {
		_, e = tx.ExecContext(ctx, `UPDATE sandbox_extensions SET released_at=? WHERE sandbox_id=? AND employee_id=? AND released_at IS NULL`, formatTime(now), sid, eid)
		if e != nil {
			return e
		}
	}
	QueueAudit(ctx, tx, AuditEvent{At: now, ActorID: &actor.ID, ActorLogin: actor.Login, Action: "employee.outcome", Entity: "sand_employee", EntityID: &eid, Details: string(outcome)})
	return tx.Commit()
}

func (db *DB) ToggleEmployeeMark(ctx context.Context, actor Actor, sid, eid int64, key string, cascade bool) (bool, error) {
	tx, e := db.BeginTx(ctx, nil)
	if e != nil {
		return false, e
	}
	defer tx.Rollback()
	format, e := employeeOpen(ctx, tx, sid, eid)
	if e != nil {
		return false, e
	}
	var outcome Outcome
	var login, pass, bid, ext string
	tx.QueryRowContext(ctx, `SELECT COALESCE(e.outcome,''),COALESCE(e.bitrix_login,''),COALESCE(e.bitrix_pass,''),COALESCE(e.bitrix_id,''),COALESCE(x.number,'') FROM sand_employees e LEFT JOIN sandbox_extensions x ON x.employee_id=e.id AND x.released_at IS NULL WHERE e.id=?`, eid).Scan(&outcome, &login, &pass, &bid, &ext)
	tasks := EmployeeTasksFor(format, outcome)
	task, ok := TaskByKey(tasks, key)
	if !ok {
		return false, ErrUnknownTask
	}
	if key == "bitrix" || key == "extension" || key == "outcome" || key == "base_filled" {
		return false, ErrStructuredTask
	}
	marks, _ := employeeMarkKeys(ctx, tx, eid)
	done := func(k string) bool {
		if k == "bitrix" {
			return login != "" && pass != "" && bid != ""
		}
		if k == "extension" {
			return ext != ""
		}
		if k == "outcome" {
			return outcome != ""
		}
		return marks[k]
	}
	marked := !marks[key]
	now := time.Now()
	if marked {
		for _, need := range task.Needs {
			if !done(need) {
				return false, ErrTaskBlocked
			}
		}
		_, e = tx.ExecContext(ctx, `INSERT INTO employee_marks(employee_id,task,done_at,done_by,done_login) VALUES(?,?,?,?,?)`, eid, key, formatTime(now), actor.ID, actor.Login)
	} else {
		var remove []string
		for _, candidate := range tasks {
			if marks[candidate.Key] && contains(candidate.Needs, key) {
				remove = append(remove, candidate.Key)
			}
		}
		if len(remove) > 0 && !cascade {
			return false, CascadeRequired{len(remove)}
		}
		for _, k := range remove {
			_, e = tx.ExecContext(ctx, `DELETE FROM employee_marks WHERE employee_id=? AND task=?`, eid, k)
			if e != nil {
				return false, e
			}
		}
		_, e = tx.ExecContext(ctx, `DELETE FROM employee_marks WHERE employee_id=? AND task=?`, eid, key)
	}
	if e != nil {
		return false, e
	}
	action := "employee.unmark"
	if marked {
		action = "employee.mark"
	}
	QueueAudit(ctx, tx, AuditEvent{At: now, ActorID: &actor.ID, ActorLogin: actor.Login, Action: action, Entity: "sand_employee", EntityID: &eid, Details: task.Title})
	return marked, tx.Commit()
}

func employeeMarkKeys(ctx context.Context, tx *sql.Tx, eid int64) (map[string]bool, error) {
	rows, e := tx.QueryContext(ctx, `SELECT task FROM employee_marks WHERE employee_id=?`, eid)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	m := map[string]bool{}
	for rows.Next() {
		var k string
		rows.Scan(&k)
		m[k] = true
	}
	return m, rows.Err()
}

func (db *DB) IssueDeals(ctx context.Context, actor Actor, sid, eid int64, limit int) (DealBatch, error) {
	tx, e := db.BeginTx(ctx, nil)
	if e != nil {
		return DealBatch{}, e
	}
	defer tx.Rollback()
	if _, e = employeeOpen(ctx, tx, sid, eid); e != nil {
		return DealBatch{}, e
	}
	var bid string
	tx.QueryRowContext(ctx, `SELECT COALESCE(bitrix_id,'') FROM sand_employees WHERE id=?`, eid).Scan(&bid)
	if bid == "" {
		return DealBatch{}, ErrBitrixRequired
	}
	var existing int64
	e = tx.QueryRowContext(ctx, `SELECT id FROM deal_batches WHERE sandbox_id=? AND employee_id=? AND imported_at IS NULL ORDER BY id DESC LIMIT 1`, sid, eid).Scan(&existing)
	if e == nil {
		tx.Rollback()
		batches, e := db.employeeBatches(ctx, sid, eid)
		for _, b := range batches {
			if b.ID == existing {
				return b, e
			}
		}
		return DealBatch{}, e
	}
	if !errors.Is(e, sql.ErrNoRows) {
		return DealBatch{}, e
	}
	if limit != 100 && limit != 300 {
		return DealBatch{}, errors.New("порция бывает 100 или 300 сделок")
	}
	rows, e := tx.QueryContext(ctx, `SELECT deal_id FROM sandbox_deals WHERE sandbox_id=? AND employee_id IS NULL ORDER BY deal_id LIMIT ?`, sid, limit)
	if e != nil {
		return DealBatch{}, e
	}
	var deals []string
	for rows.Next() {
		var id string
		rows.Scan(&id)
		deals = append(deals, id)
	}
	rows.Close()
	if len(deals) == 0 {
		return DealBatch{}, ErrNoDeals
	}
	now := time.Now()
	res, e := tx.ExecContext(ctx, `INSERT INTO deal_batches(sandbox_id,employee_id,size,created_at) VALUES(?,?,?,?)`, sid, eid, len(deals), formatTime(now))
	if e != nil {
		return DealBatch{}, e
	}
	batchID, _ := res.LastInsertId()
	for _, id := range deals {
		if _, e = tx.ExecContext(ctx, `UPDATE sandbox_deals SET employee_id=?,batch_id=?,given_at=? WHERE sandbox_id=? AND deal_id=? AND employee_id IS NULL`, eid, batchID, formatTime(now), sid, id); e != nil {
			return DealBatch{}, e
		}
	}
	QueueAudit(ctx, tx, AuditEvent{At: now, ActorID: &actor.ID, ActorLogin: actor.Login, Action: "employee.deals", Entity: "sand_employee", EntityID: &eid, Details: fmt.Sprintf("выдано %d сделок", len(deals))})
	if e = tx.Commit(); e != nil {
		return DealBatch{}, e
	}
	return DealBatch{ID: batchID, Size: len(deals), CreatedAt: now, Deals: deals}, nil
}

func (db *DB) MarkBatchImported(ctx context.Context, actor Actor, sid, eid, batchID int64) error {
	tx, e := db.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if _, e = employeeOpen(ctx, tx, sid, eid); e != nil {
		return e
	}
	now := time.Now()
	res, e := tx.ExecContext(ctx, `UPDATE deal_batches SET imported_at=?,imported_by=?,imported_login=? WHERE id=? AND sandbox_id=? AND employee_id=? AND imported_at IS NULL`, formatTime(now), actor.ID, actor.Login, batchID, sid, eid)
	if e != nil {
		return e
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return ErrBatchImported
	}
	_, e = tx.ExecContext(ctx, `INSERT INTO employee_marks(employee_id,task,done_at,done_by,done_login) VALUES(?,?,?,?,?) ON CONFLICT(employee_id,task) DO UPDATE SET done_at=excluded.done_at,done_by=excluded.done_by,done_login=excluded.done_login`, eid, "base_filled", formatTime(now), actor.ID, actor.Login)
	if e != nil {
		return e
	}
	QueueAudit(ctx, tx, AuditEvent{At: now, ActorID: &actor.ID, ActorLogin: actor.Login, Action: "employee.deals.imported", Entity: "sand_employee", EntityID: &eid, Details: fmt.Sprintf("порция %d налита", batchID)})
	return tx.Commit()
}

func (db *DB) DeleteEmployee(ctx context.Context, actor Actor, sid, eid int64) error {
	tx, e := db.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if _, e = employeeOpen(ctx, tx, sid, eid); e != nil {
		return e
	}
	var login string
	tx.QueryRowContext(ctx, `SELECT COALESCE(bitrix_login,'') FROM sand_employees WHERE id=?`, eid).Scan(&login)
	if login != "" {
		return ErrLoginExists
	}
	_, e = tx.ExecContext(ctx, `DELETE FROM sand_employees WHERE id=? AND sandbox_id=?`, eid, sid)
	if e != nil {
		return e
	}
	QueueAudit(ctx, tx, AuditEvent{At: time.Now(), ActorID: &actor.ID, ActorLogin: actor.Login, Action: "employee.delete", Entity: "sand_employee", EntityID: &eid, Details: "сотрудник удалён"})
	return tx.Commit()
}
