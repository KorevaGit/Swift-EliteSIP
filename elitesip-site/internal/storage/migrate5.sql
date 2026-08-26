-- Пятая версия схемы: идемпотентный приём событий из базы песочницы.

ALTER TABLE audit_log ADD COLUMN external_event_id TEXT;

CREATE UNIQUE INDEX audit_external_event
    ON audit_log(external_event_id) WHERE external_event_id IS NOT NULL;
