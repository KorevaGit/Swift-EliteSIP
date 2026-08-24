package storage

import (
	"database/sql"
	"fmt"
	"time"
)

// timeLayout — как времена лежат в базе.
//
// RFC 3339 в UTC с секундной точностью: так они сортируются как строки,
// читаются глазами в отладке и не зависят от того, в каком поясе стоит сервер.
// Долей секунды нет намеренно — ни одно решение панели на них не опирается, а
// в отладке они только мешают.
const timeLayout = "2006-01-02T15:04:05Z"

func formatTime(t time.Time) string {
	return t.UTC().Truncate(time.Second).Format(timeLayout)
}

func parseTime(s string) (time.Time, error) {
	t, err := time.Parse(timeLayout, s)
	if err != nil {
		return time.Time{}, fmt.Errorf("разобрать время %q: %w", s, err)
	}
	return t, nil
}

// nullTime готовит необязательное время к записи.
func nullTime(t *time.Time) any {
	if t == nil {
		return nil
	}
	return formatTime(*t)
}

// readTime разбирает обязательное время из строки базы.
func readTime(s string) time.Time {
	t, err := parseTime(s)
	if err != nil {
		// В базу пишем только через formatTime, поэтому сюда можно попасть лишь
		// правкой файла руками. Возвращаем нуль, а не паникуем: панель должна
		// показать испорченную строку, а не отказаться открывать список.
		return time.Time{}
	}
	return t
}

// readNullTime разбирает необязательное время.
func readNullTime(s sql.NullString) *time.Time {
	if !s.Valid || s.String == "" {
		return nil
	}
	t := readTime(s.String)
	return &t
}

func nullInt(v *int) any {
	if v == nil {
		return nil
	}
	return *v
}

func nullInt64(v *int64) any {
	if v == nil {
		return nil
	}
	return *v
}

func readNullInt64(v sql.NullInt64) *int64 {
	if !v.Valid {
		return nil
	}
	out := v.Int64
	return &out
}

func readNullInt(v sql.NullInt64) *int {
	if !v.Valid {
		return nil
	}
	out := int(v.Int64)
	return &out
}
