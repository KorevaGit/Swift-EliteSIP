// Package sand — данные и правила раздела «Песочница».
package sand

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

// schemaVersion растёт независимо от версии основной базы: файлы раздельны и
// могут обновляться разными этапами панели.
const schemaVersion = 2

// DB — отдельная база песочницы.
type DB struct {
	*sql.DB
}

// Open открывает sand.db и доводит его схему до версии этой сборки.
func Open(path string) (*DB, error) {
	dsn := path + "?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("открыть базу песочницы %s: %w", path, err)
	}
	db.SetMaxOpenConns(1)

	if err := migrate(db); err != nil {
		db.Close()
		return nil, err
	}
	return &DB{db}, nil
}

func migrate(db *sql.DB) error {
	var version int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return fmt.Errorf("прочитать версию схемы песочницы: %w", err)
	}
	if version > schemaVersion {
		return fmt.Errorf(
			"база песочницы собрана схемой %d, а эта сборка знает только %d — нужна версия панели новее",
			version, schemaVersion)
	}
	if version == schemaVersion {
		return nil
	}

	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("начать миграцию базы песочницы: %w", err)
	}
	defer tx.Rollback()

	if version < 1 {
		if _, err := tx.Exec(schemaSQL); err != nil {
			return fmt.Errorf("создать схему песочницы: %w", err)
		}
	} else if version < 2 {
		if _, err := tx.Exec(migrateToTwoSQL); err != nil {
			return fmt.Errorf("перевести схему песочницы на вторую версию: %w", err)
		}
	}
	if _, err := tx.Exec(fmt.Sprintf("PRAGMA user_version = %d", schemaVersion)); err != nil {
		return fmt.Errorf("записать версию схемы песочницы: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("закончить миграцию базы песочницы: %w", err)
	}
	return nil
}
