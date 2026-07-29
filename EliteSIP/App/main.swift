import AppKit

// Точка входа.
//
// Отдельный `main.swift`, а не `@main` на `AppDelegate`: делегат обязан
// пережить запуск, а `NSApplication.delegate` держит его слабо. Здесь ссылка
// глобальная, то есть живёт весь процесс. Подробнее — в `EliteSIPApp.swift`.
//
// SwiftUI-точки входа (`App` и `@main struct`) не годятся вовсе: протокол `App`
// появился в macOS 11, а срез x86_64 обязан работать на Catalina.
let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
