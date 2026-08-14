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
    остаётся техническим и не переводится: он сравнивается между машинами, а
    перевод сделал бы одно и то же событие двумя разными строками;
  * `verbatim:` у своих компонентов — текст собран в рантайме;
  * комментарий `// не переводится: причина` на строке или строкой выше.

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
# Строка журнала: `append(level: .info, message: "…")`. Литерал стоит сразу за
# `message:`, поэтому хватает взгляда на то, что ему предшествует.
JOURNAL = re.compile(r"append\(\s*level:[^()]*message:\s*$")
# Форматные вставки, которыми компилятор заменяет интерполяцию в ключе.
FORMAT = re.compile(r"%(?:\d+\$)?[-+ #0]*[\d.*]*(?:l{0,2}|h{0,2}|z|j|t|L|q)[@dioux XeEfgGcsp%]")
INTERPOLATION = re.compile(r"\\\([^()]*(?:\([^()]*\)[^()]*)*\)")


def normalize(text: str) -> str:
    """Ключ и литерал сходятся, если совпадают вне переменной части."""
    text = INTERPOLATION.sub("\0", text)
    text = FORMAT.sub("\0", text)
    return re.sub(r"\s+", " ", text).strip()


def literals(source: str) -> list[tuple[int, str, str]]:
    """Строковые литералы файла: номер строки, содержимое и код перед ним.

    Свой разбор, а не регулярное выражение на всё сразу: в проекте есть и
    многострочные литералы с переносом по обратному слэшу, и интерполяция с
    вложенными кавычками — на них однострочный шаблон врёт в обе стороны.
    """
    found: list[tuple[int, str]] = []
    i, line, length = 0, 1, len(source)

    def preceding(position: int) -> str:
        """Хвост кода перед литералом, склеенный в одну строку."""
        return re.sub(r"\s+", " ", source[max(0, position - 200):position])

    while i < length:
        char = source[i]

        if char == "\n":
            line += 1
            i += 1
            continue

        # Комментарии пропускаем целиком: кавычки внутри них не литералы.
        if source.startswith("//", i):
            end = source.find("\n", i)
            i = length if end < 0 else end
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
            body = re.sub(r"\\\n\s*", "", body)
            found.append((start_line, body, preceding(i)))
            i = end + 3
            continue

        if char == '"':
            start_line = line
            j, body = i + 1, []
            while j < length and source[j] != '"':
                if source[j] == "\\" and j + 1 < length:
                    body.append(source[j:j + 2])
                    j += 2
                    continue
                if source[j] == "\n":
                    break
                body.append(source[j])
                j += 1
            found.append((start_line, "".join(body), preceding(i)))
            i = j + 1
            continue

        i += 1

    return found


def main() -> None:
    catalog = json.loads(CATALOG.read_text())
    keys = {normalize(key) for key in catalog.get("strings", {})}

    show_all = "--all" in sys.argv
    debt: dict[Path, list[tuple[int, str]]] = {}
    exempt_count = 0

    for root in SOURCES:
        for path in sorted(root.rglob("*.swift")):
            source = path.read_text()
            lines = source.splitlines()
            for number, text, before in literals(source):
                if not CYRILLIC.search(text):
                    continue
                if normalize(text) in keys:
                    continue

                context = "\n".join(lines[max(0, number - 2):number])
                if JOURNAL.search(before) or EXEMPT.search(context) or "verbatim:" in context:
                    exempt_count += 1
                    if not show_all:
                        continue

                debt.setdefault(path.relative_to(ROOT), []).append((number, text))

    total = 0
    for path, items in debt.items():
        print(f"\n{path}")
        for number, text in items:
            shown = text if len(text) <= 70 else text[:67] + "…"
            print(f"  {number:>4}: {shown!r}")
            total += 1

    print(f"\nбез перевода:  {total}")
    print(f"помечено:      {exempt_count}")
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
