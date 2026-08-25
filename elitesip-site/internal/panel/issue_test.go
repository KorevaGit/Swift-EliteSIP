package panel

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
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

func (p *memoryPublisher) countWithPrefix(prefix string) int {
	count := 0
	for key := range p.objects {
		if strings.HasPrefix(key, prefix) {
			count++
		}
	}
	return count
}

func newIssuer(t *testing.T) (*Issuer, *memoryPublisher, *storage.DB) {
	t.Helper()

	db, err := storage.Open(filepath.Join(t.TempDir(), "panel.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	pub := &memoryPublisher{}
	issuer := &Issuer{
		DB:        db,
		Publisher: pub,
		Secret:    []byte("секрет-сервера"),
		Machines: &MachineWriter{
			Publisher:  pub,
			SigningKey: testSigningKey(t),
		},
	}
	return issuer, pub, db
}

// testSigningKey — ключ подписи помашинных объектов. Постоянный: проверяем не
// криптографию, а то, что объекты выкладываются.
func testSigningKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("ed25519.GenerateKey: %v", err)
	}
	return key
}

// Готовое к выпуску состояние: сотрудник с номером и предустановкой, пароль
// предустановки задан.
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
	if err := db.SetPresetAdminPassword(ctx, nil, preset.ID, "пароль-предустановки"); err != nil {
		t.Fatalf("SetPresetAdminPassword: %v", err)
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

	bound, err := activation.Bind(key, "")
	if err != nil {
		t.Fatalf("Bind: %v", err)
	}

	sealed, ok := pub.objects[bound.ObjectKey()]
	if !ok {
		t.Fatalf("пакета по адресу %q нет", bound.ObjectKey())
	}
	if record.ObjectKey != bound.ObjectKey() {
		t.Errorf("в базе адрес %q, у ключа %q", record.ObjectKey, bound.ObjectKey())
	}

	plaintext, err := bound.Open(sealed)
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
	// Административного пароля в пакете нет: он приезжает помашинным
	// объектом access/<installation_id>, чтобы у него не было двух источников.
	if bytes.Contains(plaintext, []byte("пароль-предустановки")) {
		t.Error("административный пароль лежит в пакете активации")
	}
	if payload.ChannelKey == "" {
		t.Error("в пакете нет ключа доступа к каналу — машине нечем будет ходить за предустановками")
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
	db.SetPresetAdminPassword(ctx, nil, preset.ID, "пароль")

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
	db.SetPresetAdminPassword(ctx, nil, preset.ID, "пароль")

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
	// Считаются только пакеты: рядом с ними в бакете лежат ещё помашинные
	// объекты — перечень ключей доступа и то, что машина забирает по нему.
	if got := pub.countWithPrefix(packagePrefix); got != 2 {
		t.Errorf("пакетов выложено %d, ожидалось 2", got)
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

	bound, err := activation.Bind(key, "")
	if err != nil {
		t.Fatalf("Bind: %v", err)
	}

	first := time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
	if err := db.MarkFetched(ctx, bound.ObjectKey(), first); err != nil {
		t.Fatalf("MarkFetched: %v", err)
	}
	// Повторный разбор журнала Worker'а не должен переписывать момент.
	if err := db.MarkFetched(ctx, bound.ObjectKey(), first.Add(time.Hour)); err != nil {
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

// Правило «не больше трёх невостребованных»: четвёртый ключ вытесняет
// старейший, и вытесняет именно ключ, а не рабочее место.
func TestFourthKeyEvictsOldest(t *testing.T) {
	issuer, _, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	var ids []int64
	for i := 0; i < MaxPendingKeys+1; i++ {
		_, record, err := issuer.Issue(ctx, nil, employeeID, "")
		if err != nil {
			t.Fatalf("ключ %d: %v", i+1, err)
		}
		ids = append(ids, record.ID)
	}

	pending, err := db.UnfetchedActivations(ctx, employeeID)
	if err != nil {
		t.Fatalf("UnfetchedActivations: %v", err)
	}
	if len(pending) != MaxPendingKeys {
		t.Fatalf("живых невостребованных ключей %d, ожидалось %d", len(pending), MaxPendingKeys)
	}

	list, err := db.ListActivations(ctx, employeeID)
	if err != nil {
		t.Fatalf("ListActivations: %v", err)
	}
	if len(list) != MaxPendingKeys+1 {
		t.Fatalf("строк активаций %d — гашение не должно удалять строку", len(list))
	}

	// Погашен именно первый: у сотрудника с четырьмя ключами старейший — самый
	// бесполезный, а вот забранный старейший вытеснять нельзя, см. ниже.
	for _, a := range list {
		if a.ID == ids[0] {
			if a.SupersededAt == nil {
				t.Error("старейший ключ не погашен")
			}
			if a.State(time.Now()) != model.ActivationSuperseded {
				t.Errorf("состояние старейшего %q, ожидалось «вытеснен»", a.State(time.Now()))
			}
		} else if a.SupersededAt != nil {
			t.Errorf("погашен не тот ключ: %d", a.ID)
		}
	}
}

// Забранная активация — это рабочее место, а не ключ: её строка держит на себе
// привязку машины к сотруднику, и вытеснять её нельзя ни при каком счёте.
func TestFetchedActivationIsNeverEvicted(t *testing.T) {
	issuer, _, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	_, first, err := issuer.Issue(ctx, nil, employeeID, "рабочая машина")
	if err != nil {
		t.Fatalf("первый ключ: %v", err)
	}
	if err := db.MarkFetched(ctx, first.ObjectKey, time.Now()); err != nil {
		t.Fatalf("MarkFetched: %v", err)
	}

	for i := 0; i < MaxPendingKeys+2; i++ {
		if _, _, err := issuer.Issue(ctx, nil, employeeID, ""); err != nil {
			t.Fatalf("ключ %d: %v", i+1, err)
		}
	}

	list, err := db.ListActivations(ctx, employeeID)
	if err != nil {
		t.Fatalf("ListActivations: %v", err)
	}
	for _, a := range list {
		if a.ID == first.ID && a.SupersededAt != nil {
			t.Fatal("вытеснено рабочее место — машина станет «удалённого сотрудника» навсегда")
		}
	}
}

// Ключ перепрошивки привязан к машине: адрес пакета выводится вместе с её
// installation_id, и посчитанный без привязки туда не попадает.
func TestReflashKeyIsBoundToMachine(t *testing.T) {
	issuer, pub, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	_, first, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("первый ключ: %v", err)
	}
	if err := db.MarkFetched(ctx, first.ObjectKey, time.Now()); err != nil {
		t.Fatalf("MarkFetched: %v", err)
	}

	key, record, err := issuer.Reflash(ctx, nil, first.InstallationID, "сменил отдел")
	if err != nil {
		t.Fatalf("Reflash: %v", err)
	}
	if record.InstallationID != first.InstallationID {
		t.Errorf("перепрошивка сменила идентификатор машины: было %q, стало %q",
			first.InstallationID, record.InstallationID)
	}
	if record.Kind != model.KindReflash {
		t.Errorf("вид ключа %q, ожидался «reflash»", record.Kind)
	}

	// Тот же ключ без привязки считает другой адрес — там пусто. Ради этого
	// привязка и вынесена в вывод адреса: не та машина ничего не сжигает.
	free, err := activation.Bind(key, "")
	if err != nil {
		t.Fatalf("Bind: %v", err)
	}
	if _, ok := pub.objects[free.ObjectKey()]; ok {
		t.Error("пакет перепрошивки лежит по адресу без привязки")
	}

	bound, err := activation.Bind(key, activation.Binding(first.InstallationID))
	if err != nil {
		t.Fatalf("Bind: %v", err)
	}
	if _, ok := pub.objects[bound.ObjectKey()]; !ok {
		t.Fatal("пакета перепрошивки нет по адресу с привязкой")
	}
}

// Перепрошивать нечего там, где активацию ещё не забрали: сотруднику проще
// ввести уже выданный ключ, чем получить второй.
func TestReflashNeedsActivatedMachine(t *testing.T) {
	issuer, _, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	_, first, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	if _, _, err := issuer.Reflash(ctx, nil, first.InstallationID, ""); err == nil {
		t.Fatal("перепрошивка прошла на машине, которая ещё не активировалась")
	}
}

// Без пароля предустановки ключ не выпускается: машина активировалась бы, а
// «Управление» на ней потом не открылось бы ничем.
func TestIssueNeedsPresetPassword(t *testing.T) {
	issuer, _, db := newIssuer(t)
	ctx := context.Background()

	preset, err := db.CreatePreset(ctx, nil, "Без пароля")
	if err != nil {
		t.Fatalf("CreatePreset: %v", err)
	}
	if _, err := db.SaveRevision(ctx, nil, preset.ID, 2, json.RawMessage(`{}`), ""); err != nil {
		t.Fatalf("SaveRevision: %v", err)
	}
	employee, err := db.CreateEmployee(ctx, nil, model.Employee{
		Name: "Пётр", Number: "172", SIPPassword: "секрет", PresetID: &preset.ID,
	})
	if err != nil {
		t.Fatalf("CreateEmployee: %v", err)
	}

	if _, _, err := issuer.Issue(ctx, nil, employee.ID, ""); err == nil {
		t.Fatal("ключ выпустился по предустановке без административного пароля")
	}
}

// Помашинные объекты выкладываются вместе с пакетом: без записи о ключе
// доступа машина не смогла бы забрать ни предустановки, ни свой пароль.
func TestIssueWritesMachineObjects(t *testing.T) {
	issuer, pub, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	_, record, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	if _, ok := pub.objects[machinePrefix+record.InstallationID]; !ok {
		t.Error("нет записи machines/ — Worker не пустит машину к предустановкам")
	}
	access, ok := pub.objects[accessPrefix+record.InstallationID]
	if !ok {
		t.Fatal("нет объекта access/ — машине неоткуда взять административный пароль")
	}
	if !bytes.Contains(access, []byte("signature")) {
		t.Error("объект доступа не подписан")
	}
}
