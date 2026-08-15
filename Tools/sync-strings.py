#!/usr/bin/env python3
"""
Сборка каталога строк из того, что извлёк компилятор.

Ключом служит русский текст: `Text("Завершить")` в коде — это уже ключ, и
никакой обёртки вокруг литерала SwiftUI не нужно. Компилятор с
`SWIFT_EMIT_LOC_STRINGS = YES` выкладывает найденные ключи в `.stringsdata`
рядом с объектными файлами; Xcode собирает их в `.xcstrings` сам, но только
когда сборку запускают из IDE. Сборка из терминала — и, значит, любая
проверка на CI — каталог не трогает вовсе. Этот скрипт делает ту же работу
воспроизводимо.

Ключи собираются из двух мест, потому что компилятор видит не всё:

  * `.stringsdata` — литералы SwiftUI, то есть всё, что попадает в
    `LocalizedStringKey`;
  * сами исходники — вызовы `NSLocalizedString`. Их компилятор в
    `.stringsdata` не кладёт: он извлекает `String(localized:)`, а тот
    появился в macOS 12 и нижней планке проекта не годится. Для строк, у
    которых вью нет вовсе — пункты меню AppKit, заголовки разделов,
    вычисленные состояния, — остаётся `NSLocalizedString`, и его разбирает
    этот скрипт, как когда-то `genstrings`.

У пакетов есть лишний шаг. SwiftPM `.xcstrings` компилировать не умеет:
`swift build` копирует каталог сырым, а Xcode выбрасывает его молча — и то и
другое означает, что `NSLocalizedString` в пакете не находит ничего. Поэтому
каталог пакета лежит вне ресурсов, а в ресурсы едут собранные им `.lproj`,
которые пакет и несёт. Собирает их тот же `xcstringstool`, что и у
приложения, — вызывает его этот скрипт.

Русский выписывается явно, хотя его значения равны ключам. Без этого
`xcstringstool` кладёт в `ru.lproj` один только `.stringsdict` с формами
множественного числа, а каталог из одного `.stringsdict` система за
локализацию не считает: русской машине доставался бы английский интерфейс.

Что важно: скрипт не выбрасывает переводы. Ключ, пропавший из кода, помечается
`extractionState: stale` и остаётся в файле — иначе переименование подписи
молча стирало бы английский перевод, а заметили бы это на чужой машине.

Запуск: Tools/sync-strings.py [--build]
"""

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_LANGUAGE = "ru"

# Каталог у приложения свой, и у каждого пакета, который что-то говорит
# человеку, — тоже свой. Пакет остаётся самодостаточным: приложению не
# приходится знать, какие у `AdminAccess` бывают отказы, чтобы их подписать.
TARGETS: list[tuple[Path, Path]] = [
    (ROOT / "EliteSIP", ROOT / "EliteSIP" / "Localizable.xcstrings"),
]
PACKAGES = ["AdminAccess", "CallGuard", "CallHistory", "SIPCore"]
for package in PACKAGES:
    TARGETS.append((ROOT / "Packages" / package / "Sources" / package,
                    ROOT / "Packages" / package / "Localizable.xcstrings"))

# `NSLocalizedString("ключ", comment: "пояснение")` — с обычным литералом или с
# многострочным. Оба аргумента обязаны быть литералами: переменная ключом не
# станет ни здесь, ни в Xcode.
NS_LOCALIZED = re.compile(
    r'NSLocalizedString\(\s*'
    r'(?:"""(?P<block>.*?)"""|"(?P<line>(?:[^"\\]|\\.)*)")\s*,\s*'
    # Между ключом и пояснением стоят необязательные аргументы: у пакетов это
    # `bundle: .module`, без которого строка искалась бы в приложении.
    r'(?:(?:tableName|bundle|value):\s*[^,]+,\s*)*'
    r'comment:\s*"(?P<comment>(?:[^"\\]|\\.)*)"\s*\)',
    re.DOTALL,
)


def unescape(text: str) -> str:
    """То же, что делает компилятор с литералом."""
    return (text.replace('\\"', '"').replace("\\n", "\n")
                .replace("\\t", "\t").replace("\\\\", "\\"))


def multiline(body: str) -> str:
    """Многострочный литерал так, как его видит компилятор.

    Порядок важен и повторяет язык: сперва снимается отступ, заданный строкой с
    закрывающими кавычками, и только потом склеиваются переносы по обратному
    слэшу. Наоборот — и ключ разойдётся с тем, что окажется в `.stringsdata`,
    на один пробел или на пустую строку в конце.
    """
    lines = body.split("\n")
    if lines and not lines[0].strip():
        lines = lines[1:]
    if not lines:
        return ""
    closing = lines[-1]
    indent = closing[:len(closing) - len(closing.lstrip())]
    lines = [line[len(indent):] if line.startswith(indent) else line.lstrip()
             for line in lines[:-1]]
    return re.sub(r"\\\n", "", "\n".join(lines))


def scan_sources(sources: Path) -> dict[str, str]:
    """Ключи из `NSLocalizedString`: ключ → комментарий."""
    keys: dict[str, str] = {}
    for path in sorted(sources.rglob("*.swift")):
        for match in NS_LOCALIZED.finditer(path.read_text()):
            if match.group("block") is not None:
                key = multiline(match.group("block"))
            else:
                key = unescape(match.group("line"))
            if key:
                keys.setdefault(key, unescape(match.group("comment")))
    return keys


def derived_data_dir() -> Path:
    """Каталог сборки ищем через сам xcodebuild, а не по маске имени."""
    output = subprocess.run(
        ["xcodebuild", "-project", str(ROOT / "EliteSIP.xcodeproj"),
         "-scheme", "EliteSIP", "-configuration", "Debug", "-showBuildSettings"],
        capture_output=True, text=True, cwd=ROOT,
    ).stdout
    for line in output.splitlines():
        if "BUILD_ROOT = " in line:
            return Path(line.split("BUILD_ROOT = ", 1)[1].strip())
    sys.exit("не удалось определить каталог сборки: нет BUILD_ROOT")


def collect(build_root: Path) -> dict[str, str]:
    """Ключ → комментарий. Срезы arm64 и x86_64 дают одно и то же, поэтому dict."""
    intermediates = build_root.parent / "Intermediates.noindex"
    if not intermediates.is_dir():
        sys.exit(f"нет промежуточных файлов сборки: {intermediates}")

    keys: dict[str, str] = {}
    for path in intermediates.rglob("*.stringsdata"):
        # Пакеты Swift несут свои каталоги — их строки сюда не попадают.
        if "/EliteSIP.build/" not in str(path):
            continue
        data = json.loads(path.read_text())
        for entry in data.get("tables", {}).get("Localizable", []):
            key = entry.get("key", "")
            # Пустой ключ — это `Text("")` или подсказка без текста: в каталоге
            # ему делать нечего, переводить нечего.
            if not key:
                continue
            keys.setdefault(key, entry.get("comment", ""))
    return keys


def merge(catalog_path: Path, found: dict[str, str]) -> tuple[int, int, int]:
    catalog = json.loads(catalog_path.read_text()) if catalog_path.exists() else {
        "sourceLanguage": SOURCE_LANGUAGE, "strings": {}, "version": "1.0"
    }
    strings = catalog.setdefault("strings", {})

    added = 0
    for key, comment in sorted(found.items()):
        entry = strings.get(key)
        if entry is None:
            entry = {}
            if comment:
                entry["comment"] = comment
            strings[key] = entry
            added += 1
        # Ключ вернулся в код — снимаем метку «устарел».
        elif entry.get("extractionState") == "stale":
            del entry["extractionState"]

        # Русский — язык исходников, и его значение равно ключу. Записывается
        # оно всё равно: иначе в `ru.lproj` не окажется `Localizable.strings`,
        # и локализации как бы нет.
        localizations = entry.setdefault("localizations", {})
        if "ru" not in localizations:
            localizations["ru"] = {
                "stringUnit": {"state": "translated", "value": key}
            }

    stale = 0
    for key, entry in strings.items():
        if key not in found:
            entry["extractionState"] = "stale"
            stale += 1

    catalog["strings"] = dict(sorted(strings.items()))
    catalog_path.parent.mkdir(parents=True, exist_ok=True)
    catalog_path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    return added, stale, len(strings)


def compile_packages() -> None:
    """Собрать `.lproj` пакетов из их каталогов.

    Результат кладётся в ресурсы и попадает в репозиторий: пакет должен
    собираться `swift build` у того, кто не запускал этот скрипт.
    """
    for package in PACKAGES:
        catalog = ROOT / "Packages" / package / "Localizable.xcstrings"
        resources = ROOT / "Packages" / package / "Sources" / package / "Resources"
        for stale in resources.glob("*.lproj"):
            shutil.rmtree(stale)
        resources.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            ["xcrun", "xcstringstool", "compile",
             "--output-directory", str(resources), str(catalog)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            sys.exit(f"{package}: xcstringstool не собрал каталог\n{result.stderr}")
        built = sorted(path.name for path in resources.glob("*.lproj"))
        print(f"  {package}: {', '.join(built)}")


def main() -> None:
    if "--build" in sys.argv:
        result = subprocess.run(
            ["xcodebuild", "-project", str(ROOT / "EliteSIP.xcodeproj"),
             "-scheme", "EliteSIP", "-configuration", "Debug", "build"],
            capture_output=True, text=True, cwd=ROOT,
        )
        if result.returncode != 0:
            sys.exit("сборка не прошла — каталог не тронут")

    # `.stringsdata` есть только у приложения: в пакетах нет SwiftUI, и все
    # их подписи — это `NSLocalizedString`, который компилятор туда не кладёт.
    from_compiler = collect(derived_data_dir())

    for sources, catalog_path in TARGETS:
        found = dict(from_compiler) if sources.name == "EliteSIP" else {}
        # Комментарий из исходника ценнее пустого из `.stringsdata`, поэтому
        # `NSLocalizedString` кладётся поверх.
        found.update(scan_sources(sources))
        added, stale, total = merge(catalog_path, found)
        print(f"{catalog_path.relative_to(ROOT)}")
        print(f"  в коде {len(found)}, добавлено {added}, устарело {stale}, всего {total}")

    print("собраны ресурсы пакетов:")
    compile_packages()


if __name__ == "__main__":
    main()
