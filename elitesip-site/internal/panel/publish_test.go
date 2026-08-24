package panel

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/koreva/elitesip-site/internal/preset"
	"github.com/koreva/elitesip-site/internal/storage"
)

func newPublisher(t *testing.T) (*BundlePublisher, *memoryPublisher, *storage.DB, ed25519.PublicKey) {
	t.Helper()

	db, err := storage.Open(filepath.Join(t.TempDir(), "panel.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}

	sink := &memoryPublisher{}
	return &BundlePublisher{DB: db, Publisher: sink, SigningKey: priv}, sink, db, pub
}

func TestPublishSignsEverything(t *testing.T) {
	publisher, sink, db, pubKey := newPublisher(t)
	ctx := context.Background()

	manager, _ := db.CreatePreset(ctx, nil, "Менеджер")
	secretary, _ := db.CreatePreset(ctx, nil, "Секретарь")
	if _, err := db.SaveRevision(ctx, nil, manager.ID, preset.SchemaVersion,
		json.RawMessage(`{"conference":{"featureCode":"*3","roomExtension":"8000"}}`), ""); err != nil {
		t.Fatalf("SaveRevision: %v", err)
	}
	if _, err := db.SaveRevision(ctx, nil, secretary.ID, preset.SchemaVersion,
		json.RawMessage(`{"queues":{"queues":[]}}`), ""); err != nil {
		t.Fatalf("SaveRevision: %v", err)
	}

	if _, err := publisher.Publish(ctx, nil); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	data, ok := sink.objects[BundleObjectKey]
	if !ok {
		t.Fatalf("файла по адресу %q нет", BundleObjectKey)
	}
	bundle, err := preset.Verify(data, pubKey)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if len(bundle.Presets) != 2 {
		t.Fatalf("в файле %d предустановок, ожидалось 2", len(bundle.Presets))
	}
	if bundle.Presets[0].ID != manager.PublicID {
		t.Errorf("первая предустановка %q, ожидалась %q", bundle.Presets[0].ID, manager.PublicID)
	}
}

// Машина ищет себя по идентификатору, а не по имени: переименование не должно
// разрывать связь.
func TestRenameKeepsIdentity(t *testing.T) {
	publisher, sink, db, pubKey := newPublisher(t)
	ctx := context.Background()

	created, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, created.ID, preset.SchemaVersion, json.RawMessage(`{}`), "")
	if _, err := publisher.Publish(ctx, nil); err != nil {
		t.Fatalf("первая выкладка: %v", err)
	}

	if _, err := db.Exec(`UPDATE presets SET name = 'Менеджер (первая линия)' WHERE id = ?`, created.ID); err != nil {
		t.Fatalf("переименование: %v", err)
	}
	db.SaveRevision(ctx, nil, created.ID, preset.SchemaVersion, json.RawMessage(`{}`), "")
	if _, err := publisher.Publish(ctx, nil); err != nil {
		t.Fatalf("вторая выкладка: %v", err)
	}

	bundle, err := preset.Verify(sink.objects[BundleObjectKey], pubKey)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if bundle.Presets[0].ID != created.PublicID {
		t.Error("после переименования идентификатор изменился — машины перестанут себя находить")
	}
	if bundle.Presets[0].Name != "Менеджер (первая линия)" {
		t.Errorf("имя в файле %q", bundle.Presets[0].Name)
	}
}

// «Сохранено» и «уехало» — разные состояния, и разница видна.
func TestPublishMarksRevisions(t *testing.T) {
	publisher, _, db, _ := newPublisher(t)
	ctx := context.Background()

	created, _ := db.CreatePreset(ctx, nil, "Менеджер")
	revision, err := db.SaveRevision(ctx, nil, created.ID, preset.SchemaVersion, json.RawMessage(`{}`), "")
	if err != nil {
		t.Fatalf("SaveRevision: %v", err)
	}
	if revision.Published() {
		t.Fatal("свежесохранённая ревизия считается выложенной")
	}

	list, _ := db.ListPresets(ctx, false)
	if list[0].Published {
		t.Error("до выкладки предустановка показана выложенной")
	}

	if _, err := publisher.Publish(ctx, nil); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	stored, err := db.RevisionByID(ctx, revision.ID)
	if err != nil {
		t.Fatalf("RevisionByID: %v", err)
	}
	if !stored.Published() {
		t.Error("после выкладки ревизия не отмечена выложенной")
	}
}

// Предустановка без ревизий в файл не идёт: управлять ею нечем, а пустая
// запись заставила бы машину применить пустоту.
func TestPresetWithoutRevisionIsNotPublished(t *testing.T) {
	publisher, sink, db, pubKey := newPublisher(t)
	ctx := context.Background()

	db.CreatePreset(ctx, nil, "Пустая")
	filled, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, filled.ID, preset.SchemaVersion, json.RawMessage(`{}`), "")

	if _, err := publisher.Publish(ctx, nil); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	bundle, err := preset.Verify(sink.objects[BundleObjectKey], pubKey)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if len(bundle.Presets) != 1 || bundle.Presets[0].Name != "Менеджер" {
		t.Errorf("в файле %d записей: %+v", len(bundle.Presets), bundle.Presets)
	}
}

func TestPublishReportsBucketFailure(t *testing.T) {
	publisher, sink, db, _ := newPublisher(t)
	ctx := context.Background()

	created, _ := db.CreatePreset(ctx, nil, "Менеджер")
	revision, _ := db.SaveRevision(ctx, nil, created.ID, preset.SchemaVersion, json.RawMessage(`{}`), "")
	sink.fail = errors.New("бакет недоступен")

	if _, err := publisher.Publish(ctx, nil); err == nil {
		t.Fatal("выкладка удалась при недоступном бакете")
	}

	stored, _ := db.RevisionByID(ctx, revision.ID)
	if stored.Published() {
		t.Error("ревизия отмечена выложенной, хотя файл не уехал")
	}
}

func TestPublishStampsTime(t *testing.T) {
	publisher, sink, db, pubKey := newPublisher(t)
	ctx := context.Background()

	fixed := time.Date(2026, 8, 24, 15, 30, 0, 0, time.UTC)
	publisher.Now = func() time.Time { return fixed }

	created, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, created.ID, preset.SchemaVersion, json.RawMessage(`{}`), "")
	if _, err := publisher.Publish(ctx, nil); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	bundle, err := preset.Verify(sink.objects[BundleObjectKey], pubKey)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if !bundle.GeneratedAt.Equal(fixed) {
		t.Errorf("время сборки %s, ожидалось %s", bundle.GeneratedAt, fixed)
	}
}
