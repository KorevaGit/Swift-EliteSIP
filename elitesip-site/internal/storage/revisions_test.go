package storage

import (
	"context"
	"errors"
	"testing"
)

// Список ревизий нужен ради отката, и в нём должно быть видно, кто и когда:
// администраторы равны, и «кто поменял» отвечает только запись.
func TestListRevisionsNewestFirstWithAuthor(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	admin, err := db.CreateAdmin(ctx, nil, "eugene", "хеш")
	if err != nil {
		t.Fatalf("CreateAdmin: %v", err)
	}
	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, &admin.ID, preset.ID, 2, []byte(`{}`), "первая")
	db.SaveRevision(ctx, nil, preset.ID, 2, []byte(`{}`), "вторая, из командной строки")

	list, err := db.ListRevisions(ctx, preset.ID)
	if err != nil {
		t.Fatalf("ListRevisions: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("ревизий %d, ожидалось 2", len(list))
	}
	if list[0].Revision != 2 {
		t.Errorf("первой идёт ревизия %d, ожидалась свежая", list[0].Revision)
	}
	if list[0].AuthorLogin != "" {
		t.Errorf("у ревизии без автора он вдруг нашёлся: %q", list[0].AuthorLogin)
	}
	if list[1].AuthorLogin != "eugene" {
		t.Errorf("автор %q, ожидался eugene", list[1].AuthorLogin)
	}
}

// Сравнивать надо с тем, что сейчас на машинах, а не с предыдущей сохранённой:
// между ними бывает несколько заходов подряд.
func TestLastPublishedRevisionSkipsUnpublished(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	first, _ := db.SaveRevision(ctx, nil, preset.ID, 2, []byte(`{"conference":{"featureCode":"*3","roomExtension":"8000"}}`), "")
	if err := db.MarkPublished(ctx, nil, first.ID); err != nil {
		t.Fatalf("MarkPublished: %v", err)
	}
	db.SaveRevision(ctx, nil, preset.ID, 2, []byte(`{}`), "вторая")
	db.SaveRevision(ctx, nil, preset.ID, 2, []byte(`{}`), "третья")

	published, err := db.LastPublishedRevision(ctx, preset.ID)
	if err != nil {
		t.Fatalf("LastPublishedRevision: %v", err)
	}
	if published.Revision != 1 {
		t.Errorf("выложенной считается ревизия %d, ожидалась 1", published.Revision)
	}
}

func TestLastPublishedRevisionOnFreshPreset(t *testing.T) {
	db := openTemp(t)
	ctx := context.Background()

	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, preset.ID, 2, []byte(`{}`), "")

	_, err := db.LastPublishedRevision(ctx, preset.ID)
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("ошибка %v, ожидалась ErrNotFound — выкладок ещё не было", err)
	}
}
