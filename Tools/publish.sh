#!/usr/bin/env bash
#
# Выкладка выпуска в канал обновлений (M7h).
#
# Отделено от Tools/release.sh намеренно. Выпуск требует ключей подписи и
# делается один раз; выкладка требует доступа к каналу и делается сколько
# угодно раз: на стенд, потом на бой, потом ещё раз после отката. Слив их в
# один скрипт означал бы пересборку ради повторной выкладки — то есть другой
# бинарь под тем же номером.
#
# Что делает:
#   1. Забирает текущий appcast канала — чтобы дописать выпуск к прежним,
#      а не затереть их.
#   2. Вклеивает запись, приготовленную release.sh (там же и подпись EdDSA).
#   3. Кладёт ZIP, DMG и обновлённый appcast в канал.
#
# Ключей подписи здесь нет и быть не должно: всё подписанное приезжает готовым.

set -euo pipefail

step() { printf '\n=== %s\n' "$1"; }
ok() { printf '  ок: %s\n' "$1"; }
die() { printf '\nПРОВАЛ: %s\n' "$1" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Использование:
  Tools/publish.sh --channel stage|prod [--from build/release] [--dry-run]

  --channel   куда выкладывать. stage — updates-stage.elitesip.vip (Caddy на
              VPS), prod — get.elitesip.vip (бакет R2 за Worker'ом).
  --from      каталог с артефактами выпуска (по умолчанию build/release).
  --dry-run   показать, что было бы сделано, и ничего не менять.

Доступы берутся из Config/publish.local.json — файла вне Git.
USAGE
}

channel=""
from_dir="build/release"
dry_run=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel) channel="${2:-}"; shift 2 ;;
        --from) from_dir="${2:-}"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "неизвестный аргумент: $1" ;;
    esac
done

[[ "$channel" == "stage" || "$channel" == "prod" ]] || { usage; die "нужен --channel stage или prod"; }
[[ -d "$from_dir" ]] || die "нет каталога с артефактами: $from_dir"

config="Config/publish.local.json"
[[ -f "$config" ]] || die "нет $config — заведите его по образцу из docs/release.md"

jget() { python3 - "$config" "$channel" "$1" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
node = cfg.get(sys.argv[2], {})
for key in sys.argv[3].split("."):
    node = (node or {}).get(key)
    if node is None:
        print("")
        break
else:
    print(node)
PY
}

base_url=$(jget baseURL)
basic_auth=$(jget basicAuth)
[[ -n "$base_url" ]] || die "в $config нет $channel.baseURL"
[[ -n "$basic_auth" ]] || die "в $config нет $channel.basicAuth"

step "Канал"
printf '  %s → %s\n' "$channel" "$base_url"
[[ $dry_run -eq 0 ]] || printf '  режим: сухой прогон, ничего не меняется\n'

# --- Что выкладываем ---------------------------------------------------------
#
# Записи appcast готовит release.sh, по одной на срез. Срез определяется именем:
# и фид, и ZIP у каждого свои, потому что Sparkle выбирать между срезами не
# умеет.

step "Артефакты"

shopt -s nullglob
items=("$from_dir"/*.item.xml)
shopt -u nullglob
(( ${#items[@]} > 0 )) || die "в $from_dir нет ни одной записи appcast (*.item.xml) — выпуск делался этим release.sh?"

# EliteSIP-0.1.20-x86_64.item.xml       → срез x86_64
# EliteSIP-0.1.20-arm64-nonotarized...  → срез arm64 (суффикс снимается первым)
label_of() {
    local name
    name=$(basename "$1" .item.xml)
    name=${name%-nonotarized}
    printf '%s' "${name##*-}"
}

for item in "${items[@]}"; do
    printf '  %s: %s\n' "$(label_of "$item")" "$(basename "$item" .item.xml)"
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- Загрузка -----------------------------------------------------------------

upload() {
    local src=$1 key=$2
    if [[ $dry_run -eq 1 ]]; then
        printf '  [сухой прогон] положил бы %s → %s\n' "$(basename "$src")" "$key"
        return 0
    fi
    case "$channel" in
        stage)
            local ssh_host ssh_key ssh_path
            ssh_host=$(jget ssh.host); ssh_key=$(jget ssh.key); ssh_path=$(jget ssh.path)
            scp -q -i "${ssh_key/#\~/$HOME}" "$src" "$ssh_host:$ssh_path/$key" \
                || die "не положилось на стенд: $key"
            ;;
        prod)
            local account bucket access secret endpoint
            account=$(jget r2.accountId); bucket=$(jget r2.bucket)
            access=$(jget r2.accessKeyId); secret=$(jget r2.secretAccessKey)
            [[ -n "$access" && -n "$secret" ]] || die "в $config не заполнены ключи R2 (prod.r2.accessKeyId / secretAccessKey)"
            endpoint="https://$account.r2.cloudflarestorage.com/$bucket/$key"
            # curl умеет подписывать по AWS SigV4 сам — отдельный клиент S3 не нужен.
            local code
            code=$(curl -s -o /dev/null -w '%{http_code}' --aws-sigv4 'aws:amz:auto:s3' \
                --user "$access:$secret" --upload-file "$src" "$endpoint")
            [[ "$code" == "200" ]] || die "R2 отверг $key: HTTP $code"
            ;;
    esac
    ok "выложено: $key"
}

# --- По каждому срезу ---------------------------------------------------------

for item in "${items[@]}"; do
    base=$(basename "$item" .item.xml)
    label=$(label_of "$item")
    appcast_name="appcast-$label.xml"

    step "[$label] Текущий appcast канала"

    current="$work/current-$label.xml"
    http_code=$(curl -s -o "$current" -w '%{http_code}' --user "$basic_auth" \
        "$base_url/$appcast_name" || echo 000)

    case "$http_code" in
        200) ok "забран, записей внутри: $(grep -c '<item>' "$current" || true)" ;;
        404) printf '  канал пуст — будет первый appcast\n'; : > "$current" ;;
        401) die "канал не пустил: проверьте basicAuth в $config" ;;
        *)   die "канал ответил HTTP $http_code — выкладывать вслепую нельзя" ;;
    esac

    step "[$label] Сборка appcast"

    merged="$work/$appcast_name"
    python3 - "$item" "$current" "$merged" "$base_url" "$label" <<'PY'
import sys, re, html

item_path, current_path, out_path, base_url, label = sys.argv[1:6]

item = open(item_path).read().replace("__BASE__", base_url)

# Номер сборки — основание решения «обновлять или нет», и он же ключ записи.
build = re.search(r"<sparkle:version>(\d+)</sparkle:version>", item)
if not build:
    sys.exit("в записи нет sparkle:version — собрать appcast нечем")
build = build.group(1)

current = open(current_path).read() if current_path else ""
old_items = re.findall(r"[ \t]*<item>.*?</item>\n?", current, re.S)

# Повторная выкладка того же номера не должна плодить вторую запись: Sparkle
# возьмёт первую попавшуюся, и какую именно — зависит от порядка.
kept = [i for i in old_items
        if re.search(r"<sparkle:version>%s</sparkle:version>" % re.escape(build), i) is None]
replaced = len(old_items) - len(kept)

body = item if item.endswith("\n") else item + "\n"
body += "".join(kept)

out = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>EliteSIP (%s)</title>
        <description>Обновления EliteSIP для среза %s</description>
        <language>ru</language>
%s    </channel>
</rss>
""" % (html.escape(label), html.escape(label), body)

open(out_path, "w").write(out)
print("  записей в новом appcast: %d%s" % (
    len(kept) + 1,
    " (запись с тем же номером сборки заменена)" if replaced else ""))
PY

    # Пустой или битый appcast — это канал, который молча перестаёт предлагать
    # обновления. Проверяем до выкладки, а не после.
    python3 -c 'import sys,xml.dom.minidom as m; m.parse(sys.argv[1])' "$merged" \
        || die "[$label] собранный appcast не разбирается как XML"
    grep -q "sparkle:edSignature" "$merged" || die "[$label] в appcast нет подписи обновления"
    ok "appcast собран и разбирается"

    step "[$label] Выкладка"

    for artifact in "$from_dir/$base.zip" "$from_dir/$base.dmg"; do
        [[ -f "$artifact" ]] || die "нет файла $artifact"
        upload "$artifact" "$(basename "$artifact")"
    done
    upload "$merged" "$appcast_name"
done

step "Готово"
printf '  канал: %s\n' "$base_url"
if [[ $dry_run -eq 1 ]]; then
    printf '  это был сухой прогон — в канале ничего не изменилось\n\n'
else
    printf '  проверить глазами:\n'
    printf '    curl -u "%s" %s/appcast-<срез>.xml\n\n' "${basic_auth%%:*}:…" "$base_url"
fi
