package sand

import (
	"bytes"
	"context"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/xuri/excelize/v2"
)

type EmployeeExchange struct{ Name, Login, Password, BitrixID, Extension string }

func (db *DB) ExportEmployees(ctx context.Context, sandboxID int64) ([]EmployeeExchange, error) {
	rows, err := db.QueryContext(ctx, `SELECT e.name,COALESCE(e.bitrix_login,''),COALESCE(e.bitrix_pass,''),COALESCE(e.bitrix_id,''),COALESCE(x.number,'') FROM sand_employees e LEFT JOIN sandbox_extensions x ON x.employee_id=e.id AND x.released_at IS NULL WHERE e.sandbox_id=? ORDER BY e.id`, sandboxID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []EmployeeExchange
	for rows.Next() {
		var e EmployeeExchange
		if err := rows.Scan(&e.Name, &e.Login, &e.Password, &e.BitrixID, &e.Extension); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	if len(out) == 0 {
		return nil, ErrNotFound
	}
	return out, rows.Err()
}

var exchangeHeaders = []string{"ФИО", "Логин", "Пароль", "ID Битрикса", "Номер"}

func WriteEmployeesCSV(w io.Writer, rows []EmployeeExchange) error {
	c := csv.NewWriter(w)
	if err := c.Write(exchangeHeaders); err != nil {
		return err
	}
	for _, r := range rows {
		if err := c.Write([]string{r.Name, r.Login, r.Password, r.BitrixID, r.Extension}); err != nil {
			return err
		}
	}
	c.Flush()
	return c.Error()
}

func WriteEmployeesXLSX(w io.Writer, rows []EmployeeExchange) error {
	f := excelize.NewFile()
	defer f.Close()
	sheet := "Сотрудники"
	f.SetSheetName("Sheet1", sheet)
	for col, h := range exchangeHeaders {
		cell, _ := excelize.CoordinatesToCellName(col+1, 1)
		f.SetCellValue(sheet, cell, h)
	}
	for i, r := range rows {
		values := []any{r.Name, r.Login, r.Password, r.BitrixID, r.Extension}
		for col, v := range values {
			cell, _ := excelize.CoordinatesToCellName(col+1, i+2)
			f.SetCellValue(sheet, cell, v)
		}
	}
	style, _ := f.NewStyle(&excelize.Style{Font: &excelize.Font{Bold: true}, Fill: excelize.Fill{Type: "pattern", Color: []string{"#EFE9D8"}, Pattern: 1}})
	f.SetCellStyle(sheet, "A1", "E1", style)
	f.SetColWidth(sheet, "A", "A", 32)
	f.SetColWidth(sheet, "B", "C", 20)
	f.SetColWidth(sheet, "D", "E", 16)
	f.SetPanes(sheet, &excelize.Panes{Freeze: true, YSplit: 1, TopLeftCell: "A2", ActivePane: "bottomLeft"})
	return f.Write(w)
}

func ReadEmployeesXLSX(r io.Reader) ([]EmployeeExchange, error) {
	data, err := io.ReadAll(io.LimitReader(r, 16<<20))
	if err != nil {
		return nil, err
	}
	f, err := excelize.OpenReader(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("открыть Excel: %w", err)
	}
	defer f.Close()
	sheets := f.GetSheetList()
	if len(sheets) == 0 {
		return nil, errors.New("в Excel нет листов")
	}
	table, err := f.GetRows(sheets[0])
	if err != nil {
		return nil, err
	}
	if len(table) < 2 {
		return nil, ErrNoEmployees
	}
	index := map[string]int{}
	for i, h := range table[0] {
		index[strings.ToLower(strings.TrimSpace(h))] = i
	}
	need, ok := index["фио"]
	if !ok {
		return nil, errors.New("в Excel нет обязательной колонки «ФИО»")
	}
	value := func(row []string, name string) string {
		i, ok := index[name]
		if !ok || i >= len(row) {
			return ""
		}
		return strings.TrimSpace(row[i])
	}
	var out []EmployeeExchange
	for _, row := range table[1:] {
		name := ""
		if need < len(row) {
			name = strings.TrimSpace(row[need])
		}
		if name == "" {
			continue
		}
		out = append(out, EmployeeExchange{Name: name, Login: value(row, "логин"), Password: value(row, "пароль"), BitrixID: value(row, "id битрикса"), Extension: value(row, "номер")})
	}
	if len(out) == 0 {
		return nil, ErrNoEmployees
	}
	return out, nil
}

func (db *DB) ImportSandbox(ctx context.Context, actor Actor, rop string, format Format, people []EmployeeExchange) (Sandbox, error) {
	rop = strings.TrimSpace(rop)
	if !KnownROP(rop) {
		return Sandbox{}, ErrUnknownROP
	}
	if format != Office && format != Remote {
		return Sandbox{}, ErrBadFormat
	}
	if len(people) == 0 {
		return Sandbox{}, ErrNoEmployees
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return Sandbox{}, err
	}
	defer tx.Rollback()
	now := time.Now()
	res, err := tx.ExecContext(ctx, `INSERT INTO sandboxes(rop,format,created_at) VALUES(?,?,?)`, rop, string(format), formatTime(now))
	if err != nil {
		return Sandbox{}, conflict(err, err)
	}
	sid, _ := res.LastInsertId()
	seenNumbers := map[string]bool{}
	for _, p := range people {
		name := strings.TrimSpace(p.Name)
		if name == "" {
			return Sandbox{}, ErrNoEmployees
		}
		res, err = tx.ExecContext(ctx, `INSERT INTO sand_employees(sandbox_id,name,bitrix_login,bitrix_pass,bitrix_id) VALUES(?,?,?,?,?)`, sid, name, strings.TrimSpace(p.Login), strings.TrimSpace(p.Password), strings.TrimSpace(p.BitrixID))
		if err != nil {
			return Sandbox{}, conflict(err, err)
		}
		eid, _ := res.LastInsertId()
		number := strings.TrimSpace(p.Extension)
		if number != "" {
			if seenNumbers[number] {
				return Sandbox{}, ErrNumberBusy
			}
			seenNumbers[number] = true
			if _, err = tx.ExecContext(ctx, `INSERT INTO sandbox_extensions(sandbox_id,number,employee_id) VALUES(?,?,?)`, sid, number, eid); err != nil {
				return Sandbox{}, conflict(err, ErrNumberBusy)
			}
		}
	}
	QueueAudit(ctx, tx, AuditEvent{At: now, ActorID: &actor.ID, ActorLogin: actor.Login, Action: "sandbox.import", Entity: "sandbox", EntityID: &sid, Details: fmt.Sprintf("РОП %s, импортировано %d", rop, len(people))})
	if err = tx.Commit(); err != nil {
		return Sandbox{}, conflict(err, err)
	}
	return Sandbox{ID: sid, ROP: rop, Format: format, CreatedAt: now.UTC()}, nil
}

type ArchiveFilter struct {
	ROP      string
	Format   Format
	From, To time.Time
}

func (db *DB) ListArchive(ctx context.Context, f ArchiveFilter) ([]SandboxCard, error) {
	cards, err := db.ListSandboxes(ctx, true)
	if err != nil {
		return nil, err
	}
	out := cards[:0]
	for _, c := range cards {
		if f.ROP != "" && c.ROP != f.ROP {
			continue
		}
		if f.Format != "" && c.Format != f.Format {
			continue
		}
		if !f.From.IsZero() && (c.ClosedAt == nil || c.ClosedAt.Before(f.From)) {
			continue
		}
		if !f.To.IsZero() && (c.ClosedAt == nil || c.ClosedAt.After(f.To.Add(24*time.Hour))) {
			continue
		}
		out = append(out, c)
	}
	return out, nil
}

const RejectedRetention = 31 * 24 * time.Hour

func (db *DB) PurgeRejected(ctx context.Context, now time.Time) (int64, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, `SELECT id FROM sand_employees WHERE outcome='rejected' AND purged_at IS NULL AND outcome_at < ?`, formatTime(now.Add(-RejectedRetention)))
	if err != nil {
		return 0, err
	}
	var ids []int64
	for rows.Next() {
		var id int64
		rows.Scan(&id)
		ids = append(ids, id)
	}
	rows.Close()
	for _, id := range ids {
		tx.ExecContext(ctx, `DELETE FROM employee_marks WHERE employee_id=?`, id)
		tx.ExecContext(ctx, `UPDATE sandbox_extensions SET released_at=COALESCE(released_at,?) WHERE employee_id=?`, formatTime(now), id)
		tx.ExecContext(ctx, `UPDATE sandbox_deals SET employee_id=NULL,batch_id=NULL,given_at=NULL WHERE employee_id=?`, id)
		_, err = tx.ExecContext(ctx, `UPDATE sand_employees SET name='Удалённый сотрудник',bitrix_login=NULL,bitrix_pass=NULL,bitrix_id=NULL,purged_at=? WHERE id=?`, formatTime(now), id)
		if err != nil {
			return 0, err
		}
	}
	if err = tx.Commit(); err != nil {
		return 0, err
	}
	return int64(len(ids)), nil
}
