#!/bin/bash
#
# Шаг сборки: вшить конфиг с секретами в бандл. M7e, пункт 7.
#
# Административный пароль и код восстановления лежат в
# `Config/provisioning.local.json` — вне Git (`*.local.json` в `.gitignore`).
# Отсюда они попадают в ресурсы бандла под именем `provisioning.json`, откуда
# их читает `Provisioning.secrets`.
#
# Главное правило, ради которого скрипт и написан: **Release без этого файла
# обязан уронить сборку.** Такой выпуск внешне рабочий, но каждая машина из него
# встаёт с «Управлением», открытым любому оператору, и заметить это можно только
# на рабочем месте. Тихое умолчание здесь дороже сорванной сборки.
#
# Debug ведёт себя наоборот: файла в бандле нет вовсе, а `Provisioning` в
# отладке читает его прямо из дерева проекта (путь от `#filePath`). Так
# отладочная сборка остаётся проходимой на любой машине, включая чужую и CI, где
# конфига нет и быть не должно.
#
# Вызывается фазой «Провижининг» цели EliteSIP; руками запускать незачем.

set -euo pipefail

source_config="$SRCROOT/Config/provisioning.local.json"
bundle_config="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/provisioning.json"

if [[ "$CONFIGURATION" != "Release" ]]; then
    # Отладка: убрать копию, оставшуюся от прежней релизной сборки в том же
    # каталоге продуктов, иначе она переживёт переключение конфигурации и будет
    # молча подсовывать боевой пароль.
    rm -f "$bundle_config"
    exit 0
fi

if [[ ! -f "$source_config" ]]; then
    echo "error: нет Config/provisioning.local.json — релизная сборка без административного пароля и заводской предустановки запрещена (M7e, пункт 7)." >&2
    echo "note: файл не лежит в Git намеренно. Возьмите его у того, кто выпускает сборки, или соберите Debug." >&2
    exit 1
fi

# Проверка содержимого, а не только наличия: пустой или недописанный файл
# декодируется в `nil`, и приложение опять встанет без пароля — то же самое, от
# чего защищает проверка выше, только незаметнее. `plutil -lint` для этого не
# годится: JSON он с ходу не разбирает, о чём сообщает как о синтаксической
# ошибке в исправном файле.
if ! /usr/bin/python3 - "$source_config" <<'PYEOF'
import json, sys

try:
    config = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as error:
    sys.exit(f"не разбираемый JSON: {error}")

for key in ("adminPassword", "recoveryCode"):
    if not str(config.get(key, "")).strip():
        sys.exit(f"пустой или отсутствующий ключ «{key}»")

# Канал обновлений (M7h). Проверяется так же строго, и по той же причине:
# сборка без него внешне рабочая, но обновлять её нечем — а обязанность
# обновляться и есть смысл всего этапа. Заметить пропажу иначе можно только
# на рабочем месте и только тогда, когда выйдет следующая версия.
updates = config.get("updates") or {}
if not isinstance(updates, dict):
    sys.exit("ключ «updates» должен быть объектом")
for key in ("baseURL", "user", "password"):
    if not str(updates.get(key, "")).strip():
        sys.exit(f"пустой или отсутствующий ключ «updates.{key}»")
PYEOF
then
    echo "error: Config/provisioning.local.json непригоден — подробность строкой выше." >&2
    exit 1
fi

mkdir -p "$(dirname "$bundle_config")"
cp "$source_config" "$bundle_config"
