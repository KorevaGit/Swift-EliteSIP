-- Таблица CEL в базе FreePBX.
--
-- FreePBX её не создаёт: он заводит только cdr. Схема взята из штатного
-- contrib/realtime Asterisk и повторяет набор колонок, который видно в боевых
-- дампах CEL (CNAM, CNUM, АНИ, AMA, расш, контекст, канал, польз. тип и так далее).

CREATE TABLE IF NOT EXISTS cel (
    id           INT(11)      NOT NULL AUTO_INCREMENT,
    eventtype    VARCHAR(30)  NOT NULL DEFAULT '',
    eventtime    DATETIME     NOT NULL DEFAULT '1970-01-02 00:00:00',
    cid_name     VARCHAR(80)  NOT NULL DEFAULT '',
    cid_num      VARCHAR(80)  NOT NULL DEFAULT '',
    cid_ani      VARCHAR(80)  NOT NULL DEFAULT '',
    cid_rdnis    VARCHAR(80)  NOT NULL DEFAULT '',
    cid_dnid     VARCHAR(80)  NOT NULL DEFAULT '',
    exten        VARCHAR(80)  NOT NULL DEFAULT '',
    context      VARCHAR(80)  NOT NULL DEFAULT '',
    channame     VARCHAR(80)  NOT NULL DEFAULT '',
    appname      VARCHAR(80)  NOT NULL DEFAULT '',
    appdata      VARCHAR(255) NOT NULL DEFAULT '',
    amaflags     INT(11)      NOT NULL DEFAULT 0,
    accountcode  VARCHAR(20)  NOT NULL DEFAULT '',
    peeraccount  VARCHAR(20)  NOT NULL DEFAULT '',
    uniqueid     VARCHAR(150) NOT NULL DEFAULT '',
    linkedid     VARCHAR(150) NOT NULL DEFAULT '',
    userfield    VARCHAR(255) NOT NULL DEFAULT '',
    peer         VARCHAR(80)  NOT NULL DEFAULT '',
    userdeftype  VARCHAR(255) NOT NULL DEFAULT '',
    eventextra   VARCHAR(255) NOT NULL DEFAULT '',
    PRIMARY KEY (id),
    -- Индексы по этим двум колонкам обязательны: именно по linkedid страница
    -- «Детализация связанных звонков» собирает все плечи одного звонка.
    KEY uniqueid_index (uniqueid),
    KEY linkedid_index (linkedid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
