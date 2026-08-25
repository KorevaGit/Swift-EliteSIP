package panel

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/publish"
	"github.com/koreva/elitesip-site/internal/storage"
)

// bucket — бакет в памяти: и то, что кладёт панель, и то, что оставляет Worker.
type bucket struct{ objects map[string][]byte }

func newBucket() *bucket { return &bucket{objects: map[string][]byte{}} }

func (b *bucket) Put(_ context.Context, key string, data []byte) error {
	b.objects[key] = data
	return nil
}

func (b *bucket) Get(_ context.Context, key string) ([]byte, error) {
	data, ok := b.objects[key]
	if !ok {
		return nil, publish.ErrNoObject
	}
	return data, nil
}

func (b *bucket) List(_ context.Context, prefix string) ([]string, error) {
	var out []string
	for key := range b.objects {
		if strings.HasPrefix(key, prefix) {
			out = append(out, key)
		}
	}
	sort.Strings(out)
	return out, nil
}

// mark кладёт в бакет отметку, какую оставил бы Worker.
func (b *bucket) mark(t *testing.T, key string, value any) {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("собрать отметку: %v", err)
	}
	b.objects[key] = data
}

// Ключ, забранный машиной, перестаёт числиться невостребованным. Здесь и
// кончается одноразовость: второй раз Worker пакет не отдаёт, а панель об этом
// узнаёт из отметки.
func TestCollectMarksPackageFetched(t *testing.T) {
	issuer, pub, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	key, saved, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	store := newBucket()
	for k, v := range pub.objects {
		store.objects[k] = v
	}
	taken := time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
	store.mark(t, "taken/"+strings.TrimPrefix(saved.ObjectKey, "activations/"), map[string]any{
		"format":     1,
		"object_key": saved.ObjectKey,
		"taken_at":   taken.Format(time.RFC3339),
	})

	collector := &MarkCollector{DB: db, Reader: store}
	result, err := collector.Collect(ctx)
	if err != nil {
		t.Fatalf("Collect: %v", err)
	}
	if result.Fetched != 1 {
		t.Fatalf("отмечено забранными %d, ожидался 1", result.Fetched)
	}

	list, _ := db.ListActivations(ctx, employeeID)
	if list[0].FetchedAt == nil {
		t.Fatal("активация не отмечена забранной")
	}
	if !list[0].FetchedAt.Equal(taken) {
		t.Errorf("время %v, ожидалось %v", list[0].FetchedAt, taken)
	}
	if list[0].State(time.Now()) != model.ActivationDone {
		t.Errorf("состояние %q, ожидалось «активировано»", list[0].State(time.Now()))
	}
	_ = key
}

// Второй заход по тем же отметкам ничего не переделывает: разбор идёт при
// каждом опросе, и переписывать уже известное значит платить запросом в бакет
// за то, что не менялось.
func TestCollectIsIdempotent(t *testing.T) {
	issuer, pub, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	_, saved, _ := issuer.Issue(ctx, nil, employeeID, "")

	store := newBucket()
	for k, v := range pub.objects {
		store.objects[k] = v
	}
	store.mark(t, "taken/"+strings.TrimPrefix(saved.ObjectKey, "activations/"), map[string]any{
		"object_key": saved.ObjectKey,
		"taken_at":   time.Now().UTC().Format(time.RFC3339),
	})
	store.mark(t, "seen/"+saved.InstallationID, map[string]any{
		"installation_id": saved.InstallationID,
		"last_seen_at":    time.Now().UTC().Format(time.RFC3339),
		"app_version":     "0.1.25",
		"schema_version":  2,
		"preset_revision": 2,
	})

	collector := &MarkCollector{DB: db, Reader: store}
	first, err := collector.Collect(ctx)
	if err != nil {
		t.Fatalf("первый заход: %v", err)
	}
	if first.Fetched != 1 || first.Checkins != 1 {
		t.Fatalf("первый заход дал %+v", first)
	}

	second, err := collector.Collect(ctx)
	if err != nil {
		t.Fatalf("второй заход: %v", err)
	}
	if second.Fetched != 0 || second.Checkins != 0 {
		t.Errorf("второй заход переделал работу: %+v", second)
	}
}

// Отметка машины доносит версию приложения и ревизию предустановки — всё, что
// панель вообще может о ней узнать.
func TestCollectFillsCheckin(t *testing.T) {
	issuer, pub, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	_, saved, _ := issuer.Issue(ctx, nil, employeeID, "")

	store := newBucket()
	for k, v := range pub.objects {
		store.objects[k] = v
	}
	seen := time.Date(2026, 8, 24, 15, 30, 0, 0, time.UTC)
	store.mark(t, "seen/"+saved.InstallationID, map[string]any{
		"installation_id": saved.InstallationID,
		"last_seen_at":    seen.Format(time.RFC3339),
		"app_version":     "0.1.25",
		"schema_version":  2,
		"preset_revision": 7,
	})

	collector := &MarkCollector{DB: db, Reader: store}
	if _, err := collector.Collect(ctx); err != nil {
		t.Fatalf("Collect: %v", err)
	}

	machines, err := db.Machines(ctx, employeeID)
	if err != nil {
		t.Fatalf("Machines: %v", err)
	}
	if machines[0].Checkin == nil {
		t.Fatal("отметка не легла")
	}
	c := machines[0].Checkin
	if !c.LastSeenAt.Equal(seen) || c.AppVersion != "0.1.25" {
		t.Errorf("отметка вышла такая: %+v", c)
	}
	if c.SchemaVersion == nil || *c.SchemaVersion != 2 {
		t.Errorf("версия схемы %v", c.SchemaVersion)
	}
	if c.PresetRevision == nil || *c.PresetRevision != 7 {
		t.Errorf("ревизия %v", c.PresetRevision)
	}
}

// Машина удалённого сотрудника продолжает тянуть файл предустановок: она о
// людях ничего не знает, а файл лежит на R2. Её отметка пропускается молча.
func TestCollectIgnoresUnknownMachine(t *testing.T) {
	_, _, db := newIssuer(t)
	ctx := context.Background()

	store := newBucket()
	store.mark(t, "seen/призрак-удалённого", map[string]any{
		"installation_id": "призрак-удалённого",
		"last_seen_at":    time.Now().UTC().Format(time.RFC3339),
		"app_version":     "0.1.25",
	})

	collector := &MarkCollector{DB: db, Reader: store}
	result, err := collector.Collect(ctx)
	if err != nil {
		t.Fatalf("Collect: %v", err)
	}
	if result.Checkins != 0 {
		t.Errorf("отметок легло %d, ожидалось 0", result.Checkins)
	}
	if result.Unknown != 1 {
		t.Errorf("незнакомых машин %d, ожидалась 1", result.Unknown)
	}

	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM checkins`).Scan(&count); err != nil {
		t.Fatalf("checkins: %v", err)
	}
	if count != 0 {
		t.Errorf("чужая отметка попала в базу: строк %d", count)
	}
}

// Одна нечитаемая отметка не должна лишать панель сведений обо всех остальных
// машинах: сведения тут вспомогательные, а не те, на которых что-то держится.
func TestCollectSurvivesBrokenMark(t *testing.T) {
	issuer, pub, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)
	_, saved, _ := issuer.Issue(ctx, nil, employeeID, "")

	store := newBucket()
	for k, v := range pub.objects {
		store.objects[k] = v
	}
	store.objects["seen/битая"] = []byte("это не JSON")
	store.mark(t, "seen/"+saved.InstallationID, map[string]any{
		"installation_id": saved.InstallationID,
		"last_seen_at":    time.Now().UTC().Format(time.RFC3339),
	})

	collector := &MarkCollector{DB: db, Reader: store}
	result, err := collector.Collect(ctx)
	if err != nil {
		t.Fatalf("Collect споткнулся на битой отметке: %v", err)
	}
	if result.Checkins != 1 {
		t.Errorf("целая отметка не разобрана: %+v", result)
	}
}

// Отставшей считается машина, применившая не последнюю выложенную ревизию.
// Невыложенная ревизия отставшей никого не делает: её на машинах и не должно
// быть.
func TestBehindVersionCountsOnlyPublished(t *testing.T) {
	issuer, pub, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)
	_, saved, _ := issuer.Issue(ctx, nil, employeeID, "")

	store := newBucket()
	for k, v := range pub.objects {
		store.objects[k] = v
	}
	store.mark(t, "seen/"+saved.InstallationID, map[string]any{
		"installation_id": saved.InstallationID,
		"last_seen_at":    time.Now().UTC().Format(time.RFC3339),
		"preset_revision": 1,
	})
	collector := &MarkCollector{DB: db, Reader: store}
	if _, err := collector.Collect(ctx); err != nil {
		t.Fatalf("Collect: %v", err)
	}

	behind, err := db.BehindVersion(ctx)
	if err != nil {
		t.Fatalf("BehindVersion: %v", err)
	}
	if behind != 0 {
		t.Fatalf("отставших %d, а выкладок ещё не было", behind)
	}

	// Ревизия 1 существует и выложена — машина на ней, отставших нет.
	revision, _ := db.LatestRevision(ctx, presetOf(t, db))
	if err := db.MarkPublished(ctx, nil, revision.ID); err != nil {
		t.Fatalf("MarkPublished: %v", err)
	}
	if behind, _ = db.BehindVersion(ctx); behind != 0 {
		t.Errorf("машина на выложенной ревизии сочтена отставшей")
	}

	// Появилась вторая, тоже выложенная — вот теперь машина отстала.
	second, err := db.SaveRevision(ctx, nil, presetOf(t, db), 2, []byte(`{}`), "вторая")
	if err != nil {
		t.Fatalf("SaveRevision: %v", err)
	}
	if err := db.MarkPublished(ctx, nil, second.ID); err != nil {
		t.Fatalf("MarkPublished: %v", err)
	}
	if behind, _ = db.BehindVersion(ctx); behind != 1 {
		t.Errorf("отставших %d, ожидалась 1", behind)
	}
}

func presetOf(t *testing.T, db *storage.DB) int64 {
	t.Helper()
	list, err := db.ListPresets(context.Background(), false)
	if err != nil || len(list) == 0 {
		t.Fatalf("предустановки: %v", err)
	}
	return list[0].ID
}

// Отметка ставится до выдачи, значит бывает и там, где отдавать было нечего:
// просрочено, унесено уборкой, опечатка в ключе. Считать такую выдачей — значит
// показать опоздавшему сотруднику «активировано» на месте, которого он не
// поднимал.
func TestCollectIgnoresUndeliveredMark(t *testing.T) {
	issuer, pub, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	_, saved, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	store := newBucket()
	for k, v := range pub.objects {
		store.objects[k] = v
	}
	store.mark(t, "taken/"+strings.TrimPrefix(saved.ObjectKey, "activations/"), map[string]any{
		"format":     2,
		"object_key": saved.ObjectKey,
		"taken_at":   time.Now().UTC().Format(time.RFC3339),
		"delivered":  false,
	})

	collector := &MarkCollector{DB: db, Reader: store}
	result, err := collector.Collect(ctx)
	if err != nil {
		t.Fatalf("Collect: %v", err)
	}
	if result.Fetched != 0 {
		t.Errorf("промах засчитан выдачей: отмечено %d", result.Fetched)
	}

	list, _ := db.ListActivations(ctx, employeeID)
	if list[0].FetchedAt != nil {
		t.Fatal("активация отмечена забранной по отметке о промахе")
	}
}

// Отметка старого образца — без поля вовсе — считается выдачей: иначе первый же
// разбор после обновления Worker'а потерял бы живые активации.
func TestCollectTreatsOldMarkAsDelivered(t *testing.T) {
	issuer, pub, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	_, saved, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	store := newBucket()
	for k, v := range pub.objects {
		store.objects[k] = v
	}
	store.mark(t, "taken/"+strings.TrimPrefix(saved.ObjectKey, "activations/"), map[string]any{
		"format":     1,
		"object_key": saved.ObjectKey,
		"taken_at":   time.Now().UTC().Format(time.RFC3339),
	})

	collector := &MarkCollector{DB: db, Reader: store}
	if _, err := collector.Collect(ctx); err != nil {
		t.Fatalf("Collect: %v", err)
	}
	list, _ := db.ListActivations(ctx, employeeID)
	if list[0].FetchedAt == nil {
		t.Error("отметка без поля delivered не засчитана выдачей")
	}
}

// Перепрошивка дожимается в момент, когда её пакет забрали: прежняя строка
// машины гасится, а в machines/ остаётся один ключ доступа.
func TestCollectSettlesReflash(t *testing.T) {
	issuer, pub, db := newIssuer(t)
	ctx := context.Background()
	employeeID := seedReady(t, db)

	_, first, err := issuer.Issue(ctx, nil, employeeID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	if err := db.MarkFetched(ctx, first.ObjectKey, time.Now()); err != nil {
		t.Fatalf("MarkFetched: %v", err)
	}

	_, second, err := issuer.Reflash(ctx, nil, first.InstallationID, "сменил отдел")
	if err != nil {
		t.Fatalf("Reflash: %v", err)
	}

	store := newBucket()
	for k, v := range pub.objects {
		store.objects[k] = v
	}
	// До ввода ключа действуют оба доступа: машина работает на старой
	// предустановке и обязана получать её правки.
	var record struct {
		Keys []ChannelKeyGrant `json:"keys"`
	}
	if err := json.Unmarshal(store.objects[machinePrefix+first.InstallationID], &record); err != nil {
		t.Fatalf("разобрать machines/: %v", err)
	}
	if len(record.Keys) != 2 {
		t.Fatalf("действующих ключей доступа %d, ожидалось два", len(record.Keys))
	}

	store.mark(t, "taken/"+strings.TrimPrefix(second.ObjectKey, "activations/"), map[string]any{
		"format":     2,
		"object_key": second.ObjectKey,
		"taken_at":   time.Now().UTC().Format(time.RFC3339),
		"delivered":  true,
	})

	collector := &MarkCollector{
		DB:       db,
		Reader:   store,
		Machines: &MachineWriter{Publisher: store, SigningKey: issuer.Machines.SigningKey},
	}
	if _, err := collector.Collect(ctx); err != nil {
		t.Fatalf("Collect: %v", err)
	}

	list, _ := db.ListActivations(ctx, employeeID)
	for _, a := range list {
		switch a.ID {
		case first.ID:
			if a.SupersededAt == nil {
				t.Error("прежняя строка машины не погашена — машина будет двоиться в списке")
			}
			if a.State(time.Now()) != model.ActivationReflashed {
				t.Errorf("состояние прежней строки %q, ожидалось «перепрошита»", a.State(time.Now()))
			}
		case second.ID:
			if a.SupersededAt != nil {
				t.Error("погашена новая строка вместо прежней")
			}
		}
	}

	if err := json.Unmarshal(store.objects[machinePrefix+first.InstallationID], &record); err != nil {
		t.Fatalf("разобрать machines/: %v", err)
	}
	if len(record.Keys) != 1 {
		t.Errorf("после перепрошивки действующих ключей %d, ожидался один", len(record.Keys))
	}
}
