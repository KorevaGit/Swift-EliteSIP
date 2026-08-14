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

Что важно: скрипт не выбрасывает переводы. Ключ, пропавший из кода, помечается
`extractionState: stale` и остаётся в файле — иначе переименование подписи
молча стирало бы английский перевод, а заметили бы это на чужой машине.

Запуск: Tools/sync-strings.py [--build]
"""

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "EliteSIP" / "Localizable.xcstrings"
SOURCE_LANGUAGE = "ru"


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


def merge(found: dict[str, str]) -> tuple[int, int, int]:
    catalog = json.loads(CATALOG.read_text()) if CATALOG.exists() else {
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

    stale = 0
    for key, entry in strings.items():
        if key not in found:
            entry["extractionState"] = "stale"
            stale += 1

    catalog["strings"] = dict(sorted(strings.items()))
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    return added, stale, len(strings)


def main() -> None:
    if "--build" in sys.argv:
        result = subprocess.run(
            ["xcodebuild", "-project", str(ROOT / "EliteSIP.xcodeproj"),
             "-scheme", "EliteSIP", "-configuration", "Debug", "build"],
            capture_output=True, text=True, cwd=ROOT,
        )
        if result.returncode != 0:
            sys.exit("сборка не прошла — каталог не тронут")

    found = collect(derived_data_dir())
    added, stale, total = merge(found)
    print(f"ключей в коде: {len(found)}")
    print(f"добавлено:     {added}")
    print(f"устарело:      {stale}")
    print(f"всего в файле: {total}")


if __name__ == "__main__":
    main()
