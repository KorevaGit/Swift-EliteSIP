package panel

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/koreva/elitesip-site/internal/publish"
)

// memoryStore — бакет целиком: кладём, читаем, перечисляем и уносим.
type memoryStore struct {
	objects map[string][]byte
}

func newStore() *memoryStore {
	return &memoryStore{objects: map[string][]byte{}}
}

func (m *memoryStore) Put(_ context.Context, key string, data []byte) error {
	m.objects[key] = data
	return nil
}

func (m *memoryStore) Get(_ context.Context, key string) ([]byte, error) {
	data, ok := m.objects[key]
	if !ok {
		return nil, publish.ErrNoObject
	}
	return data, nil
}

func (m *memoryStore) List(_ context.Context, prefix string) ([]string, error) {
	var out []string
	for key := range m.objects {
		if strings.HasPrefix(key, prefix) {
			out = append(out, key)
		}
	}
	sort.Strings(out)
	return out, nil
}

func (m *memoryStore) Delete(_ context.Context, key string) error {
	delete(m.objects, key)
	return nil
}

// Забранный пакет уносится вместе со своей отметкой: она уже разобрана
// панелью, иначе строка не считалась бы забранной.
func TestSweepRemovesFetchedPackageWithItsMark(t *testing.T) {
	issuer, _, db := newIssuer(t)
	store := newStore()
	issuer.Publisher = store
	issuer.Machines.Publisher = store

	ctx := context.Background()
	employeeID := seedReady(t, db)

	_, record, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	name := strings.TrimPrefix(record.ObjectKey, packagePrefix)
	store.objects[takenPrefix+name] = mark(t, time.Now(), true)

	if err := db.MarkFetched(ctx, record.ObjectKey, time.Now()); err != nil {
		t.Fatalf("MarkFetched: %v", err)
	}

	sweeper := &Sweeper{DB: db, Store: store}
	result, err := sweeper.Sweep(ctx)
	if err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	if result.Packages != 1 || result.Marks != 1 {
		t.Errorf("унесено пакетов %d, отметок %d — ожидалось по одному",
			result.Packages, result.Marks)
	}
	if _, ok := store.objects[record.ObjectKey]; ok {
		t.Error("забранный пакет остался в бакете")
	}
	if _, ok := store.objects[takenPrefix+name]; ok {
		t.Error("отметка забранного пакета осталась в бакете")
	}

	// Второй заход не должен ходить в бакет за тем же самым.
	again, err := sweeper.Sweep(ctx)
	if err != nil {
		t.Fatalf("повторный Sweep: %v", err)
	}
	if again.Packages != 0 {
		t.Errorf("повторный заход унёс ещё %d пакетов", again.Packages)
	}
}

// Просроченный пакет уносится, хотя его никто не забирал: пролежав, он
// превращается в ставку на то, что ключ никуда не утёк.
func TestSweepRemovesExpiredPackage(t *testing.T) {
	issuer, _, db := newIssuer(t)
	store := newStore()
	issuer.Publisher = store
	issuer.Machines.Publisher = store

	ctx := context.Background()
	employeeID := seedReady(t, db)

	_, record, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	// Заход через трое суток: ключ протух, забрать его уже нельзя.
	later := time.Now().Add(3 * 24 * time.Hour)
	sweeper := &Sweeper{DB: db, Store: store, Now: func() time.Time { return later }}
	if _, err := sweeper.Sweep(ctx); err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	if _, ok := store.objects[record.ObjectKey]; ok {
		t.Error("просроченный пакет остался в бакете")
	}
}

// Отметка без строки в базе — след промаха: опечатка в ключе, запрос по
// унесённому адресу. Уборка от базы до неё не дотянется, поэтому есть проход
// по сроку.
func TestSweepRemovesOrphanMarkAfterLifetime(t *testing.T) {
	_, _, db := newIssuer(t)
	store := newStore()
	ctx := context.Background()

	store.objects[takenPrefix+"deadbeef"] = mark(t, time.Now().Add(-3*24*time.Hour), false)
	store.objects[takenPrefix+"freshbee"] = mark(t, time.Now(), false)

	sweeper := &Sweeper{DB: db, Store: store}
	result, err := sweeper.Sweep(ctx)
	if err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	if result.Orphans != 1 {
		t.Errorf("вычищено осиротевших отметок %d, ожидалась одна", result.Orphans)
	}
	if _, ok := store.objects[takenPrefix+"deadbeef"]; ok {
		t.Error("старая осиротевшая отметка осталась")
	}
	if _, ok := store.objects[takenPrefix+"freshbee"]; !ok {
		t.Error("свежая отметка унесена — а ключ по ней мог быть введён минуту назад")
	}
}

// Главное правило прохода по сроку: отметка — это замок одноразовости, и снять
// её с лежащего пакета значит перезарядить ключ спустя недели после выдачи.
func TestSweepKeepsMarkWhilePackageIsAlive(t *testing.T) {
	_, _, db := newIssuer(t)
	store := newStore()
	ctx := context.Background()

	// Пакета нет в базе — например, панель восстановили из бэкапа, — но в
	// бакете он лежит. Отметка старая, и по сроку её положено бы снять.
	store.objects[packagePrefix+"deadbeef"] = []byte("пакет")
	store.objects[takenPrefix+"deadbeef"] = mark(t, time.Now().Add(-30*24*time.Hour), true)

	sweeper := &Sweeper{DB: db, Store: store}
	result, err := sweeper.Sweep(ctx)
	if err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	if result.Orphans != 0 {
		t.Error("отметка снята с лежащего пакета — ключ перезаряжен")
	}
	if _, ok := store.objects[takenPrefix+"deadbeef"]; !ok {
		t.Fatal("замок одноразовости унесён уборкой")
	}
}

func mark(t *testing.T, at time.Time, delivered bool) []byte {
	t.Helper()
	data, err := json.Marshal(map[string]any{
		"format":    2,
		"taken_at":  at.UTC().Format(time.RFC3339),
		"delivered": delivered,
	})
	if err != nil {
		t.Fatalf("собрать отметку: %v", err)
	}
	return data
}

// Отзыв — три шага, и порядок в них не безразличен: отметка, подписанный отзыв,
// обрубленный доступ. Обрубить доступ первым значило бы лишить машину
// возможности забрать сам отзыв.
func TestRevokeCutsAccessAndLeavesSignedRevocation(t *testing.T) {
	issuer, _, db := newIssuer(t)
	store := newStore()
	issuer.Publisher = store
	issuer.Machines.Publisher = store

	ctx := context.Background()
	employeeID := seedReady(t, db)

	_, record, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	if _, ok := store.objects[machinePrefix+record.InstallationID]; !ok {
		t.Fatal("после выпуска нет записи machines/")
	}

	revoker := &Revoker{DB: db, Machines: issuer.Machines, Deleter: store}
	if err := revoker.Revoke(ctx, nil, record.ID); err != nil {
		t.Fatalf("Revoke: %v", err)
	}

	if _, ok := store.objects[machinePrefix+record.InstallationID]; ok {
		t.Error("доступ машины не обрублен — она продолжит получать предустановки")
	}
	revoked, ok := store.objects[revokedPrefix+record.InstallationID]
	if !ok {
		t.Fatal("отзыв не выложен — машине неоткуда узнать, что её сбросили")
	}
	if !bytes.Contains(revoked, []byte("signature")) {
		t.Error("отзыв не подписан: сброс по неподписанному объекту стирал бы машины по ошибке")
	}
	if _, ok := store.objects[accessPrefix+record.InstallationID]; ok {
		t.Error("административный пароль остался лежать в бакете после отзыва")
	}

	list, err := db.ListActivations(ctx, employeeID)
	if err != nil {
		t.Fatalf("ListActivations: %v", err)
	}
	if len(list) != 1 || list[0].RevokedAt == nil {
		t.Error("в базе активация не отмечена отозванной")
	}
}

// Смена пароля предустановки обязана доехать до работающих машин: в общий файл
// предустановок блок доступа не входит, и доехать сам он не может ничем.
func TestAccessRepublishReachesLiveMachines(t *testing.T) {
	issuer, _, db := newIssuer(t)
	store := newStore()
	issuer.Publisher = store
	issuer.Machines.Publisher = store

	ctx := context.Background()
	employeeID := seedReady(t, db)

	_, record, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	if err := db.MarkFetched(ctx, record.ObjectKey, time.Now()); err != nil {
		t.Fatalf("MarkFetched: %v", err)
	}

	if err := db.SetPresetAdminPassword(ctx, nil, record.PresetID, "новый-пароль"); err != nil {
		t.Fatalf("SetPresetAdminPassword: %v", err)
	}

	publisher := &AccessPublisher{DB: db, Machines: issuer.Machines}
	done, err := publisher.Republish(ctx, record.PresetID)
	if err != nil {
		t.Fatalf("Republish: %v", err)
	}
	if done != 1 {
		t.Fatalf("переписано машин %d, ожидалась одна", done)
	}

	access, ok := store.objects[accessPrefix+record.InstallationID]
	if !ok {
		t.Fatal("объекта доступа нет")
	}
	if !bytes.Contains(access, []byte(base64.StdEncoding.EncodeToString([]byte("новый-пароль"))[:8])) {
		// Пароль лежит внутри base64-конверта, поэтому ищем по разобранному.
		var envelope struct{ Payload []byte }
		if err := json.Unmarshal(access, &envelope); err != nil {
			t.Fatalf("разобрать конверт: %v", err)
		}
		if !bytes.Contains(envelope.Payload, []byte("новый-пароль")) {
			t.Error("в объекте доступа лежит не новый пароль")
		}
	}
}

// Невостребованный ключ машиной ещё не стал: переписывать по нему доступ
// нечему, и в счёт он идти не должен.
func TestAccessRepublishSkipsUnfetched(t *testing.T) {
	issuer, _, db := newIssuer(t)
	store := newStore()
	issuer.Publisher = store
	issuer.Machines.Publisher = store

	ctx := context.Background()
	employeeID := seedReady(t, db)

	_, record, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	publisher := &AccessPublisher{DB: db, Machines: issuer.Machines}
	done, err := publisher.Republish(ctx, record.PresetID)
	if err != nil {
		t.Fatalf("Republish: %v", err)
	}
	if done != 0 {
		t.Errorf("переписано машин %d, ожидалось ноль: ключ ещё не забирали", done)
	}
}
