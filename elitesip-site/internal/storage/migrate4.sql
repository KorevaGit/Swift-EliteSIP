-- Четвёртая версия схемы: журнал называет человека по имени и чистится.
--
-- Свежая база получает это прямо из schema.sql. Здесь — только перевод той,
-- что уже живёт на сервере конторы.

-- Логин пишется в саму строку журнала, а не подтягивается связкой: иначе
-- удаление пользователя панели делает всю его историю безымянной — ровно то,
-- ради чего журнал и заведён.
ALTER TABLE audit_log ADD COLUMN actor_login TEXT NOT NULL DEFAULT '';

-- Прошлым строкам имя можно восстановить: те, кого ещё не гасили, в базе есть.
UPDATE audit_log
   SET actor_login = COALESCE((SELECT login FROM admins WHERE admins.id = audit_log.admin_id), '')
 WHERE admin_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS audit_by_time ON audit_log(at);
