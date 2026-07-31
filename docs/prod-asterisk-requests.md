# Что ещё попросить у боевого Asterisk

## Готовая команда (CLI, `chan_sip`, безопасно — только чтение)

Одной командой на самом боевом сервере, без изменения конфигурации и без
перезагрузки модулей. `<НОМЕР>` — реальный агентский extension, под которым
фактически регистрируется рабочее место (не транк).

```bash
{
  echo "=== core show version ==="
  asterisk -rx "core show version"
  echo
  echo "=== sip show settings ==="
  asterisk -rx "sip show settings"
  echo
  echo "=== sip show peer <НОМЕР> ==="
  asterisk -rx "sip show peer <НОМЕР>"
  echo
  echo "=== rtp show settings ==="
  asterisk -rx "rtp show settings"
  echo
  echo "=== features show ==="
  asterisk -rx "features show"
  echo
  echo "=== core show codecs audio ==="
  asterisk -rx "core show codecs audio"
} > elitesip-compat-report.txt 2>&1
```

Секрет пира команда не печатает (`sip show peer` показывает `Secret : <Set>`,
не значение), поэтому файл можно присылать как есть. Дальше по каждому блоку —
что он закрывает и куда идёт ответ.



Список конкретных команд и файлов для администратора боевого сервера. Не
общие пожелания «пришлите конфиг», а то, что реально закрывает конкретные
открытые вопросы из [ROADMAP.md](ROADMAP.md#нужны-ответы) и других документов.

**31 июля 2026 закрыты пункты 2–4** — пришли реальные `sip show settings`,
`sip show peer` (на живом зарегистрированном тестовом пире) и
`rtp show settings`. Настройки перенесены в лабораторный конфиг
([sip.conf](../Lab/asterisk/config/sip.conf),
[rtp.conf](../Lab/asterisk/config/rtp.conf)) без боевых IP, номера и имени —
только сами параметры, по принципу конфиденциальности из
[ROADMAP.md](ROADMAP.md#конфиденциальность-конфигурации). Пункт 1 (сам
диалплан) остаётся открытым.

## 1. Диалплан и фич-коды — то, чего `core show features` не показывает

`core show features` печатает только код и имя фичи, а не тело
`[applicationmap]`/диалплана за ней. Нужны сами файлы:

```
features.conf
extensions_custom.conf
```

Закрывает: боевой код конференции (сейчас непроверенная догадка `*3`, см.
[conference.md](conference.md)); что именно делает `apprecord` (*1) —
**частично прояснилось**: боевой `sip show peer` показал, что у тестового
пира `Record On/Off feature` — это как раз `apprecord`, то есть код `*1`
переключает штатную боевую запись разговора через
`recordonfeature`/`recordofffeature`, а не какая-то экзотика; но само тело
фичи в `[applicationmap]` (что именно она выполняет — `MixMonitor` напрямую
или что-то ещё) по-прежнему не видно. `cancel-transfer` (*77) остаётся
неизвестным полностью; исходный смысл `*022998#`, который раньше приняли за
`blindxfer`, не подтвердился (реальный `blindxfer` — `##`).

## 2. ~~Общие параметры `chan_sip` — транспорт и таймауты~~ — отвечено

```
sip show settings
```

Пришло 31 июля 2026. Главные находки:

- транспорт — обычный UDP, TLS выключен целиком (`TLS SIP Bindaddress:
  Disabled`) — закрывает M1/M2b: TLS/SRTP не боевой, а поддерживаемый профиль
  на будущее;
- `dtmfmode=rfc2833` — подтвердилось, как и предполагалось для M4;
- Session-Timers: `Accept`, refresher `uas`, `Session-Expires: 1800`,
  `Min-SE: 90` — RFC 4028 на бою есть, режим не обязывающий;
- порядок кодеков в `[general]` — `(ulaw|alaw|gsm|g726|g722)`, **не** G.722
  первым, как предполагалось для M2. Разбор — [audio.md](audio.md#g722).

## 3. ~~Настройки конкретного боевого extension~~ — отвечено

```
sip show peer <номер>
```

Пришло на реальном зарегистрированном тестовом пире 31 июля 2026:

- `Encryption: No` — TLS/SRTP на этом рабочем месте не используется,
  согласуется с `sip show settings`;
- `Force rport: Yes`, `Symmetric RTP: Yes` — современные имена того же, что в
  лабе уже стояло как `nat=force_rport,comedia`; совпало, менять не пришлось;
- `Record On/Off feature: apprecord` — см. пункт 1;
- `SIP Options: replaces` — сервер объявляет поддержку `Replaces`,
  подтверждает подход M5 (REFER с Replaces для консультационного перевода);
- `context` конкретного extension получен, но связь с `from-auto-dialer`
  всё ещё требует самого диалплана (пункт 1).

## 4. ~~RTP и NAT-траversal~~ — отвечено

```
rtp show settings
```

Пришло 31 июля 2026: `Strict RTP: Yes`, `ICE support: Yes`, диапазон портов
шире лабораторного (у нас меньше — так и задумано, ограничение публикации
портов в Docker, не совместимости). `strictrtp` перенесён в
[rtp.conf](../Lab/asterisk/config/rtp.conf); `icesupport` — нет: лабораторный
Asterisk собран без pjproject/pjnath, и `rtp show settings` после включения
параметра просто не печатает строку ICE support вообще — проверено на живом
контейнере. Если ICE понадобится для проверки удалённого профиля (M2b), сборку
придётся менять, а не только конфиг.

## 5. Не Asterisk, а инфраструктура — но напрямую блокирует M2b/M7

- Проходит ли удалённый профиль через L2TP VPN на уровне сети, а не только
  делает ли скрипт подключения исходящие пакеты для открытия NAT — это два
  разных вопроса, и сейчас проверен только второй.
- Доступен ли EliteDash (политика, макросы, телеметрия) тем же удалённым
  сотрудникам по тому же VPN — тот же вопрос про транспорт, ответ может
  отличаться от SIP.

## Как использовать ответы

| Ответ | Куда идёт | Статус |
|---|---|---|
| `features.conf` / `extensions_custom.conf` | [Lab/asterisk/config/features.conf](../Lab/asterisk/config/features.conf) | ждём |
| `sip show settings` | [Lab/asterisk/config/sip.conf](../Lab/asterisk/config/sip.conf), секция `[general]` | перенесено 31.07.2026 |
| `sip show peer` | тот же `sip.conf`, секции пиров | перенесено 31.07.2026 |
| `rtp show settings` | [Lab/asterisk/config/rtp.conf](../Lab/asterisk/config/rtp.conf) | перенесено 31.07.2026 |

Пока не пришёл пункт 1, диалплан конференции и обеих dynamic-фич остаётся
лабораторным прототипом с явно помеченными догадками — менять клиентское
поведение под непроверенные предположения об одном конкретном боевом сервере
нельзя.
