#!/usr/bin/env python3
"""
Что из русского текста в коде не попало в каталог переводов.

Критерий этапа 8 — «ни одной русской подписи, не имеющей перевода» — глазами не
проверяется: строк под тысячу, и разбросаны они по сотне файлов. Скрипт
проверяет каждый русский литерал по его собственному месту в коде: локализован
ли он **здесь**, а не нашёлся ли такой же текст где-то в каталоге. Разница
существенная. `NumberField(placeholder: "Номер")` — обычная строка AppKit,
переводом она не станет никогда, но ключ «Номер» в каталоге есть от соседнего
`TextField("Номер")`, и проверка по каталогу такую подпись пропускает. Живой
английский прогон её и нашёл.

Литерал считается локализованным, если он либо стоит ключом в
`NSLocalizedString`, либо его строку назвал сам компилятор в `.stringsdata` —
то есть он попал в `LocalizedStringKey`. Всё остальное — либо забытая подпись,
либо строка, которую переводить не надо; второе помечается в самом коде.

Помечается тремя способами, все видны на месте:

  * `append(level:message:)` — строка журнала. По решению этапа 8 журнал
    остаётся техническим и не переводится: его сравнивают между машинами, а
    перевод сделал бы одно и то же событие двумя разными строками;
  * `verbatim:` у своих компонентов — текст собран в рантайме;
  * `precondition`, `assert`, `fatalError` — сообщение читает тот, кто правит
    этот же код, а не человек за телефоном;
  * комментарий `// не переводится: причина`. Он действует до конца блока, в
    котором стоит, — иначе список из восьми отладочных макросов пришлось бы
    помечать восемь раз, и семь пометок из восьми были бы шумом.

Всё, что не помечено и не найдено в каталоге, скрипт печатает как долг. Вторым
списком идут ключи, у которых нет английского перевода: ключ без перевода
закрывает первую половину критерия этапа и не закрывает вторую — переключение
языка такую подпись оставит русской.

Запуск: Tools/check-strings.py [--all]   (--all показывает и помеченные)
"""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Приложение и пакеты сразу: пакет со своим каталогом проверяется по нему, а
# пакет без каталога — по пустому списку ключей, то есть каждая его русская
# строка обязана быть помечена как непереводимая.
TARGETS: list[tuple[Path, Path]] = [
    (ROOT / "EliteSIP", ROOT / "EliteSIP" / "Localizable.xcstrings"),
]
for package in ["AdminAccess", "CallGuard", "CallHistory", "MediaCore", "SIPCore", "Diagnostics"]:
    # Каталог пакета лежит вне ресурсов: SwiftPM `.xcstrings` не компилирует,
    # и в ресурсы едут собранные из него `.lproj` — см. `sync-strings.py`.
    TARGETS.append((ROOT / "Packages" / package / "Sources" / package,
                    ROOT / "Packages" / package / "Localizable.xcstrings"))

CYRILLIC = re.compile(r"[А-Яа-яЁё]")
# Литерал стоит ключом в `NSLocalizedString` — значит, переводится.
LOCALIZED_KEY = re.compile(r"NSLocalizedString\(\s*$")
EXEMPT = re.compile(r"//\s*не переводится")
# Строка журнала. Форм три — по одной на слой:
#
#   `append(level: .info, message: "…")`  — приложение;
#   `log(.info, "…")` / `log(level, "…")` — SIPCore;
#   `onDiagnostic?("…")`                  — MediaCore.
#
# Скобки в хвосте не допускаются намеренно: иначе выражение накрыло бы
# соседний вызов, стоящий следом за закрытой скобкой журнала. Между началом
# вызова и литералом при этом бывает тернар, и его пропустить надо.
JOURNAL = re.compile(
    r"(append\(\s*level:[^()]*message:[^()]*"
    r"|\blog\(\s*(?:\.\w+|level)\s*,[^()]*"
    r"|onDiagnostic\??\([^()]*)$"
)
# Пояснение переводчику в самом `NSLocalizedString` — не подпись приложения.
COMMENT_ARGUMENT = re.compile(r"comment:\s*$")
# Сообщение проверки в коде. Его читает тот, кто правит этот же код, и увидеть
# его можно только уронив сборку: до человека за телефоном оно не доходит.
ASSERTION = re.compile(r"\b(precondition|preconditionFailure|assert|assertionFailure|fatalError)\([^()]*$")
# Форматные вставки, которыми компилятор заменяет интерполяцию в ключе.
FORMAT = re.compile(r"%(?:\d+\$)?[-+ #0]*[\d.*]*(?:l{0,2}|h{0,2}|z|j|t|L|q)[@dioux XeEfgGcsp%]")
INTERPOLATION = re.compile(r"\\\([^()]*(?:\([^()]*\)[^()]*)*\)")
# `\u{203A}` — та же «›», что и в ключе: компилятор escape уже развернул.
UNICODE_ESCAPE = re.compile(r"\\u\{([0-9A-Fa-f]+)\}")


def normalize(text: str) -> str:
    """Ключ и литерал сходятся, если совпадают вне переменной части."""
    text = UNICODE_ESCAPE.sub(lambda m: chr(int(m.group(1), 16)), text)
    text = INTERPOLATION.sub("\0", text)
    text = FORMAT.sub("\0", text)
    return re.sub(r"\s+", " ", text).strip()


class Literal:
    """Литерал, его место и то, помечен ли он как непереводимый."""

    def __init__(self, line: int, text: str, before: str, exempt: bool):
        self.line = line
        self.text = text
        self.before = before
        self.exempt = exempt


def literals(source: str) -> list[Literal]:
    """Строковые литералы файла.

    Свой разбор, а не регулярное выражение на всё сразу: в проекте есть и
    многострочные литералы с переносом по обратному слэшу, и интерполяция с
    вложенными кавычками — на них однострочный шаблон врёт в обе стороны.
    Заодно разбор считает вложенность фигурных скобок: без неё пометка
    «не переводится» не знала бы, где кончается её область.
    """
    found: list[Literal] = []
    marks: list[int] = []          # вложенность каждой действующей пометки
    i, line, depth, length = 0, 1, 0, len(source)

    def note(start_line: int, text: str, position: int) -> None:
        # Окно шире, чем кажется нужным: у журнала с тернаром между `append(`
        # и вторым литералом стоит первый, и двухсот знаков на них не хватает.
        before = re.sub(r"\s+", " ", source[max(0, position - 600):position])
        # Интерполяция выбрасывается до разбора: её скобки закрывали бы вызов
        # журнала, и `message: "…\(Int(seconds)) с" + "…"` читалось бы как
        # подпись интерфейса.
        before = INTERPOLATION.sub("", before)
        # Соседние литералы тоже выбрасываются: скобка внутри текста — «стук
        # перед регистрацией (» — иначе обрывает поиск вызова журнала.
        before = re.sub(r'"[^"]*"', "", before)
        found.append(Literal(start_line, text, before, bool(marks)))

    while i < length:
        char = source[i]

        if char == "\n":
            line += 1
            i += 1
            continue

        # Комментарии пропускаем целиком: кавычки внутри них не литералы.
        if source.startswith("//", i):
            end = source.find("\n", i)
            end = length if end < 0 else end
            if EXEMPT.search(source[i:end]):
                marks.append(depth)
            i = end
            continue
        if source.startswith("/*", i):
            end = source.find("*/", i + 2)
            end = length if end < 0 else end + 2
            line += source.count("\n", i, end)
            i = end
            continue

        if source.startswith('"""', i):
            start_line = line
            end = source.find('"""', i + 3)
            end = length if end < 0 else end
            body = source[i + 3:end]
            line += source.count("\n", i, end + 3)
            # Перенос обратным слэшем склеивает строку — так же, как в Swift.
            note(start_line, re.sub(r"\\\n\s*", "", body), i)
            i = end + 3
            continue

        if char == '"':
            start_line = line
            j, body = i + 1, []
            while j < length and source[j] != '"':
                if source.startswith("\\(", j):
                    nesting, k = 0, j + 1
                    while k < length:
                        if source[k] == "(":
                            nesting += 1
                        elif source[k] == ")":
                            nesting -= 1
                            if nesting == 0:
                                break
                        elif source[k] == '"':
                            # Вложенный литерал целиком, вместе с кавычками.
                            k += 1
                            while k < length and source[k] != '"':
                                k += 2 if source[k] == "\\" else 1
                        k += 1
                    body.append(source[j:k + 1])
                    j = k + 1
                    continue
                if source[j] == "\\" and j + 1 < length:
                    body.append(source[j:j + 2])
                    j += 2
                    continue
                if source[j] == "\n":
                    break
                body.append(source[j])
                j += 1
            note(start_line, "".join(body), i)
            i = j + 1
            continue

        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            marks = [level for level in marks if level <= depth]
        i += 1

    return found


def extracted_lines() -> dict[str, set[int]]:
    """Строки исходников, литералы которых компилятор счёл ключами.

    Единственный надёжный ответ на вопрос «локализован ли этот литерал»:
    компилятор знает про `LocalizedStringKey` то, чего не знает регулярное
    выражение, — какого типа параметр, в который литерал попал.
    """
    output = subprocess.run(
        ["xcodebuild", "-project", str(ROOT / "EliteSIP.xcodeproj"),
         "-scheme", "EliteSIP", "-configuration", "Debug", "-showBuildSettings"],
        capture_output=True, text=True, cwd=ROOT,
    ).stdout
    build_root = next(
        (Path(line.split("BUILD_ROOT = ", 1)[1].strip())
         for line in output.splitlines() if "BUILD_ROOT = " in line),
        None,
    )
    if build_root is None:
        sys.exit("не удалось определить каталог сборки: нет BUILD_ROOT")

    intermediates = build_root.parent / "Intermediates.noindex"
    if not intermediates.is_dir():
        sys.exit(f"нет промежуточных файлов сборки: {intermediates}")

    lines: dict[str, set[int]] = {}
    for path in intermediates.rglob("*.stringsdata"):
        if "/EliteSIP.build/" not in str(path):
            continue
        data = json.loads(path.read_text())
        source = data.get("source", "")
        for entry in data.get("tables", {}).get("Localizable", []):
            location = entry.get("location", {})
            if "startingLine" in location:
                lines.setdefault(source, set()).add(location["startingLine"])
    return lines


def main() -> None:
    show_all = "--all" in sys.argv
    from_compiler = extracted_lines()
    debt: dict[Path, list[Literal]] = {}
    exempt_count = 0

    for root, _ in TARGETS:
        for path in sorted(root.rglob("*.swift")):
            source = path.read_text()
            lines = source.splitlines()
            # Многострочный литерал компилятор относит к строке вызова, а разбор
            # — к строке с кавычками; между ними бывает перенос, отсюда допуск.
            known = from_compiler.get(str(path), set())
            for item in literals(source):
                if not CYRILLIC.search(item.text):
                    continue
                if LOCALIZED_KEY.search(item.before):
                    continue
                if any(item.line + shift in known for shift in (-1, 0, 1)):
                    continue

                context = "\n".join(lines[max(0, item.line - 2):item.line])
                if (item.exempt
                        or JOURNAL.search(item.before)
                        or COMMENT_ARGUMENT.search(item.before)
                        or ASSERTION.search(item.before)
                        or "verbatim:" in context):
                    exempt_count += 1
                    if not show_all:
                        continue

                debt.setdefault(path.relative_to(ROOT), []).append(item)

    # Ключ есть, перевода нет — подпись останется русской при английском языке.
    untranslated: list[tuple[Path, str]] = []
    for _, catalog_path in TARGETS:
        if not catalog_path.exists():
            continue
        catalog = json.loads(catalog_path.read_text())
        for key, entry in catalog.get("strings", {}).items():
            english = entry.get("localizations", {}).get("en")
            if english is None:
                untranslated.append((catalog_path.relative_to(ROOT), key))

    total = 0
    for path, items in debt.items():
        print(f"\n{path}")
        for item in items:
            shown = item.text if len(item.text) <= 70 else item.text[:67] + "…"
            print(f"  {item.line:>4}: {shown!r}")
            total += 1

    if untranslated:
        print("\nключи без английского перевода:")
        for path, key in untranslated:
            shown = key if len(key) <= 60 else key[:57] + "…"
            print(f"  {path}: {shown!r}")

    print(f"\nбез ключа:            {total}")
    print(f"помечено:             {exempt_count}")
    print(f"без перевода на en:   {len(untranslated)}")
    sys.exit(1 if total or untranslated else 0)


if __name__ == "__main__":
    main()
