package panel

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/publish"
	"github.com/koreva/elitesip-site/internal/storage"
)

// Приставки в бакете. Те же, что у Worker'а, — worker/worker.js.
const (
	packagePrefix = "activations/"
	takenPrefix   = "taken/"
	seenPrefix    = "seen/"
)

// Reader читает то, что Worker оставил в бакете.
//
// Интерфейс, а не сразу R2, по той же причине, что и Publisher: разбор отметок
// должен проверяться без бакета и работать на стенде, где выкладка идёт в
// каталог.
type Reader interface {
	List(ctx context.Context, prefix string) ([]string, error)
	Get(ctx context.Context, objectKey string) ([]byte, error)
}

// Store — бакет целиком: и кладём, и читаем.
//
// Один и тот же доступ на обе стороны: панель выкладывает файлы и она же
// разбирает отметки, которые Worker оставляет рядом с ними. Второй канал ради
// чтения означал бы второй секрет и второе место, где можно ошибиться.
type Store interface {
	Publisher
	Reader
}

// CollectInterval — как часто панель заходит за отметками.
//
// Впятеро чаще, чем машина опрашивает файл предустановок: реже — и «ключ
// забрали» появлялось бы в панели позже, чем сотрудник успевает позвонить и
// спросить, дошло ли. Чаще незачем: раньше машины отметка всё равно не
// появится.
const CollectInterval = 5 * time.Minute

// MarkCollector разбирает отметки Worker'а.
//
// Обратной связи от самого приложения нет и не будет: после активации оно к
// панели не ходит вовсе. Всё, что панель знает о живых рабочих местах, она
// узнаёт отсюда — из следов, которые Worker оставляет, раздавая файлы.
type MarkCollector struct {
	DB     *storage.DB
	Reader Reader
}

// Result — что дал один заход.
type Result struct {
	Fetched  int // пакетов отмечено забранными
	Checkins int // машин отметилось
	Unknown  int // машин, которых нет в базе
}

// Collect забирает отметки и раскладывает их по базе.
//
// Отказы отдельных отметок не роняют заход целиком: одна нечитаемая отметка не
// должна лишать панель сведений обо всех остальных машинах. Не разобранное
// останется лежать в бакете и разберётся на следующем заходе — или не
// разберётся никогда, и это тоже приемлемо: сведения тут вспомогательные, а не
// те, на которых что-то держится.
func (m *MarkCollector) Collect(ctx context.Context) (Result, error) {
	var result Result

	fetched, err := m.collectTaken(ctx)
	if err != nil {
		return result, err
	}
	result.Fetched = fetched

	checkins, unknown, err := m.collectSeen(ctx)
	if err != nil {
		return result, err
	}
	result.Checkins = checkins
	result.Unknown = unknown

	return result, nil
}

// collectTaken отмечает забранные пакеты.
//
// Читаются только отметки тех пакетов, которых панель ещё не считает
// забранными: отметка после того, как её поставили, не меняется, и перечитывать
// её при каждом заходе значит платить запросом в бакет за уже известное.
func (m *MarkCollector) collectTaken(ctx context.Context) (int, error) {
	pending, err := m.DB.PendingObjectKeys(ctx)
	if err != nil {
		return 0, err
	}
	if len(pending) == 0 {
		return 0, nil
	}

	keys, err := m.Reader.List(ctx, takenPrefix)
	if err != nil {
		return 0, err
	}

	count := 0
	for _, key := range keys {
		objectKey := packagePrefix + strings.TrimPrefix(key, takenPrefix)
		if !pending[objectKey] {
			continue
		}

		var mark struct {
			ObjectKey string `json:"object_key"`
			TakenAt   string `json:"taken_at"`
		}
		if err := m.read(ctx, key, &mark); err != nil {
			continue
		}

		at, err := time.Parse(time.RFC3339, mark.TakenAt)
		if err != nil {
			// Отметка есть, а время в ней нечитаемо. «Забрали» здесь важнее
			// «когда»: без отметки ключ так и висел бы невостребованным.
			at = time.Now()
		}
		if err := m.DB.MarkFetched(ctx, objectKey, at); err != nil {
			continue
		}
		count++
	}
	return count, nil
}

// collectSeen обновляет сведения о живых машинах.
func (m *MarkCollector) collectSeen(ctx context.Context) (int, int, error) {
	keys, err := m.Reader.List(ctx, seenPrefix)
	if err != nil {
		return 0, 0, err
	}

	known, err := m.DB.KnownCheckins(ctx)
	if err != nil {
		return 0, 0, err
	}

	var saved, unknown int
	for _, key := range keys {
		var mark struct {
			InstallationID string `json:"installation_id"`
			LastSeenAt     string `json:"last_seen_at"`
			AppVersion     string `json:"app_version"`
			SchemaVersion  *int   `json:"schema_version"`
			PresetRevision *int   `json:"preset_revision"`
		}
		if err := m.read(ctx, key, &mark); err != nil {
			continue
		}
		if mark.InstallationID == "" {
			continue
		}

		seenAt, err := time.Parse(time.RFC3339, mark.LastSeenAt)
		if err != nil {
			continue
		}
		// Отметка, которая не двигалась с прошлого захода, не переписывается:
		// тридцать машин раз в полчаса — это тысяча с лишним записей в день,
		// и все они об одном и том же.
		if was, ok := known[mark.InstallationID]; ok && !seenAt.After(was) {
			continue
		}

		checkin := model.Checkin{
			InstallationID: mark.InstallationID,
			LastSeenAt:     seenAt,
			AppVersion:     mark.AppVersion,
			SchemaVersion:  mark.SchemaVersion,
			PresetRevision: mark.PresetRevision,
		}
		landed, err := m.DB.SaveCheckin(ctx, checkin)
		if err != nil {
			continue
		}
		if !landed {
			// Идентификатора нет среди активаций — это машина удалённого
			// сотрудника. Считаем и идём дальше.
			unknown++
			continue
		}
		saved++
	}
	return saved, unknown, nil
}

func (m *MarkCollector) read(ctx context.Context, key string, into any) error {
	data, err := m.Reader.Get(ctx, key)
	if errors.Is(err, publish.ErrNoObject) {
		return err
	}
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, into); err != nil {
		return fmt.Errorf("разобрать отметку %s: %w", key, err)
	}
	return nil
}
