# Заметки для агентов

- Тесты пакетов: `cd Packages/<Имя> && swift test` (SIPCore, MediaCore, CallHistory, Diagnostics, CallGuard, AdminAccess, PanelLink, Compat).
- Сборка приложения — только Xcode 26.6 (Xcode 27 не поддерживает цель 10.15):
  `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project EliteSIP.xcodeproj -scheme EliteSIP -configuration Debug -derivedDataPath /tmp/elitesip-dd -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
- Совместимость с Catalina: `Tools/check-compat.sh`.
- Перенос изменений Windows-клиента: источник — `../Win-EliteSIP-main/Mychanges.md`.
