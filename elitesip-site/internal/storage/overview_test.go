package storage

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestOverviewCountsAndEmptyTails(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	preset := seedPublishedPreset(t, db)
	whole := person("Пётр", "172", "секрет")
	whole.PresetID = &preset
	db.CreateEmployee(ctx, nil, whole)

	o, err := db.Overview(ctx, time.Now())
	if err != nil {
		t.Fatalf("Overview: %v", err)
	}
	if o.Employees != 1 {
		t.Errorf("сотрудников %d, ожидался 1", o.Employees)
	}
	if len(o.Loose) != 0 {
		t.Errorf("на заполненной панели висят хвосты: %+v", o.Loose)
	}
}

// Самый дорогой из хвостов: правка сделана, администратор считает дело
// закрытым, а на машинах по-прежнему прежнее.
func TestOverviewShowsUnpublishedRevision(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, preset.ID, 2, []byte(`{}`), "")

	o, _ := db.Overview(ctx, time.Now())
	end := findEnd(t, o, "preset")
	if !strings.Contains(end.Text, "не выложена") {
		t.Errorf("хвост говорит не о том: %q", end.Text)
	}
	if end.Href != "/presets/1" {
		t.Errorf("ссылка ведёт на %q — чинится оно не там", end.Href)
	}
}

// Ключ выдан, машина не отметилась. Просроченные сюда не попадают: чинить в
// них нечего, выпускается новый — и хвост убирается сам.
func TestOverviewShowsPendingKeyButNotExpiredOne(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	preset := seedPublishedPreset(t, db)
	e := person("Пётр", "172", "секрет")
	e.PresetID = &preset
	employee, _ := db.CreateEmployee(ctx, nil, e)

	issued := time.Date(2026, 8, 24, 9, 0, 0, 0, time.UTC)
	db.SaveActivation(ctx, nil, IssueRecord{
		EmployeeID: employee.ID, PresetID: preset,
		KeyFingerprint: "hash", KeyPrefix: "K7M2", ObjectKey: "obj",
		InstallationID: "inst", ExpiresAt: issued.Add(48 * time.Hour),
	})

	live, _ := db.Overview(ctx, issued.Add(time.Hour))
	end := findEnd(t, live, "key")
	if !strings.Contains(end.Text, "K7M2") || end.Href != "/employees/1" {
		t.Errorf("хвост про ключ вышел такой: %+v", end)
	}

	later, _ := db.Overview(ctx, issued.Add(72*time.Hour))
	for _, l := range later.Loose {
		if l.Kind == "key" {
			t.Errorf("просроченный ключ остался в хвостах: %q", l.Text)
		}
	}
}

// Чего именно не хватает, говорится прямо: «карточка заполнена не до конца»
// отправляет человека сравнивать поля глазами.
func TestOverviewNamesWhatEmployeeLacks(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	preset := seedPublishedPreset(t, db)
	noNumber := person("Без номера", "", "")
	noNumber.PresetID = &preset
	db.CreateEmployee(ctx, nil, noNumber)
	db.CreateEmployee(ctx, nil, person("Совсем пустой", "", ""))

	o, _ := db.Overview(ctx, time.Now())

	var texts []string
	for _, l := range o.Loose {
		if l.Kind == "employee" {
			texts = append(texts, l.Text)
		}
	}
	if len(texts) != 2 {
		t.Fatalf("незаполненных нашлось %d, ожидалось 2: %v", len(texts), texts)
	}
	if !strings.Contains(texts[0], "номера и SIP-пароля") || strings.Contains(texts[0], "предустановки") {
		t.Errorf("первому не хватает только номера, а сказано: %q", texts[0])
	}
	if !strings.Contains(texts[1], "номера и SIP-пароля, предустановки") {
		t.Errorf("второму не хватает всего, а сказано: %q", texts[1])
	}
}

// Отозванная активация машиной не считается.
func TestOverviewIgnoresRevokedActivations(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	preset := seedPublishedPreset(t, db)
	e := person("Пётр", "172", "секрет")
	e.PresetID = &preset
	employee, _ := db.CreateEmployee(ctx, nil, e)
	saved, _ := db.SaveActivation(ctx, nil, IssueRecord{
		EmployeeID: employee.ID, PresetID: preset,
		KeyFingerprint: "hash", KeyPrefix: "K7M2", ObjectKey: "obj",
		InstallationID: "inst", ExpiresAt: time.Now().Add(48 * time.Hour),
	})
	if err := db.RevokeActivation(ctx, nil, saved.ID); err != nil {
		t.Fatalf("RevokeActivation: %v", err)
	}

	o, _ := db.Overview(ctx, time.Now())
	if o.Machines != 0 {
		t.Errorf("машин %d, ожидалось 0", o.Machines)
	}
	for _, l := range o.Loose {
		if l.Kind == "key" {
			t.Errorf("отозванный ключ остался в хвостах: %q", l.Text)
		}
	}
}

// seedPublishedPreset заводит предустановку с выложенной ревизией — такую,
// которая сама хвоста не даёт.
func seedPublishedPreset(t *testing.T, db *DB) int64 {
	t.Helper()
	ctx := context.Background()

	preset, err := db.CreatePreset(ctx, nil, "Менеджер")
	if err != nil {
		t.Fatalf("CreatePreset: %v", err)
	}
	revision, err := db.SaveRevision(ctx, nil, preset.ID, 2, []byte(`{}`), "")
	if err != nil {
		t.Fatalf("SaveRevision: %v", err)
	}
	if _, err := db.Exec(`UPDATE preset_revisions SET published_at = ? WHERE id = ?`,
		"2026-08-24T09:00:00Z", revision.ID); err != nil {
		t.Fatalf("выкладка: %v", err)
	}
	return preset.ID
}

func findEnd(t *testing.T, o Overview, kind string) LooseEnd {
	t.Helper()
	for _, l := range o.Loose {
		if l.Kind == kind {
			return l
		}
	}
	t.Fatalf("хвоста %q нет: %+v", kind, o.Loose)
	return LooseEnd{}
}
