-- Схема песочницы.
--
-- База отдельна от основной панели намеренно: у песочницы свой срок хранения
-- и свой цикл миграций. Идентификаторы пользователей панели здесь поэтому не
-- внешние ключи — таблица admins живёт в другом файле SQLite.

PRAGMA foreign_keys = ON;

CREATE TABLE sandboxes (
    id         INTEGER PRIMARY KEY,
    rop        TEXT NOT NULL,
    format     TEXT NOT NULL CHECK (format IN ('office', 'remote')),
    created_at TEXT NOT NULL,
    closed_at  TEXT,
    closed_by  INTEGER
);

CREATE UNIQUE INDEX sandboxes_one_active_rop
    ON sandboxes(rop) WHERE closed_at IS NULL;

CREATE TABLE sandbox_marks (
    sandbox_id INTEGER NOT NULL REFERENCES sandboxes(id) ON DELETE CASCADE,
    task       TEXT    NOT NULL,
    done_at    TEXT    NOT NULL,
    done_by    INTEGER NOT NULL,
    done_login TEXT    NOT NULL,
    PRIMARY KEY (sandbox_id, task)
);

CREATE TABLE sand_employees (
    id           INTEGER PRIMARY KEY,
    sandbox_id   INTEGER NOT NULL REFERENCES sandboxes(id) ON DELETE CASCADE,
    name         TEXT    NOT NULL,
    bitrix_login TEXT,
    bitrix_pass  TEXT,
    bitrix_id    TEXT,
    outcome      TEXT CHECK (outcome IS NULL OR outcome IN ('hired', 'rejected')),
    outcome_at   TEXT,
    purged_at    TEXT
);

CREATE UNIQUE INDEX sand_employees_one_bitrix_id
    ON sand_employees(bitrix_id) WHERE bitrix_id IS NOT NULL AND bitrix_id <> '';

CREATE TABLE employee_marks (
    employee_id INTEGER NOT NULL REFERENCES sand_employees(id) ON DELETE CASCADE,
    task        TEXT    NOT NULL,
    done_at     TEXT    NOT NULL,
    done_by     INTEGER NOT NULL,
    done_login  TEXT    NOT NULL,
    PRIMARY KEY (employee_id, task)
);

CREATE TABLE sandbox_extensions (
    sandbox_id  INTEGER NOT NULL REFERENCES sandboxes(id) ON DELETE CASCADE,
    number      TEXT    NOT NULL,
    employee_id INTEGER REFERENCES sand_employees(id) ON DELETE SET NULL,
    released_at TEXT,
    PRIMARY KEY (sandbox_id, number)
);

-- У человека один добавочный, а незакрытый добавочный не может одновременно
-- лежать в пулах двух активных песков. released_at освобождает номер, не
-- стирая его прежнюю привязку из истории.
CREATE UNIQUE INDEX sandbox_extensions_one_per_employee
    ON sandbox_extensions(employee_id) WHERE employee_id IS NOT NULL;
CREATE UNIQUE INDEX sandbox_extensions_one_active_number
    ON sandbox_extensions(number) WHERE released_at IS NULL;

CREATE TABLE deal_batches (
    id             INTEGER PRIMARY KEY,
    sandbox_id     INTEGER NOT NULL REFERENCES sandboxes(id) ON DELETE CASCADE,
    employee_id    INTEGER NOT NULL REFERENCES sand_employees(id) ON DELETE CASCADE,
    size           INTEGER NOT NULL CHECK (size > 0),
    created_at     TEXT    NOT NULL,
    imported_at    TEXT,
    imported_by    INTEGER,
    imported_login TEXT    NOT NULL DEFAULT ''
);

CREATE TABLE sandbox_deals (
    sandbox_id  INTEGER NOT NULL REFERENCES sandboxes(id) ON DELETE CASCADE,
    deal_id     TEXT    NOT NULL,
    employee_id INTEGER REFERENCES sand_employees(id) ON DELETE SET NULL,
    batch_id    INTEGER REFERENCES deal_batches(id) ON DELETE SET NULL,
    given_at    TEXT,
    PRIMARY KEY (sandbox_id, deal_id)
);

CREATE INDEX sandbox_deals_available
    ON sandbox_deals(sandbox_id, employee_id, deal_id);
CREATE INDEX sandbox_deals_by_batch ON sandbox_deals(batch_id);

CREATE TABLE sandbox_comments (
    id           INTEGER PRIMARY KEY,
    sandbox_id   INTEGER NOT NULL REFERENCES sandboxes(id) ON DELETE CASCADE,
    author_id    INTEGER NOT NULL,
    author_login TEXT    NOT NULL,
    created_at   TEXT    NOT NULL,
    text         TEXT    NOT NULL
);

CREATE INDEX sandbox_comments_by_sandbox
    ON sandbox_comments(sandbox_id, created_at);

-- Действие и эта строка фиксируются одной транзакцией. Поэтому падение между
-- двумя файлами баз не теряет журнал: недоставленная строка останется здесь и
-- уйдёт в основную базу после следующего запуска или прохода доставщика.
CREATE TABLE audit_outbox (
    event_id    TEXT PRIMARY KEY,
    at          TEXT    NOT NULL,
    actor_id    INTEGER,
    actor_login TEXT    NOT NULL DEFAULT '',
    action      TEXT    NOT NULL,
    entity      TEXT    NOT NULL DEFAULT '',
    entity_id   INTEGER,
    details     TEXT    NOT NULL DEFAULT '',
    delivered_at TEXT
);

CREATE INDEX audit_outbox_pending
    ON audit_outbox(delivered_at, at);
