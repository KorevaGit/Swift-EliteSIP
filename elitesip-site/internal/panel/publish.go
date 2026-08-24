package panel

import (
	"context"
	"crypto/ed25519"
	"fmt"
	"time"

	"github.com/koreva/elitesip-site/internal/preset"
	"github.com/koreva/elitesip-site/internal/storage"
)

// BundleObjectKey — под каким именем файл предустановок лежит в бакете.
//
// Имя постоянное: приложение зашивает его вместе с адресом канала, и менять
// его — то же самое, что менять адрес, только незаметнее.
const BundleObjectKey = "presets/current.json"

// BundlePublisher собирает файл предустановок, подписывает его и выкладывает.
type BundlePublisher struct {
	DB        *storage.DB
	Publisher Publisher

	// SigningKey — приватный ключ линии предустановок.
	//
	// Лежит на локальном сервере файлом рядом с базой, а не в ней: бэкап базы
	// не должен быть заодно связкой ключей. Решение подписывать на стороне
	// сайта принято 24 августа 2026 вместе с переездом панели внутрь сети —
	// разбор в docs/DECISIONS.md.
	SigningKey ed25519.PrivateKey

	Now func() time.Time
}

// Publish выкладывает текущее состояние всех предустановок.
//
// Выкладывается всё разом, а не одна изменённая: файл один, и собрать его
// частично нельзя. Заодно это чинит расхождение, если прошлая выкладка
// оборвалась на середине.
func (p *BundlePublisher) Publish(ctx context.Context, actor *int64) (preset.Bundle, error) {
	now := p.now()

	entries, err := p.DB.BundleEntries(ctx)
	if err != nil {
		return preset.Bundle{}, err
	}

	bundle := preset.Bundle{
		Format:      preset.BundleFormat,
		GeneratedAt: now.UTC().Truncate(time.Second),
		Presets:     make([]preset.Entry, 0, len(entries)),
	}
	for _, e := range entries {
		bundle.Presets = append(bundle.Presets, preset.Entry{
			ID:            e.PublicID,
			Name:          e.Name,
			Revision:      e.Revision,
			SchemaVersion: e.SchemaVersion,
			Fields:        e.Payload,
		})
	}

	signed, err := preset.Sign(bundle, p.SigningKey)
	if err != nil {
		return preset.Bundle{}, err
	}
	if err := p.Publisher.Put(ctx, BundleObjectKey, signed); err != nil {
		return preset.Bundle{}, fmt.Errorf("выложить файл предустановок: %w", err)
	}

	// Отметка ставится после выкладки, а не вместе с сохранением ревизии:
	// «сохранено» и «уехало» — разные состояния, и администратор должен видеть
	// разницу, иначе он считает уехавшим то, чего на машинах ещё нет.
	//
	// Ошибка отметки выкладку не отменяет: файл уже снаружи, и притвориться,
	// что его там нет, значит соврать в другую сторону.
	for _, e := range entries {
		if err := p.DB.MarkPublished(ctx, actor, e.RevisionID); err != nil && err != storage.ErrNotFound {
			return bundle, fmt.Errorf(
				"файл выложен, но отметка о ревизии %d не записана: %w", e.Revision, err)
		}
	}
	return bundle, nil
}

func (p *BundlePublisher) now() time.Time {
	if p.Now != nil {
		return p.Now()
	}
	return time.Now()
}
