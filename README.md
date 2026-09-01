# EliteSIP

SIP-софтфон под macOS для Asterisk. Написан с нуля на Swift: свой стек SIP и RTP,
без PJSIP, без Electron, без внешнего бэкенда. Один процесс, ноль IPC.

Предыдущая версия (`~/Projects/EliteSIP`: Python + pjsua2 + Tauri/React с
WebSocket-мостом) закрыта как неподдерживаемая. Она остаётся только справочным
материалом.

## Область

Только то, что нужно оператору: **конференция, удержание, DTMF, DTMF-макросы,
перевод и история звонков**. Нет контактов, нет голосовой почты, нет видео.
Только macOS; для Intel Mac обязательна поддержка macOS 10.15 Catalina,
приложение выпускается одной universal-сборкой.

Плюс то, ради чего проект в основном и начат: **защита приёма горячих лидов от
автокликеров**. Менеджер, автоматически принимающий вызов из очереди раздачи,
получает больше лидов, не находясь за рабочим местом, и лид уходит в тишину.
Рандомизация окна — часть этой защиты, а не косметика. Подробно:
[docs/anti-autoclicker.md](docs/anti-autoclicker.md).

## Решения

| | |
|---|---|
| Стек | свой: Network.framework + свой RTP + AVAudioEngine с VoiceProcessingIO |
| Транспорт | боевой Asterisk сейчас использует UDP; TLS + SRTP (SDES) поддерживаются отдельно |
| Кодеки | G.722 с fallback на G.711 PCMU/PCMA, 20 мс, + telephone-event (RFC 4733) |
| Сервер | Asterisk 13.38.3 под FreePBX, драйвер `chan_sip` |
| Окна | панель софтфона 280×500 · плавающее окно входящего 320×212 · окно настроек |
| macOS | одна Universal: `x86_64` для Catalina 10.15+, `arm64` для Big Sur 11+ |
| Конференция | ConfBridge на стороне Asterisk |
| Перевод | REFER + Replaces, плюс серверные DTMF-коды через макросы |
| Sandbox | выключен; Hardened Runtime включён |
| Дизайн | [Figma: Swift EliteSIP](https://www.figma.com/design/gcXOwiSXo7Ca5drVskhluG/Swift-EliteSIP) |

Почему свой стек, а не PJSIP: область узкая (один сервер, один аудиопоток на
звонок, без видео и без ICE), эхоподавление даёт система, а любой баг читается
и правится в своём коде. Аварийный выход — заменить только медиа-слой на
baresip/libre, не трогая сигнализацию.

## Структура

```
EliteSIP.xcodeproj      objectVersion 77, синхронизированная с файловой системой
                        группа — файлы подхватываются сами, pbxproj править не надо
EliteSIP/               приложение
  App/                  main.swift, делегат приложения, состояние
  Assets.xcassets/      Symbols/ — свой комплект иконок вместо SF Symbols,
                        которых на Catalina нет. Исходники — во фрейме
                        «Иконки · комплект для Catalina» того же макета Figma
  Services/             настройки, рингтон
  Views/                панель, дайлпад, входящий вызов, настройки
  Windows/              NSPanel входящего, слежение за курсором, доступ к NSWindow
  Theme/                токены размеров и цветов, шим Liquid Glass ↔ материалы,
                        BackwardCompatibility.swift — весь слой совместимости UI
Packages/Compat/        то, чего нет в стандартной библиотеке до macOS 13:
                        Interval и MonotonicClock вместо Duration и
                        ContinuousClock, UnfairLock вместо OSAllocatedUnfairLock
Packages/SIPCore/       протокол SIP. Без AppKit, без аудио, полностью тестируем
Packages/MediaCore/     RTP и кодеки. Без AppKit
Packages/CallGuard/     защита приёма вызова: случайность, признаки живого
                        человека, отчёт. Чистая логика, время и ГПСЧ снаружи
Packages/Diagnostics/   файловый журнал: маскирование секретов, ротация,
                        архив для поддержки
Packages/AdminAccess/   административный доступ: проверочное значение пароля,
                        код восстановления, режим управления
Packages/CallHistory/   локальная история звонков: SQLite из системы, срок
                        хранения, выборки. Без AppKit
Config/                 entitlements
docs/                   решения, которые нужно объяснять: аудиотракт, защита
                        от автокликеров, удержание и DTMF
```

Сайт раздачи `elitesip.vip` вынесен туда же — отдельным проектом
`~/Projects/EliteSIP-Site`. Он выкладывается на другую машину и своей командой,
к сборке и подписи приложения отношения не имеет, а установщики берёт из
`build/release` готовыми.

Стенд лаборатории вынесен из репозитория и живёт отдельным проектом
`~/Projects/FreePBXLab` — FreePBX 15 на Asterisk 13.38.3, боевой версии, и для
отладки клиента, и для понимания устройства сервера. Своего git у него нет
намеренно: это стенд, а не продукт.

Текущее состояние и грабли — [docs/STATE.md](docs/STATE.md). Согласованные
продуктовые решения и следующие работы — [docs/ROADMAP.md](docs/ROADMAP.md).
Два языка интерфейса и то, что переводится, а что намеренно нет, —
[docs/localization.md](docs/localization.md).

## Сборка и тесты

```bash
xcodebuild -project EliteSIP.xcodeproj -scheme EliteSIP -configuration Debug build
```

Debug собирается только под текущую архитектуру, поэтому на Apple Silicon он
никогда не проверит срез Catalina. Совместимость ломается молча — компилятор
ругается только тогда, когда цель действительно 10.15, — поэтому её надо
проверять отдельной командой:

```bash
xcodebuild -project EliteSIP.xcodeproj -scheme EliteSIP -configuration Debug -arch x86_64 ONLY_ACTIVE_ARCH=NO build
```

Release собирает обе архитектуры сразу. Что у среза внутри — видно так:

```bash
lipo -archs "$(xcodebuild -project EliteSIP.xcodeproj -scheme EliteSIP -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n"/Contents/MacOS/EliteSIP"}')"
```

```bash
(cd Packages/Compat && swift test) && (cd Packages/Diagnostics && swift test) \
  && (cd Packages/SIPCore && swift test) && (cd Packages/MediaCore && swift test) \
  && (cd Packages/CallGuard && swift test) && (cd Packages/AdminAccess && swift test) \
  && (cd Packages/CallHistory && swift test)
```

Подписи проверяются отдельно от кода: каталог собирается из того, что извлёк
компилятор, а проверка печатает русские строки без перевода и ключи без
английского. Ноль в обеих графах — условие выпуска, подробнее в
[docs/localization.md](docs/localization.md).

```bash
Tools/sync-strings.py && Tools/check-strings.py
```

Разговор со звуком против живой АТС и замеры аудиотракта:

```bash
(cd Tools/sipcheck && swift run sipcheck --user 100 --password elite100 --call 600 --audio)
```

Приём входящего против живой АТС — `--answer`, а позвонить на себя проще всего
через `channel originate` на стороне Asterisk:

```bash
(cd Tools/sipcheck && swift run sipcheck --user 100 --password elite100 --duration 15 --answer)
```

Три линии сразу и консультационный перевод против живой АТС. Цели 700/701/702
уводят звонок в `Local`-канал: перевести можно только канал, у которого есть
собеседник, а внутри `Echo()` его нет — см. [FreePBXLab/README.md](../FreePBXLab/README.md):

```bash
(cd Tools/sipcheck && swift run sipcheck --user 100 --password elite100 --lines 700,701,702)
```

```bash
(cd Tools/sipcheck && swift run sipcheck --user 100 --password elite100 --call 700 --consult 701)
```

Тоны и удержание против живой АТС. Добавочный 603 на стенде читает набранное
вслух, и в журнале Asterisk видно, что именно он принял:

```bash
(cd Tools/sipcheck && swift run sipcheck --user 100 --password elite100 --call 603 --duration 24 --dtmf "4915" --dtmf-after 4)
```

```bash
(cd Tools/sipcheck && swift run sipcheck --user 100 --password elite100 --call 600 --duration 14 --hold 5)
```

```bash
(cd Tools/audioprobe && swift run audioprobe list)
```

Проверка против живой АТС и лаборатория — [FreePBXLab/README.md](../FreePBXLab/README.md).
Настройки для клиентов, включая PortSIP на телефоне — [FreePBXLab/CLIENTS.md](../FreePBXLab/CLIENTS.md).

## Этапы

Пометка **⟨аудит 1⟩** означает, что по этапу прошла первая волна аудита —
отдельный проход по уже написанному коду в поиске расхождений между тем, что
записано в документах, и тем, что делает программа. Найденное и закрытое
записано в [docs/STATE.md](docs/STATE.md) и в файле самого этапа. **M7a** и
**M7b** прошли свой аудит позже, 3 августа 2026, и помечены так же. Этапы без
пометки аудита не проходили вовсе: **M1.5**, **M1.6**, **M2c** и **M2d**.

- [x] **M0** — скелет, три окна, два пакета, лаборатория Asterisk
- [x] **M0b** ⟨аудит 1⟩ — одна universal-сборка вместо одной цели под свежую macOS: срез
      `x86_64` собирается с deployment target 10.15, срез `arm64` — с 11.0.
      Слой совместимости — пакет `Compat` для стандартной библиотеки и
      `Theme/BackwardCompatibility.swift` для SwiftUI; точка входа переехала с
      `App`/`Window` на `NSApplicationDelegate`, `@Observable` — на
      `ObservableObject`, SF Symbols — на свой комплект иконок
- [x] **M1** ⟨аудит 1⟩ — транспорт SIP, парсер, транзакции, регистрация (UDP и TLS)
- [x] **M1.5** — FreePBX рядом с нашим Asterisk, чтобы видеть, что он
      генерирует: контексты `from-internal`, `sub-record-check`, очереди,
      `MixMonitor`. Отдельный контейнер, не поверх лабы — см. ниже. Очередь
      раздачи 2929 заводится сама при старте контейнера, поэтому её поведение
      входит в воспроизводимую проверку — [FreePBXLab/FREEPBX.md](../FreePBXLab/FREEPBX.md)
- [x] **M1.6** — настоящая история FreePBX: постоянные CDR/CEL в MariaDB,
      обязательная запись разговоров, прослушивание и скачивание записей из
      отчёта CDR — [FreePBXLab/FREEPBX.md](../FreePBXLab/FREEPBX.md)
- [x] **M2** ⟨аудит 1⟩ — исходящий звонок, RTP, аудиотракт, джиттер-буфер, раздельный выбор
      устройств и переключение на ходу. Сборка под оба среза выпуска проверяется
      скриптом `Tools/check-compat.sh`. Остаётся эксплуатационная приёмка на
      живой Catalina и на расширенной матрице устройств —
      [docs/audio.md](docs/audio.md)
- [x] **M2b** ⟨аудит 1⟩ — SRTP с SDES для TLS: `RTP/SAVP`, `AES_CM_128_HMAC_SHA1_80`, запрет
      незаметного downgrade в обе стороны. Сверка 31 июля 2026 показала, что на
      бою TLS выключен целиком, поэтому защищённый профиль подтверждённо **не
      развёрнут** — [docs/srtp.md](docs/srtp.md)
- [ ] **M2c** — широкая полоса против боевого порядка кодеков. Работа
      эксплуатационная, а не программная: клиент готов, но боевой `allow` держит
      G.722 последним, и Asterisk как отвечающая сторона выбирает по своей
      очереди — [docs/ROADMAP.md](docs/ROADMAP.md)
- [x] **M2d** — транспорт удалённого профиля: «VPN» оказался стуком по портам, а
      не туннелем. Открытый UDP принят как осознанное решение, стук перенесён из
      скрипта в клиент — [docs/remote-access.md](docs/remote-access.md)
- [x] **M3** ⟨аудит 1⟩ — входящий звонок и **защита от автокликеров**: случайная позиция
      окна как основная мера, требование движения курсора, отсев синтетических
      нажатий, отчёт на каждый вызов, отказ отвечает `486`. Подтверждение цифрой —
      опция в настройках, по умолчанию выключена. Задержки активации нет, приём
      вызова — только мышью. Плюс рингтон —
      [docs/incoming.md](docs/incoming.md)
- [x] **M4** ⟨аудит 1⟩ — удержание, DTMF и макросы. Удержание — повторный INVITE в обе
      стороны, включая старую запись `c=0.0.0.0`, которую chan_sip шлёт до сих
      пор; тоны по RFC 4733 внутри RTP; макросы с паузами —
      [docs/hold-dtmf.md](docs/hold-dtmf.md)
- [x] **M5** ⟨аудит 1⟩ — слепой перевод через REFER/NOTIFY, включая точный результат
      созданного сервером INVITE; протокольная основа консультационного
      перевода через Replaces — [docs/transfer.md](docs/transfer.md)
- [x] **M6** ⟨аудит 1⟩ — три адресуемые по Call-ID линии, одна активная аудиолиния,
      консультационный перевод через REFER с Replaces и серверная конференция
      через ConfBridge настраиваемой командой — [docs/lines.md](docs/lines.md) и
      [docs/conference.md](docs/conference.md). Три линии и перевод прогнаны на
      живом Asterisk 13.38.3; сверка боевого feature-code — впереди
- [x] **M6b** ⟨аудит 1⟩ — стабилизация после аудита перед многолинейной архитектурой:
      реальная резервация пары RTP/RTCP, безопасный disconnect, строгая проверка
      SIP-диалогов, надёжная очередь DTMF и гарантированный mute микрофона.
      Повторён на трёх линиях, закрыт запрет отключения профиля в разговоре,
      выполнен живой прогон линий — [docs/m6b.md](docs/m6b.md)
- [ ] **M7** — локальное администрирование и выпуск. Совместимость сама по себе
      закрыта в M0b; остаток разбит на подэтапы в
      [docs/ROADMAP.md](docs/ROADMAP.md): **M7a** ⟨аудит 1⟩ файловые логи
      (сделано, [docs/logs.md](docs/logs.md)), **M7b** ⟨аудит 1⟩ профили
      аккаунтов с явной пометкой офисного и удалённого рабочего места (сделано,
      [docs/profiles.md](docs/profiles.md)),
      **M7c** административный режим, **M7d** локальная история
      звонков (сделано, [docs/history.md](docs/history.md)),
      **M7e** подпись, нотарификация и DMG, **M7f** приёмка на живом
      Intel с Catalina, **M7g** отдельный аудио-DSP, **M7h** автообновление
      через Sparkle с раздачей с `get.elitesip.vip` (Cloudflare R2). Цепочка
      зависимостей: M7e → M7f → M7g. M7h нотарификации не требует — Sparkle
      снимает карантин сам, и этап идёт на самоподписанном сертификате. Разбор
      подписи, нотарификации, Gatekeeper и двух разных ключей —
      [docs/release.md](docs/release.md)
- [ ] **M9** — панель EliteSIP: политика защиты, имена extension,
      макросы, полные CDR/CEL, объединённая история и провижининг удалёнщиков

### Про FreePBX в M1.5–M1.6

Поставить FreePBX «поверх» лабораторного Asterisk в смысле общих конфигов
нельзя: FreePBX генерирует `sip.conf`, `extensions.conf` и остальное из своей
базы и при каждом «Apply Config» перезаписывает их — а лаба нужна именно с
предсказуемым руками написанным диалпланом. Поэтому это **отдельный контейнер**,
но собранный на том же образе Asterisk 13.38.3, что и лаба, и с FreePBX 15 —
версией, которая штатно работает с Asterisk 13, то есть с той же парой, что на
бою.

Задача стенда другая: не отладка клиента, а возможность увидеть, какие файлы и
какой диалплан FreePBX создаёт под очередь раздачи и запись разговоров, и
сверить с боевыми CDR и CEL. Разбор и инструмент для сравнения «до/после» —
в [FreePBXLab/FREEPBX.md](../FreePBXLab/FREEPBX.md).

## Что известно про бой из CDR и CEL

| | |
|---|---|
| Очередь раздачи | `2929`, CallerID `"AutoDialer" <2929>` |
| Внутренние номера | трёхзначные: 634, 711, 724, 807 |
| Каналы агентов | `SIP/711-…` — подтверждает `chan_sip` |
| Контексты | `from-trunk`, `from-auto-dialer`, `from-internal`, `sub-record-check` |
| Запись | `MixMonitor` на стороне сервера, клиент не участвует |
| Номер клиента | в `accountcode` (колонка «Учётка»), **не** в CallerID агента |

Последняя строка важна для M3: на плечо агента уходит CallerID очереди, а не
номер клиента. Значит окно входящего сможет показать «раздача из 2929» — если
номер клиента нужен на экране, его должен передавать диалплан.

## Открытые вопросы

Актуальный список решений и оставшихся вопросов ведётся в
[docs/ROADMAP.md](docs/ROADMAP.md). Главные блокеры: слой совместимости с
Catalina, проверка VPN-скрипта и проверенные фрагменты боевого диалплана.
