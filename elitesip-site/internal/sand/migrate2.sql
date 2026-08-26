-- Вторая версия схемы: надёжная доставка событий в общий журнал панели.

CREATE TABLE audit_outbox (
    event_id      TEXT PRIMARY KEY,
    at            TEXT    NOT NULL,
    actor_id      INTEGER,
    actor_login   TEXT    NOT NULL DEFAULT '',
    action        TEXT    NOT NULL,
    entity        TEXT    NOT NULL DEFAULT '',
    entity_id     INTEGER,
    details       TEXT    NOT NULL DEFAULT '',
    delivered_at TEXT
);

CREATE INDEX audit_outbox_pending
    ON audit_outbox(delivered_at, at);
