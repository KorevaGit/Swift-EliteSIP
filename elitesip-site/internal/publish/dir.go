package publish

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Dir кладёт объекты в каталог на диске.
//
// Существует ради двух случаев: проверить выкладку целиком, не имея бакета, и
// поднять панель на стенде, где R2 не нужен вовсе. В бою не используется.
type Dir struct {
	Root string
}

// Put записывает объект файлом.
func (d Dir) Put(_ context.Context, objectKey string, data []byte) error {
	// Имя объекта приходит из кода панели, а не снаружи, но проверка стоит
	// дёшево, а стоимость ошибки — запись куда угодно на диске.
	path, err := d.path(objectKey)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("создать каталог для %s: %w", objectKey, err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return fmt.Errorf("записать %s: %w", objectKey, err)
	}
	return nil
}

// Get читает объект.
func (d Dir) Get(_ context.Context, objectKey string) ([]byte, error) {
	path, err := d.path(objectKey)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNoObject
	}
	if err != nil {
		return nil, fmt.Errorf("прочитать %s: %w", objectKey, err)
	}
	return data, nil
}

// List перечисляет объекты с этой приставкой.
//
// Порядок задан явно: файловая система его не обещает, а панель по этому
// перечню считает, что нового появилось с прошлого захода.
func (d Dir) List(_ context.Context, prefix string) ([]string, error) {
	var out []string

	err := filepath.WalkDir(d.Root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(d.Root, path)
		if err != nil {
			return err
		}
		key := filepath.ToSlash(rel)
		if strings.HasPrefix(key, prefix) {
			out = append(out, key)
		}
		return nil
	})
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("перечислить %s*: %w", prefix, err)
	}

	sort.Strings(out)
	return out, nil
}

func (d Dir) path(objectKey string) (string, error) {
	if strings.Contains(objectKey, "..") {
		return "", fmt.Errorf("подозрительное имя объекта: %q", objectKey)
	}
	return filepath.Join(d.Root, filepath.FromSlash(objectKey)), nil
}
