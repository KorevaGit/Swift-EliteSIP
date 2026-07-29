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
  Services/             настройки, Keychain, рингтон
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
Config/                 entitlements
docs/                   решения, которые нужно объяснять: аудиотракт, защита
                        от автокликеров, удержание и DTMF
Lab/                    три стенда в Docker: Asterisk 13.38.3 (боевая версия),
                        Asterisk 16 для сравнения, FreePBX 15 для понимания
```

Текущее состояние и грабли — [docs/STATE.md](docs/STATE.md). Согласованные
продуктовые решения и следующие работы — [docs/ROADMAP.md](docs/ROADMAP.md).

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
(cd Packages/Compat && swift test) && (cd Packages/SIPCore && swift test) \
  && (cd Packages/MediaCore && swift test) && (cd Packages/CallGuard && swift test)
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

Проверка против живой АТС и лаборатория — [Lab/README.md](Lab/README.md).
Настройки для клиентов, включая PortSIP на телефоне — [Lab/CLIENTS.md](Lab/CLIENTS.md).

## Этапы

- [x] **M0** — скелет, три окна, два пакета, лаборатория Asterisk
- [x] **M0b** — одна universal-сборка вместо одной цели под свежую macOS: срез
      `x86_64` собирается с deployment target 10.15, срез `arm64` — с 11.0.
      Слой совместимости — пакет `Compat` для стандартной библиотеки и
      `Theme/BackwardCompatibility.swift` для SwiftUI; точка входа переехала с
      `App`/`Window` на `NSApplicationDelegate`, `@Observable` — на
      `ObservableObject`, SF Symbols — на свой комплект иконок
- [x] **M1** — транспорт SIP, парсер, транзакции, регистрация (UDP и TLS)
- [x] **M1.5** — FreePBX рядом с нашим Asterisk, чтобы видеть, что он
      генерирует: контексты `from-internal`, `sub-record-check`, очереди,
      `MixMonitor`. Отдельный контейнер, не поверх лабы — см. ниже. Очередь
      раздачи 2929 заводится сама при старте контейнера, поэтому её поведение
      входит в воспроизводимую проверку — [Lab/FREEPBX.md](Lab/FREEPBX.md)
- [x] **M1.6** — настоящая история FreePBX: постоянные CDR/CEL в MariaDB,
      обязательная запись разговоров, прослушивание и скачивание записей из
      отчёта CDR — [Lab/FREEPBX.md](Lab/FREEPBX.md)
- [ ] **M2 — реализация готова, эксплуатационная приёмка продолжается**:
      исходящий звонок, RTP, аудиотракт, джиттер-буфер, раздельный выбор
      устройств и переключение на ходу — [docs/audio.md](docs/audio.md)
- [ ] **M2b — реализация готова, боевой профиль не подтверждён**: SRTP с SDES
      для TLS; боевой Asterisk сейчас использует UDP — [docs/srtp.md](docs/srtp.md)
- [ ] **M3 — реализация готова, политика корректируется**: входящий звонок и
      **защита от автокликеров** — случайная позиция окна, требование движения курсора, отсев
      синтетических нажатий, отчёт на каждый вызов. Подтверждение цифрой — опция
      в настройках, по умолчанию выключена; задержка активации будет удалена.
      Плюс рингтон —
      [docs/incoming.md](docs/incoming.md)
- [x] **M4** — удержание, DTMF и макросы. Удержание — повторный INVITE в обе
      стороны, включая старую запись `c=0.0.0.0`, которую chan_sip шлёт до сих
      пор; тоны по RFC 4733 внутри RTP; макросы с паузами —
      [docs/hold-dtmf.md](docs/hold-dtmf.md)
- [x] **M5** — слепой перевод через REFER/NOTIFY, включая точный результат
      созданного сервером INVITE; протокольная основа консультационного
      перевода через Replaces — [docs/transfer.md](docs/transfer.md)
- [ ] **M6** — три адресуемые линии, консультационный перевод и серверная
      конференция через ConfBridge. Первый срез — настраиваемая команда
      конференции для текущего разговора — [docs/conference.md](docs/conference.md)
- [x] **M6b** — стабилизация после аудита перед многолинейной архитектурой:
      реальная резервация пары RTP/RTCP, безопасный disconnect, строгая проверка
      SIP-диалогов, надёжная очередь DTMF и гарантированный mute микрофона —
      [docs/m6b.md](docs/m6b.md)
- [ ] **M7** — одна Universal для Catalina Intel и Big Sur Apple Silicon,
      мультиаккаунт с одним активным профилем, локальная история,
      административный режим, аудио-DSP, логи, подпись, нотаризация и DMG
- [ ] **M8** — синхронизация с EliteDash: политика защиты, имена extension,
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
в [Lab/FREEPBX.md](Lab/FREEPBX.md).

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
