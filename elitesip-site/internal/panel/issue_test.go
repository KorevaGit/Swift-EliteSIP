package panel

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/koreva/elitesip-site/internal/activation"
	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/storage"
)

type memoryPublisher struct {
	objects map[string][]byte
	fail    error
}

func (p *memoryPublisher) Put(_ context.Context, objectKey string, data []byte) error {
	if p.fail != nil {
		return p.fail
	}
	if p.objects == nil {
		p.objects = map[string][]byte{}
	}
	p.objects[objectKey] = data
	return nil
}

func newIssuer(t *testing.T) (*Issuer, *memoryPublisher, *storage.DB) {
	t.Helper()

	db, err := storage.Open(filepath.Join(t.TempDir(), "panel.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	pub := &memoryPublisher{}
	return &Issuer{DB: db, Publisher: pub, Secret: []byte("секрет-сервера")}, pub, db
}

// Готовое к выпуску состояние: сотрудник с номером и предустановкой, пароль
// конторы задан.
func seedReady(t *testing.T, db *storage.DB) int64 {
	t.Helper()
	ctx := context.Background()

	preset, err := db.CreatePreset(ctx, nil, "Менеджер")
	if err != nil {
		t.Fatalf("CreatePreset: %v", err)
	}
	if _, err := db.SaveRevision(ctx, nil, preset.ID, 2,
		json.RawMessage(`{"queues":{"1000":"Раздача"}}`), "первая"); err != nil {
		t.Fatalf("SaveRevision: %v", err)
	}
	employee, err := db.CreateEmployee(ctx, nil, model.Employee{
		Name: "Пётр", Number: "172", SIPPassword: "секрет-172", PresetID: &preset.ID,
	})
	if err != nil {
		t.Fatalf("CreateEmployee: %v", err)
	}
	if err := db.SetSetting(ctx, nil, storage.SettingAdminPassword, "пароль-конторы"); err != nil {
		t.Fatalf("SetSetting: %v", err)
	}
	return employee.ID
}

// Полный круг: выпустили ключ, забрали пакет по вычисленному из ключа адресу,
// распечатали тем же ключом и получили то, что клали.
func TestIssueRoundTrip(t *testing.T) {
	issuer, pub, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	key, record, err := issuer.Issue(ctx, nil, employeeID, "первый ноутбук")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	sealed, ok := pub.objects[key.ObjectKey()]
	if !ok {
		t.Fatalf("пакета по адресу %q нет", key.ObjectKey())
	}
	if record.ObjectKey != key.ObjectKey() {
		t.Errorf("в базе адрес %q, у ключа %q", record.ObjectKey, key.ObjectKey())
	}

	plaintext, err := activation.Open(key, sealed)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	var payload activation.Payload
	if err := json.Unmarshal(plaintext, &payload); err != nil {
		t.Fatalf("разобрать пакет: %v", err)
	}

	if payload.Number != "172" || payload.SIPPassword != "секрет-172" {
		t.Errorf("в пакете номер %q с паролем %q", payload.Number, payload.SIPPassword)
	}
	if payload.AdminPassword != "пароль-конторы" {
		t.Errorf("административный пароль в пакете %q", payload.AdminPassword)
	}
	if payload.Employee != "Пётр" {
		t.Errorf("имя сотрудника в пакете %q", payload.Employee)
	}
	if payload.Preset.Name != "Менеджер" || payload.Preset.Revision != 1 {
		t.Errorf("предустановка в пакете %q ревизии %d", payload.Preset.Name, payload.Preset.Revision)
	}
	if payload.Preset.SchemaVersion != 2 {
		t.Errorf("версия схемы в пакете %d", payload.Preset.SchemaVersion)
	}
	if payload.InstallationID != record.InstallationID {
		t.Error("идентификатор машины в пакете и в базе разошёлся")
	}
}

// Панель ключа не хранит: по базе его восстановить нельзя.
func TestIssuedKeyIsNotStored(t *testing.T) {
	issuer, _, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	key, record, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	if record.KeyFingerprint == string(key) || record.KeyFingerprint == key.String() {
		t.Fatal("в базе лежит сам ключ, а не отпечаток")
	}
	if record.KeyPrefix != key.Prefix() {
		t.Errorf("в базе начало ключа %q, у ключа %q", record.KeyPrefix, key.Prefix())
	}

	// Найти активацию по ключу можно — это и есть смысл отпечатка.
	found, err := db.ActivationByFingerprint(ctx, activation.Fingerprint(issuer.Secret, key))
	if err != nil {
		t.Fatalf("ActivationByFingerprint: %v", err)
	}
	if found.ID != record.ID {
		t.Errorf("нашлась активация %d, выпускалась %d", found.ID, record.ID)
	}
}

func TestIssuedKeyExpiresInTwoDays(t *testing.T) {
	issuer, _, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	fixed := time.Date(2026, 8, 24, 10, 0, 0, 0, time.UTC)
	issuer.Now = func() time.Time { return fixed }

	_, record, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	want := fixed.Add(48 * time.Hour)
	if !record.ExpiresAt.Equal(want) {
		t.Errorf("срок %s, ожидался %s", record.ExpiresAt, want)
	}
	if state := record.State(fixed.Add(47 * time.Hour)); state != "ожидает" {
		t.Errorf("за час до срока состояние %q", state)
	}
	if state := record.State(fixed.Add(49 * time.Hour)); state != "просрочено" {
		t.Errorf("через час после срока состояние %q", state)
	}
}

// Пакет кладётся до записи в базу: выданный ключ, которому нечего открывать, —
// это звонок в поддержку из дома.
func TestIssueDoesNotRecordWhenPublishFails(t *testing.T) {
	issuer, pub, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)
	pub.fail = errors.New("бакет недоступен")

	if _, _, err := issuer.Issue(ctx, nil, employeeID, ""); err == nil {
		t.Fatal("выпуск прошёл, хотя пакет не выложился")
	}

	list, err := db.ListActivations(ctx, employeeID)
	if err != nil {
		t.Fatalf("ListActivations: %v", err)
	}
	if len(list) != 0 {
		t.Errorf("активаций записано %d, ожидалось 0", len(list))
	}
}

func TestIssueRequiresNumber(t *testing.T) {
	issuer, _, db := newIssuer(t)
	ctx := context.Background()

	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, preset.ID, 2, json.RawMessage(`{}`), "")
	employee, _ := db.CreateEmployee(ctx, nil, model.Employee{Name: "Без номера", PresetID: &preset.ID})
	db.SetSetting(ctx, nil, storage.SettingAdminPassword, "пароль")

	_, _, err := issuer.Issue(ctx, nil, employee.ID, "")
	if !errors.Is(err, storage.ErrNoNumber) {
		t.Fatalf("ошибка %v, ожидалась ErrNoNumber", err)
	}
}

func TestIssueRequiresPresetRevision(t *testing.T) {
	issuer, _, db := newIssuer(t)
	ctx := context.Background()

	preset, _ := db.CreatePreset(ctx, nil, "Пустая")
	employee, _ := db.CreateEmployee(ctx, nil, model.Employee{
		Name: "Пётр", Number: "172", SIPPassword: "секрет", PresetID: &preset.ID,
	})
	db.SetSetting(ctx, nil, storage.SettingAdminPassword, "пароль")

	_, _, err := issuer.Issue(ctx, nil, employee.ID, "")
	if !errors.Is(err, storage.ErrNoPreset) {
		t.Fatalf("ошибка %v, ожидалась ErrNoPreset", err)
	}
}

// Без административного пароля машина активируется, но «Управление» на ней
// потом не откроется ничем.
func TestIssueRequiresAdminPassword(t *testing.T) {
	issuer, _, db := newIssuer(t)
	ctx := context.Background()

	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, preset.ID, 2, json.RawMessage(`{}`), "")
	employee, _ := db.CreateEmployee(ctx, nil, model.Employee{
		Name: "Пётр", Number: "172", SIPPassword: "секрет", PresetID: &preset.ID,
	})

	if _, _, err := issuer.Issue(ctx, nil, employee.ID, ""); err == nil {
		t.Fatal("ключ выпустился без административного пароля конторы")
	}
}

// Удалённому сотруднику ключ не выпускается: увольнения больше нет, есть
// удаление, и карточки после него не существует.
func TestIssueRefusesDeleted(t *testing.T) {
	issuer, _, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	if err := db.DeleteEmployee(ctx, nil, employeeID); err != nil {
		t.Fatalf("DeleteEmployee: %v", err)
	}
	_, _, err := issuer.Issue(ctx, nil, employeeID, "")
	if !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("ошибка %v, ожидалась ErrNotFound", err)
	}
}

// Второй ключ тому же человеку — это его вторая машина, и это норма.
func TestIssueTwiceGivesTwoActivations(t *testing.T) {
	issuer, pub, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	first, _, err := issuer.Issue(ctx, nil, employeeID, "офис")
	if err != nil {
		t.Fatalf("первый ключ: %v", err)
	}
	second, _, err := issuer.Issue(ctx, nil, employeeID, "дом")
	if err != nil {
		t.Fatalf("второй ключ: %v", err)
	}

	if first == second {
		t.Fatal("два выпуска дали один ключ")
	}
	if len(pub.objects) != 2 {
		t.Errorf("пакетов выложено %d, ожидалось 2", len(pub.objects))
	}

	list, err := db.ListActivations(ctx, employeeID)
	if err != nil {
		t.Fatalf("ListActivations: %v", err)
	}
	if len(list) != 2 {
		t.Errorf("активаций %d, ожидалось 2", len(list))
	}
}

// Одноразовость: пакет забрали, и это видно в панели.
func TestMarkFetchedIsOneWay(t *testing.T) {
	issuer, _, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	key, _, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	first := time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
	if err := db.MarkFetched(ctx, key.ObjectKey(), first); err != nil {
		t.Fatalf("MarkFetched: %v", err)
	}
	// Повторный разбор журнала Worker'а не должен переписывать момент.
	if err := db.MarkFetched(ctx, key.ObjectKey(), first.Add(time.Hour)); err != nil {
		t.Fatalf("повторный MarkFetched: %v", err)
	}

	list, _ := db.ListActivations(ctx, employeeID)
	if len(list) != 1 || list[0].FetchedAt == nil {
		t.Fatal("активация не отмечена забранной")
	}
	if !list[0].FetchedAt.Equal(first) {
		t.Errorf("момент получения %s, ожидался %s", list[0].FetchedAt, first)
	}
	if state := list[0].State(time.Now()); state != "активировано" {
		t.Errorf("состояние %q, ожидалось «активировано»", state)
	}
}
