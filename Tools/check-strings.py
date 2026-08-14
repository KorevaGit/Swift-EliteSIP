#!/usr/bin/env python3
"""
Что из русского текста в коде не попало в каталог переводов.

Критерий этапа 8 — «ни одной русской подписи, не имеющей перевода» — глазами не
проверяется: строк под тысячу, и разбросаны они по сотне файлов. Скрипт
сравнивает два списка: русские литералы, которые есть в исходниках, и ключи,
которые лежат в `Localizable.xcstrings`. Разница — это либо забытая подпись,
либо строка, которую переводить не надо; второе помечается в самом коде.

Помечается тремя способами, все видны на месте:

  * `append(level:message:)` — строка журнала. По решению этапа 8 журнал
    остаётся техническим и не переводится: его сравнивают между машинами, а
    перевод сделал бы одно и то же событие двумя разными строками;
  * `verbatim:` у своих компонентов — текст собран в рантайме;
  * комментарий `// не переводится: причина`. Он действует до конца блока, в
    котором стоит, — иначе список из восьми отладочных макросов пришлось бы
    помечать восемь раз, и семь пометок из восьми были бы шумом.

Всё, что не помечено и не найдено в каталоге, скрипт печатает как долг.

Запуск: Tools/check-strings.py [--all]   (--all показывает и помеченные)
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "EliteSIP" / "Localizable.xcstrings"
SOURCES = [ROOT / "EliteSIP"]

CYRILLIC = re.compile(r"[А-Яа-яЁё]")
EXEMPT = re.compile(r"//\s*не переводится")
# Строка журнала: `append(level: .info, message: "…")`. Скобки в хвосте не
# допускаются намеренно — иначе выражение накрыло бы соседний вызов, стоящий
# следом за закрытой скобкой журнала. Между `message:` и литералом при этом
# бывает тернар, и его пропустить надо.
JOURNAL = re.compile(r"append\(\s*level:[^()]*message:[^()]*$")
# Пояснение переводчику в самом `NSLocalizedString` — не подпись приложения.
COMMENT_ARGUMENT = re.compile(r"comment:\s*$")
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


def main() -> None:
    catalog = json.loads(CATALOG.read_text())
    keys = {normalize(key) for key in catalog.get("strings", {})}

    show_all = "--all" in sys.argv
    debt: dict[Path, list[Literal]] = {}
    exempt_count = 0

    for root in SOURCES:
        for path in sorted(root.rglob("*.swift")):
            source = path.read_text()
            lines = source.splitlines()
            for item in literals(source):
                if not CYRILLIC.search(item.text):
                    continue
                if normalize(item.text) in keys:
                    continue

                context = "\n".join(lines[max(0, item.line - 2):item.line])
                if (item.exempt
                        or JOURNAL.search(item.before)
                        or COMMENT_ARGUMENT.search(item.before)
                        or "verbatim:" in context):
                    exempt_count += 1
                    if not show_all:
                        continue

                debt.setdefault(path.relative_to(ROOT), []).append(item)

    total = 0
    for path, items in debt.items():
        print(f"\n{path}")
        for item in items:
            shown = item.text if len(item.text) <= 70 else item.text[:67] + "…"
            print(f"  {item.line:>4}: {shown!r}")
            total += 1

    print(f"\nбез перевода:  {total}")
    print(f"помечено:      {exempt_count}")
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
