package publish

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
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
	if strings.Contains(objectKey, "..") {
		return fmt.Errorf("подозрительное имя объекта: %q", objectKey)
	}

	path := filepath.Join(d.Root, filepath.FromSlash(objectKey))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("создать каталог для %s: %w", objectKey, err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return fmt.Errorf("записать %s: %w", objectKey, err)
	}
	return nil
}
