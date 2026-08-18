#!/bin/bash
#
# Выпуск EliteSIP одной командой: версия, сборка, подпись, проверки, DMG,
# нотарификация, степлинг. M7e, пункт 6.
#
# Ручной выпуск из десяти шагов рано или поздно выпускается без одного из них, и
# обычно это степлинг: без прикреплённого билета Gatekeeper идёт к Apple по
# сети, а удалённые сотрудники сидят за L2TP, и что там с исходящим доступом к
# серверам Apple — неизвестно. Заметит это не тот, кто выпускал.
#
# Разбор того, что именно проверяет Gatekeeper и почему шаги стоят в таком
# порядке, — docs/release.md. Здесь только исполнение.
#
# Пример:
#
#   Tools/release.sh --bump patch \
#       --identity "Developer ID Application: ООО ... (TEAMID1234)" \
#       --team TEAMID1234 \
#       --notary-profile elitesip
#
# Учётные данные нотарификации берутся из профиля связки ключей, заведённого
# один раз:
#
#   xcrun notarytool store-credentials elitesip \
#       --apple-id … --team-id … --password <пароль приложения>
#
# В командную строку они не попадают намеренно: `ps` видно всем, а история
# оболочки переживает выпуск.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# --- Разбор аргументов -------------------------------------------------------

identity="${ELITESIP_SIGN_IDENTITY:-}"
team="${ELITESIP_TEAM_ID:-}"
notary_profile="${ELITESIP_NOTARY_PROFILE:-}"
version=""
bump=""
run_checks=1
allow_dirty=0
output_dir="build/release"

usage() {
    cat <<'USAGE'
Tools/release.sh — выпуск целиком.

  --identity <имя>        Developer ID Application из связки ключей.
                          Или переменная ELITESIP_SIGN_IDENTITY.
  --team <TEAMID>         Team ID. Или ELITESIP_TEAM_ID.
  --notary-profile <имя>  Профиль notarytool. Или ELITESIP_NOTARY_PROFILE.
  --version <X.Y.Z>       Поставить эту версию.
  --bump patch|minor|major
                          Поднять версию саму. Номер сборки растёт всегда.
  --skip-checks           Не гонять Tools/check-compat.sh (тесты и совместимость).
  --allow-dirty           Выпустить из дерева с незакоммиченными правками.
  --output <каталог>      Куда положить DMG. По умолчанию build/release.
  -h, --help              Это сообщение.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) identity="${2:-}"; shift 2 ;;
        --team) team="${2:-}"; shift 2 ;;
        --notary-profile) notary_profile="${2:-}"; shift 2 ;;
        --version) version="${2:-}"; shift 2 ;;
        --bump) bump="${2:-}"; shift 2 ;;
        --skip-checks) run_checks=0; shift ;;
        --allow-dirty) allow_dirty=1; shift ;;
        --output) output_dir="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Неизвестный аргумент: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

step() { printf '\n=== %s\n' "$1"; }
ok() { printf '  ок: %s\n' "$1"; }
die() { printf '\nПРОВАЛ: %s\n' "$1" >&2; exit 1; }

# --- Предполётные проверки ---------------------------------------------------
#
# Все они стоят до сборки не из аккуратности: сборка с прогоном тестов идёт
# минуты, и узнавать на восьмом шаге, что профиля нотарификации нет, дорого.

step "Предполётные проверки"

[[ -n "$identity" ]] || die "не задан Developer ID (--identity). Выпуск без подписи запрещён: Gatekeeper такую сборку на чужой машине не откроет, а обновлять её потом нечем."
[[ -n "$team" ]] || die "не задан Team ID (--team). Без него подпись без Team ID, и нотарификация её не примет."
[[ -n "$notary_profile" ]] || die "не задан профиль notarytool (--notary-profile). Нотарификация обязательна начиная с macOS 10.15 — то есть на всём нашем диапазоне."

if ! security find-identity -v -p codesigning | grep -qF "$identity"; then
    die "сертификата «$identity» нет в связке ключей. Список: security find-identity -v -p codesigning"
fi
ok "сертификат найден"

case "$identity" in
    "Developer ID Application:"*) ok "тип сертификата верный" ;;
    *) die "«$identity» — не Developer ID Application. Apple Development и Mac App Distribution для раздачи вне App Store не годятся." ;;
esac

if ! security find-generic-password -s "com.apple.gke.notary.tool" -a "$notary_profile" >/dev/null 2>&1; then
    die "профиля notarytool «$notary_profile» нет в связке ключей. Завести: xcrun notarytool store-credentials $notary_profile"
fi
ok "профиль нотарификации найден"

[[ -f Config/provisioning.local.json ]] || die "нет Config/provisioning.local.json — выпуск без административного пароля и заводской предустановки запрещён (M7e, пункт 7)."
ok "конфиг провижининга на месте"

for tool in xcodebuild codesign hdiutil lipo vtool ditto; do
    command -v "$tool" >/dev/null 2>&1 || die "нет инструмента $tool"
done
xcrun --find notarytool >/dev/null 2>&1 || die "нет notarytool"
xcrun --find stapler >/dev/null 2>&1 || die "нет stapler"
ok "инструменты на месте"

if [[ $allow_dirty -eq 0 ]] && [[ -n "$(git status --porcelain)" ]]; then
    die "в дереве незакоммиченные правки. Выпуск из такого дерева невоспроизводим: по номеру версии потом не найти код. Либо закоммитить, либо --allow-dirty."
fi

# --- Версия ------------------------------------------------------------------

step "Версия"

version_file="Config/Version.xcconfig"
current_version=$(awk -F'= *' '/^MARKETING_VERSION/ {print $2}' "$version_file" | tr -d ' ')
current_build=$(awk -F'= *' '/^CURRENT_PROJECT_VERSION/ {print $2}' "$version_file" | tr -d ' ')
[[ -n "$current_version" && -n "$current_build" ]] || die "не прочитал версию из $version_file"

if [[ -n "$bump" ]]; then
    [[ -z "$version" ]] || die "--version и --bump вместе не работают: непонятно, что победит."
    IFS=. read -r major minor patch <<<"$current_version"
    case "$bump" in
        major) version="$((major + 1)).0.0" ;;
        minor) version="$major.$((minor + 1)).0" ;;
        patch) version="$major.$minor.$((patch + 1))" ;;
        *) die "--bump принимает patch, minor или major" ;;
    esac
fi

[[ -n "$version" ]] || version="$current_version"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "версия «$version» не вида X.Y.Z"

# Номер сборки растёт всегда, даже если человеческая версия та же. Именно он
# отличает две сборки одной версии, и именно его сравнивает Sparkle (M7h).
build_number=$((current_build + 1))

# Возврат правкой тех же двух строк, а не заменой файла: комментарии в нём
# длиннее самих значений и терять их нельзя.
restore_version() {
    /usr/bin/sed -i '' \
        -e "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $current_version/" \
        -e "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $current_build/" \
        "$version_file"
}

/usr/bin/sed -i '' \
    -e "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $version/" \
    -e "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $build_number/" \
    "$version_file"
ok "$current_version ($current_build) → $version ($build_number)"

# Дальше любой обрыв возвращает версию на место: наполовину поднятый номер в
# рабочем дереве — это следующий выпуск с чужим номером.
trap 'printf "\nВыпуск прерван, версия возвращена на %s (%s).\n" "$current_version" "$current_build" >&2; restore_version' ERR INT TERM

# --- Тесты и совместимость ---------------------------------------------------

if [[ $run_checks -eq 1 ]]; then
    step "Тесты и совместимость (Tools/check-compat.sh)"
    if ! Tools/check-compat.sh; then
        restore_version
        die "проверки совместимости не прошли — выпускать нечего."
    fi
    ok "проверки прошли"
else
    step "Тесты и совместимость пропущены (--skip-checks)"
fi

# --- Сборка ------------------------------------------------------------------

step "Сборка Release universal"

derived="build/release-dd"
rm -rf "$derived"
if ! xcodebuild -project EliteSIP.xcodeproj -scheme EliteSIP -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
    ONLY_ACTIVE_ARCH=NO ARCHS="x86_64 arm64" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$identity" \
    DEVELOPMENT_TEAM="$team" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
    build > "$derived.log" 2>&1; then
    restore_version
    die "сборка не удалась, журнал: $derived.log"
fi

app="$derived/Build/Products/Release/EliteSIP.app"
[[ -d "$app" ]] || { restore_version; die "не нашёл собранный бандл"; }
ok "собрано: $app"

# --- Подпись -----------------------------------------------------------------
#
# Снизу вверх: подпись бандла считает хеши вложенного, и библиотека,
# переподписанная после бандла, ломает подпись целиком.
#
# Вложенное переподписывается даже после сборки с настоящим сертификатом:
# libswift_Concurrency кладёт туда CopySwiftLibs своей подписью, и флага
# runtime на ней исторически не бывает. Нотарификация требует Hardened Runtime у
# всего исполняемого содержимого бандла — это одна из самых частых причин отказа.

step "Подпись"

while IFS= read -r -d '' nested; do
    codesign --force --sign "$identity" --options runtime --timestamp "$nested" 2>/dev/null \
        || { restore_version; die "не подписалось вложенное: $nested"; }
    ok "вложенное подписано: $(basename "$nested")"
done < <(find "$app/Contents/Frameworks" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null)

codesign --force --sign "$identity" --options runtime --timestamp \
    --entitlements Config/EliteSIP.entitlements "$app" \
    || { restore_version; die "не подписался бандл"; }
ok "бандл подписан"

# --- Проверки подписи --------------------------------------------------------
#
# Каждая из них — это отказ нотарификации, узнанный за секунду вместо часа
# ожидания вердикта Apple.

step "Проверки подписи"

codesign --verify --deep --strict --verbose=2 "$app" 2>/dev/null \
    || { restore_version; die "подпись не проходит проверку"; }
ok "подпись целостна"

if codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q "get-task-allow"; then
    restore_version
    die "в подписи осталось com.apple.security.get-task-allow — нотарификация такой бинарь отклонит."
fi
ok "отладочного права get-task-allow нет"

signature_info=$(codesign -dvvv "$app" 2>&1)
grep -q "flags=.*runtime" <<<"$signature_info" || { restore_version; die "у бандла нет флага runtime"; }
grep -q "TeamIdentifier=$team" <<<"$signature_info" || { restore_version; die "в подписи не тот Team ID (ждали $team)"; }
grep -q "Timestamp=" <<<"$signature_info" || { restore_version; die "в подписи нет защищённой метки времени"; }
ok "runtime, Team ID и метка времени на месте"

while IFS= read -r -d '' nested; do
    codesign -dvv "$nested" 2>&1 | grep -q "flags=.*runtime" \
        || { restore_version; die "у вложенного $(basename "$nested") нет флага runtime"; }
done < <(find "$app/Contents/Frameworks" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null)
ok "у вложенного тоже runtime"

# --- Проверки содержимого ----------------------------------------------------

step "Проверки бандла"

binary="$app/Contents/MacOS/EliteSIP"
architectures=$(lipo -archs "$binary")
for arch in x86_64 arm64; do
    [[ " $architectures " == *" $arch "* ]] || { restore_version; die "нет среза $arch (есть: $architectures)"; }
done
ok "срезы: $architectures"

check_minos() {
    local arch=$1 expected=$2 actual
    actual=$(vtool -arch "$arch" -show-build-version "$binary" 2>/dev/null | awk '/minos/ {print $2}')
    [[ "$actual" == "$expected" ]] || { restore_version; die "$arch: minos $actual вместо $expected"; }
}
check_minos x86_64 10.15
check_minos arm64 11.0
ok "нижние планки: 10.15 для x86_64, 11.0 для arm64"

[[ -f "$app/Contents/Frameworks/libswift_Concurrency.dylib" ]] \
    || { restore_version; die "libswift_Concurrency не вложен — на Catalina приложение не запустится вовсе"; }
ok "libswift_Concurrency вложен"

[[ -f "$app/Contents/Resources/provisioning.json" ]] \
    || { restore_version; die "в бандле нет provisioning.json — машины из такого выпуска встанут с «Управлением», открытым всякому"; }
ok "конфиг провижининга в бандле"

bundle_version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
bundle_build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$app/Contents/Info.plist")
[[ "$bundle_version" == "$version" && "$bundle_build" == "$build_number" ]] \
    || { restore_version; die "в бандле версия $bundle_version ($bundle_build), а выпускаем $version ($build_number)"; }
ok "версия в бандле сходится: $bundle_version ($bundle_build)"

# --- Нотарификация приложения ------------------------------------------------
#
# Отправок две, и обе нужны. Билет прикрепляется к тому файлу, который
# отправляли: степлинг DMG не кладёт билет внутрь приложения, а приложение
# переживает свой DMG — его копируют, переносят и восстанавливают из архива.

step "Нотарификация приложения"

mkdir -p "$output_dir"
app_zip="$output_dir/EliteSIP-$version.zip"
rm -f "$app_zip"
ditto -c -k --keepParent "$app" "$app_zip" || { restore_version; die "не собрался архив для нотарификации"; }

if ! xcrun notarytool submit "$app_zip" --keychain-profile "$notary_profile" --wait; then
    restore_version
    die "нотарификация приложения не прошла. Подробности: xcrun notarytool log <id> --keychain-profile $notary_profile"
fi
xcrun stapler staple "$app" || { restore_version; die "не прикрепился билет к приложению"; }
rm -f "$app_zip"
ok "приложение нотарифицировано и заштемпелёвано"

# --- DMG ---------------------------------------------------------------------

step "DMG"

dmg="$output_dir/EliteSIP-$version.dmg"
staging="$output_dir/staging"
rm -rf "$staging" "$dmg"
mkdir -p "$staging"
ditto "$app" "$staging/EliteSIP.app" || { restore_version; die "не скопировалось приложение в образ"; }
ln -s /Applications "$staging/Applications"

hdiutil create -volname "EliteSIP" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null \
    || { restore_version; die "не собрался DMG"; }
rm -rf "$staging"

codesign --force --sign "$identity" --timestamp "$dmg" || { restore_version; die "не подписался DMG"; }
ok "образ собран и подписан: $dmg"

step "Нотарификация DMG"
if ! xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait; then
    restore_version
    die "нотарификация DMG не прошла. Подробности: xcrun notarytool log <id> --keychain-profile $notary_profile"
fi
xcrun stapler staple "$dmg" || { restore_version; die "не прикрепился билет к DMG"; }
xcrun stapler validate "$dmg" || { restore_version; die "билет на DMG не проверяется"; }
ok "DMG нотарифицирован и заштемпелёван"

trap - ERR INT TERM

# --- Итог --------------------------------------------------------------------

step "Готово"
printf '  версия:   %s (%s)\n' "$version" "$build_number"
printf '  образ:    %s\n' "$dmg"
printf '  размер:   %s\n' "$(du -h "$dmg" | cut -f1)"
printf '  SHA-256:  %s\n' "$(shasum -a 256 "$dmg" | cut -d' ' -f1)"

cat <<'REMINDER'

Что осталось сделать руками:

  1. Закоммитить Config/Version.xcconfig и поставить метку версии:
     git commit -am "Выпуск X.Y.Z" && git tag vX.Y.Z
  2. Проверить образ на ЧИСТОЙ машине с включёнными проверками
     (`spctl --status` → assessments enabled) и с карантином:
     xattr -w com.apple.quarantine "0081;00000000;Safari;" /путь/EliteSIP.app
     На машине сборки проверка Gatekeeper не доказывает ничего: при
     выключенных проверках spctl принимает что угодно, включая ad-hoc.
  3. Открыть образ без сети — это и есть доказательство степлинга.

Полный чек-лист приёмки — docs/release.md.
REMINDER
