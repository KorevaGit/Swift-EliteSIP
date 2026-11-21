# Заметки для агентов

- Тесты пакетов: `cd Packages/<Имя> && swift test` (SIPCore, MediaCore, CallHistory, Diagnostics, CallGuard, AdminAccess, PanelLink, Compat).
- Сборка приложения — только Xcode 26.6 (Xcode 27 не поддерживает цель 10.15):
  `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project EliteSIP.xcodeproj -scheme EliteSIP -configuration Debug -derivedDataPath /tmp/elitesip-dd -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
- Совместимость с Catalina: `Tools/check-compat.sh`.
- Перенос изменений Windows-клиента: источник — `../Win-EliteSIP-main/Mychanges.md`.
- Release-сборка требует `Config/provisioning.local.json` (секреты, в репозитории нет). Проверка совместимости без него: universal Release с `-derivedDataPath`, затем `vtool -arch x86_64 -show-build` → minos 10.15, arm64 → 11.0.
- Debug для запуска: добавить `ONLY_ACTIVE_ARCH=NO ARCHS="x86_64 arm64" CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""` и скопировать `.app` в `build/debug/`.
- Скрипты `Tools/check-strings.py`/`sync-strings.py` ищут DerivedData по умолчанию (`/Volumes/EliteDev`); без него ключи вносятся в `EliteSIP/Localizable.xcstrings` вручную, без пересортировки.
- Иконка: `swift Tools/makeAppIcon.swift` из корня; геометрия знака повторена в `EliteSIP/Theme/BrandMark.swift`.
- Отладочные ключи Debug для снимков без мыши: `--appearance light|dark`, `--settings <раздел>`, `--administration connection|macros|incoming|system|spark`, `--history`, `--first-run welcome|user|appearance|finale`, `--demo-incoming`, `--dialog` (графитовый вопрос), `--dialog update` (предложение обновиться с заметками `docs/releases/0.1.72.md`, запускать из корня проекта), `--menu` (меню значка), `--perf [--perf-window phone|history|settings] [--perf-resize]` (время открытия окон и разрывы кадров при движении). Снимок окна: `screencapture -x -o -l <windowID>`; ID — через `CGWindowListCopyWindowInfo`.
- Заметки выпуска — `docs/releases/<версия>.md`, пунктами через «- »: `Tools/release.sh` кладёт их в `<description>` записи appcast, окно обновления показывает их списком «Что нового».
- Привязки контролов к `@Published` (сегменты, сайдбар, тумблеры, ползунки) — через `Binding.deferred()` / `afterViewUpdate`, иначе SwiftUI пишет «Publishing changes from within view updates». Стек такого предупреждения берётся из `log show --style json` (поле `backtrace`) и `atos -o …/EliteSIP.debug.dylib -l 0x0 <смещение>`.
