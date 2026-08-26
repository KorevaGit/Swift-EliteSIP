// Package storage — база панели и всё, что с ней связано.
package storage

import (
	"database/sql"
	_ "embed"
	"fmt"

	_ "modernc.org/sqlite"
)

//go:embed schema.sql
var schemaSQL string

//go:embed migrate2.sql
var migrateToTwoSQL string

//go:embed migrate3.sql
var migrateToThreeSQL string

//go:embed migrate4.sql
var migrateToFourSQL string

// schemaVersion — версия схемы базы. Растёт с каждой миграцией.
const schemaVersion = 4

// DB — база панели.
type DB struct {
	*sql.DB
}

// Open открывает базу и доводит её схему до текущей версии.
//
// Драйвер — modernc.org/sqlite, то есть чистый Go без cgo: бинарник остаётся
// одним статически слинкованным файлом, который кладут на сервер и запускают.
func Open(path string) (*DB, error) {
	// _time_format=sqlite не ставим намеренно: времена пишутся строками RFC 3339
	// нами самими, а не драйвером, — см. комментарий в schema.sql.
	dsn := path + "?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("открыть базу %s: %w", path, err)
	}
	// SQLite не любит нескольких писателей: WAL их допускает, но занятость
	// всё равно выливается в SQLITE_BUSY под нагрузкой. Панель — не то место,
	// где нужна параллельность записи, поэтому писатель ровно один.
	db.SetMaxOpenConns(1)

	if err := migrate(db); err != nil {
		db.Close()
		return nil, err
	}
	return &DB{db}, nil
}

// migrate доводит схему до schemaVersion.
//
// Версия хранится в PRAGMA user_version, а не в своей таблице: таблицу пришлось
// бы заводить до первой миграции, то есть держать нулевую миграцию ради самого
// механизма миграций.
func migrate(db *sql.DB) error {
	var version int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return fmt.Errorf("прочитать версию схемы: %w", err)
	}

	if version > schemaVersion {
		// Откат бинарника на старый рядом с новой базой. Молча работать
		// дальше нельзя: старый код не знает, что изменилось в схеме, и
		// испортит данные тише, чем отказ запуститься.
		return fmt.Errorf(
			"база собрана схемой %d, а эта сборка знает только %d — нужна версия панели новее",
			version, schemaVersion,
		)
	}
	if version == schemaVersion {
		return nil
	}

	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("начать миграцию: %w", err)
	}
	defer tx.Rollback()

	// Переводы идут подряд, а не по одному: база на сервере конторы могла
	// отстать сразу на две версии, и «иначе если» тихо перевело бы её только
	// на одну — с записанным номером последней.
	if version < 1 {
		if _, err := tx.Exec(schemaSQL); err != nil {
			return fmt.Errorf("создать схему: %w", err)
		}
	} else {
		// Свежая база получает всё это сразу из schema.sql; сюда попадает
		// только та, что уже живёт на сервере конторы.
		if version < 2 {
			if _, err := tx.Exec(migrateToTwoSQL); err != nil {
				return fmt.Errorf("перевести схему на вторую версию: %w", err)
			}
		}
		if version < 3 {
			if _, err := tx.Exec(migrateToThreeSQL); err != nil {
				return fmt.Errorf("перевести схему на третью версию: %w", err)
			}
		}
		if version < 4 {
			if _, err := tx.Exec(migrateToFourSQL); err != nil {
				return fmt.Errorf("перевести схему на четвёртую версию: %w", err)
			}
		}
	}

	// PRAGMA не принимает параметров, поэтому число подставляется в текст.
	// Оно константа этого пакета, а не ввод снаружи.
	if _, err := tx.Exec(fmt.Sprintf("PRAGMA user_version = %d", schemaVersion)); err != nil {
		return fmt.Errorf("записать версию схемы: %w", err)
	}
	return tx.Commit()
}
