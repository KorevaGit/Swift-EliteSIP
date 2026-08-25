-- Вторая версия схемы: разбор 25 августа 2026, авторизация по ключу.
--
-- Свежая база получает всё это прямо из schema.sql. Здесь — только перевод
-- той, что уже живёт на сервере конторы.

-- --------------------------------------------------------------------------
-- Административный пароль переезжает из настроек конторы в предустановку
-- --------------------------------------------------------------------------

ALTER TABLE presets ADD COLUMN admin_password TEXT NOT NULL DEFAULT '';

-- Прежний общий пароль раскладывается по всем предустановкам. Иначе перевод
-- схемы тихо обнулил бы пароль на всех рабочих местах разом: пакет с пустым
-- паролем активируется, но «Управление» на такой машине потом не открывается
-- ничем.
UPDATE presets
   SET admin_password = COALESCE((SELECT value FROM settings WHERE key = 'admin_password'), '');

-- --------------------------------------------------------------------------
-- Активации: идентификатор машины перестаёт быть уникальным
-- --------------------------------------------------------------------------

-- Перепрошивка сохраняет installation_id, то есть у одной машины появляется
-- несколько строк. UNIQUE на столбце это запрещал, а снять ограничение в
-- SQLite можно только пересборкой таблицы.
CREATE TABLE activations_v2 (
    id               INTEGER PRIMARY KEY,
    employee_id      INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    preset_id        INTEGER NOT NULL REFERENCES presets(id),
    kind             TEXT    NOT NULL DEFAULT 'activation',
    key_hash         TEXT    NOT NULL UNIQUE,
    key_prefix       TEXT    NOT NULL,
    object_key       TEXT    NOT NULL UNIQUE,
    installation_id  TEXT    NOT NULL,
    channel_key_hash TEXT    NOT NULL DEFAULT '',
    issued_by        INTEGER REFERENCES admins(id),
    issued_at        TEXT    NOT NULL,
    expires_at       TEXT    NOT NULL,
    fetched_at       TEXT,
    revoked_at       TEXT,
    superseded_at    TEXT,
    superseded_by    INTEGER REFERENCES activations_v2(id),
    package_removed_at TEXT,
    note             TEXT    NOT NULL DEFAULT ''
);

INSERT INTO activations_v2
      (id, employee_id, preset_id, key_hash, key_prefix, object_key,
       installation_id, issued_by, issued_at, expires_at, fetched_at,
       revoked_at, note)
SELECT id, employee_id, preset_id, key_hash, key_prefix, object_key,
       installation_id, issued_by, issued_at, expires_at, fetched_at,
       revoked_at, note
  FROM activations;

DROP TABLE activations;
ALTER TABLE activations_v2 RENAME TO activations;

CREATE INDEX activations_by_employee ON activations(employee_id);
CREATE INDEX activations_by_installation ON activations(installation_id);

-- --------------------------------------------------------------------------
-- Отметки машин теряют внешний ключ
-- --------------------------------------------------------------------------

-- Он ссылался на activations(installation_id), а тот перестал быть уникальным.
-- Ссылка на неуникальный столбец в SQLite не работает вовсе — запрос падает с
-- «foreign key mismatch» при первом же удалении сотрудника.
CREATE TABLE checkins_v2 (
    installation_id TEXT    PRIMARY KEY,
    last_seen_at    TEXT    NOT NULL,
    app_version     TEXT    NOT NULL DEFAULT '',
    schema_version  INTEGER,
    preset_revision INTEGER
);

INSERT INTO checkins_v2 SELECT * FROM checkins;
DROP TABLE checkins;
ALTER TABLE checkins_v2 RENAME TO checkins;
