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
# Настоящий выпуск:
#
#   Tools/release.sh --bump patch \
#       --identity "Developer ID Application: ООО ... (TEAMID1234)" \
#       --team TEAMID1234 \
#       --notary-profile elitesip
#
# Пока учётной записи Apple Developer нет — своя подпись, без нотарификации:
#
#   Tools/release.sh --self-signed --identity "EliteSIP Self-Signed" --bump patch
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
arch_choice="both"
self_signed=0
run_checks=1
allow_dirty=0
output_dir="build/release"

usage() {
    cat <<'USAGE'
Tools/release.sh — выпуск целиком.

  --identity <имя>        Сертификат из связки ключей.
                          Или переменная ELITESIP_SIGN_IDENTITY.
  --team <TEAMID>         Team ID. Или ELITESIP_TEAM_ID. Не нужен при
                          --self-signed.
  --notary-profile <имя>  Профиль notarytool. Или ELITESIP_NOTARY_PROFILE.
                          Не нужен при --self-signed.
  --self-signed           Подписать своим сертификатом и НЕ нотарифицировать.
                          Такой выпуск Gatekeeper не проходит — см. ниже.
  --arch <что>            both (по умолчанию) — две отдельные сборки, x86_64 и
                          arm64; либо x86_64, либо arm64, либо universal —
                          один бандл с обоими срезами.
  --version <X.Y.Z>       Поставить эту версию.
  --bump patch|minor|major
                          Поднять версию саму. Номер сборки растёт всегда.
  --skip-checks           Не гонять Tools/check-compat.sh (тесты и совместимость).
  --allow-dirty           Выпустить из дерева с незакоммиченными правками.
  --output <каталог>      Куда положить образы. По умолчанию build/release.
  -h, --help              Это сообщение.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) identity="${2:-}"; shift 2 ;;
        --team) team="${2:-}"; shift 2 ;;
        --notary-profile) notary_profile="${2:-}"; shift 2 ;;
        --self-signed) self_signed=1; shift ;;
        --arch) arch_choice="${2:-}"; shift 2 ;;
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

# Отдельные сборки против одной universal.
#
# По умолчанию собираются две: x86_64 и arm64 порознь. Каждая вдвое легче
# universal, и на рабочее место приезжает только то, что там исполняется.
# Цена — выбор при раздаче: срез выбирает человек, а не система, и Intel-сборка,
# принесённая на Apple Silicon, поедет через Rosetta (если он вообще
# установлен), то есть тише и с другой задержкой звука. Для софтфона это не
# мелочь, поэтому имя среза стоит прямо в имени образа.
case "$arch_choice" in
    both) targets=(x86_64 arm64) ;;
    x86_64) targets=(x86_64) ;;
    arm64) targets=(arm64) ;;
    universal) targets=(universal) ;;
    *) die "--arch принимает both, x86_64, arm64 или universal" ;;
esac

# --- Предполётные проверки ---------------------------------------------------
#
# Все они стоят до сборки не из аккуратности: сборка с прогоном тестов идёт
# минуты, и узнавать на восьмом шаге, что профиля нотарификации нет, дорого.

step "Предполётные проверки"

[[ -n "$identity" ]] || die "не задан сертификат (--identity). Выпуск без подписи запрещён: у ad-hoc сборки подпись меняется при каждой пересборке, и для связки ключей и TCC это каждый раз новое приложение."

if ! security find-identity -v -p codesigning | grep -qF "$identity"; then
    die "сертификата «$identity» нет в связке ключей. Список: security find-identity -v -p codesigning. Свой сертификат заводится Tools/make-selfsigned-cert.sh"
fi
ok "сертификат найден"

if [[ $self_signed -eq 1 ]]; then
    case "$identity" in
        "Developer ID Application:"*)
            die "с настоящим Developer ID флаг --self-signed бессмыслен: сборку надо нотарифицировать, иначе Gatekeeper её всё равно не пустит." ;;
    esac
    [[ -z "$team" ]] || die "--team при --self-signed не работает: Team ID выдаёт Apple вместе с учётной записью."
    ok "режим своей подписи: нотарификации не будет"
else
    [[ -n "$team" ]] || die "не задан Team ID (--team). Без него подпись без Team ID, и нотарификация её не примет. Если сертификат свой, а не от Apple, нужен флаг --self-signed."
    [[ -n "$notary_profile" ]] || die "не задан профиль notarytool (--notary-profile). Нотарификация обязательна начиная с macOS 10.15 — то есть на всём нашем диапазоне."

    case "$identity" in
        "Developer ID Application:"*) ok "тип сертификата верный" ;;
        *) die "«$identity» — не Developer ID Application. Apple Development и Mac App Distribution для раздачи вне App Store не годятся, а свой сертификат требует флага --self-signed." ;;
    esac

    if ! security find-generic-password -s "com.apple.gke.notary.tool" -a "$notary_profile" >/dev/null 2>&1; then
        die "профиля notarytool «$notary_profile» нет в связке ключей. Завести: xcrun notarytool store-credentials $notary_profile"
    fi
    ok "профиль нотарификации найден"
fi

[[ -f Config/provisioning.local.json ]] || die "нет Config/provisioning.local.json — выпуск без административного пароля и заводской предустановки запрещён (M7e, пункт 7)."
ok "конфиг провижининга на месте"

for tool in xcodebuild codesign hdiutil lipo vtool ditto; do
    command -v "$tool" >/dev/null 2>&1 || die "нет инструмента $tool"
done
if [[ $self_signed -eq 0 ]]; then
    xcrun --find notarytool >/dev/null 2>&1 || die "нет notarytool"
    xcrun --find stapler >/dev/null 2>&1 || die "нет stapler"
fi
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
#
# Срезы одной версии номер делят: это одно и то же приложение, собранное под две
# машины, а не два разных выпуска.
build_number=$((current_build + 1))

# Возврат правкой тех же двух строк, а не заменой файла: комментарии в нём
# длиннее самих значений и терять их нельзя.
restore_version() {
    /usr/bin/sed -i '' \
        -e "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $current_version/" \
        -e "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $current_build/" \
        "$version_file"
}

fail() { restore_version; die "$1"; }

/usr/bin/sed -i '' \
    -e "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $version/" \
    -e "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $build_number/" \
    "$version_file"
ok "$current_version ($current_build) → $version ($build_number)"

# Дальше любой обрыв возвращает версию на место: наполовину поднятый номер в
# рабочем дереве — это следующий выпуск с чужим номером.
trap 'printf "\nВыпуск прерван, версия возвращена на %s (%s).\n" "$current_version" "$current_build" >&2; restore_version' INT TERM

# --- Тесты и совместимость ---------------------------------------------------

if [[ $run_checks -eq 1 ]]; then
    step "Тесты и совместимость (Tools/check-compat.sh)"
    Tools/check-compat.sh || fail "проверки совместимости не прошли — выпускать нечего."
    ok "проверки прошли"
else
    step "Тесты и совместимость пропущены (--skip-checks)"
fi

mkdir -p "$output_dir"
artifacts=()

# --- Сборка, подпись и упаковка одного среза ---------------------------------

release_one() {
    local target=$1
    local archs label
    case "$target" in
        universal) archs="x86_64 arm64"; label="universal" ;;
        *) archs="$target"; label="$target" ;;
    esac

    step "[$label] Сборка Release"

    local derived="build/release-dd-$label"
    rm -rf "$derived"

    # Метка времени просится у сервера Apple и нужна нотарификации: без неё
    # подпись считается непроверяемой. Своей подписи она не нужна и только
    # ставит выпуск в зависимость от сети.
    local sign_flags="--options runtime"
    [[ $self_signed -eq 1 ]] || sign_flags="--timestamp $sign_flags"

    local -a build_args=(
        -project EliteSIP.xcodeproj -scheme EliteSIP -configuration Release
        -destination 'generic/platform=macOS' -derivedDataPath "$derived"
        ONLY_ACTIVE_ARCH=NO "ARCHS=$archs"
        CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity"
        "OTHER_CODE_SIGN_FLAGS=$sign_flags"
    )
    [[ -z "$team" ]] || build_args+=("DEVELOPMENT_TEAM=$team")

    xcodebuild "${build_args[@]}" build > "$derived.log" 2>&1 \
        || fail "[$label] сборка не удалась, журнал: $derived.log"

    local app="$derived/Build/Products/Release/EliteSIP.app"
    [[ -d "$app" ]] || fail "[$label] не нашёл собранный бандл"
    ok "собрано: $app"

    # --- Подпись ---
    #
    # Снизу вверх: подпись бандла считает хеши вложенного, и библиотека,
    # переподписанная после бандла, ломает подпись целиком.
    #
    # Вложенное переподписывается даже после сборки с настоящим сертификатом:
    # libswift_Concurrency кладёт туда CopySwiftLibs своей подписью, и флага
    # runtime на ней исторически не бывает. Нотарификация требует Hardened
    # Runtime у всего исполняемого содержимого бандла — это одна из самых частых
    # причин отказа.

    step "[$label] Подпись"

    local nested
    while IFS= read -r -d '' nested; do
        codesign --force --sign "$identity" $sign_flags "$nested" 2>/dev/null \
            || fail "[$label] не подписалось вложенное: $nested"
        ok "вложенное подписано: $(basename "$nested")"
    done < <(find "$app/Contents/Frameworks" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null)

    codesign --force --sign "$identity" $sign_flags \
        --entitlements Config/EliteSIP.entitlements "$app" \
        || fail "[$label] не подписался бандл"
    ok "бандл подписан"

    # --- Проверки подписи ---
    #
    # Каждая из них — это отказ нотарификации, узнанный за секунду вместо часа
    # ожидания вердикта Apple.

    step "[$label] Проверки подписи"

    codesign --verify --deep --strict --verbose=2 "$app" 2>/dev/null \
        || fail "[$label] подпись не проходит проверку"
    ok "подпись целостна"

    # Вывод сперва в переменную, и так везде ниже. Труба здесь была бы ловушкой:
    # при `pipefail` нашедший `grep -q` закрывает трубу, `codesign` получает
    # SIGPIPE, и весь конвейер возвращает ошибку — то есть находка теряется
    # ровно тогда, когда она есть. Проверка, которая молчит при попадании, хуже
    # отсутствующей.
    local entitlements
    entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null)
    if grep -q "get-task-allow" <<<"$entitlements"; then
        fail "[$label] в подписи осталось com.apple.security.get-task-allow — нотарификация такой бинарь отклонит."
    fi
    ok "отладочного права get-task-allow нет"

    local signature_info
    signature_info=$(codesign -dvvv "$app" 2>&1)
    grep -q "flags=.*runtime" <<<"$signature_info" || fail "[$label] у бандла нет флага runtime"
    if [[ $self_signed -eq 0 ]]; then
        grep -q "TeamIdentifier=$team" <<<"$signature_info" || fail "[$label] в подписи не тот Team ID (ждали $team)"
        grep -q "Timestamp=" <<<"$signature_info" || fail "[$label] в подписи нет защищённой метки времени"
        ok "runtime, Team ID и метка времени на месте"
    else
        ok "runtime на месте"
    fi

    local nested_info
    while IFS= read -r -d '' nested; do
        nested_info=$(codesign -dvv "$nested" 2>&1)
        grep -q "flags=.*runtime" <<<"$nested_info" \
            || fail "[$label] у вложенного $(basename "$nested") нет флага runtime"
    done < <(find "$app/Contents/Frameworks" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null)
    ok "у вложенного тоже runtime"

    # --- Проверки бандла ---

    step "[$label] Проверки бандла"

    local binary="$app/Contents/MacOS/EliteSIP"
    local architectures
    architectures=$(lipo -archs "$binary")
    local arch
    for arch in $archs; do
        [[ " $architectures " == *" $arch "* ]] || fail "[$label] нет среза $arch (есть: $architectures)"
    done
    # Отдельная сборка обязана быть именно отдельной: лишний срез — это вдвое
    # больший образ, ради которого всё и разделено.
    if [[ "$target" != "universal" ]]; then
        [[ "$architectures" == "$target" ]] || fail "[$label] в бинаре лишние срезы: $architectures"
    fi
    ok "срезы: $architectures"

    check_minos() {
        local arch=$1 expected=$2 actual
        actual=$(vtool -arch "$arch" -show-build-version "$binary" 2>/dev/null | awk '/minos/ {print $2}')
        [[ "$actual" == "$expected" ]] || fail "[$label] $arch: minos $actual вместо $expected"
    }
    [[ "$architectures" != *x86_64* ]] || { check_minos x86_64 10.15; ok "x86_64: minos 10.15"; }
    [[ "$architectures" != *arm64* ]] || { check_minos arm64 11.0; ok "arm64: minos 11.0"; }

    [[ ! " $archs " == *" x86_64 "* ]] || [[ -f "$app/Contents/Frameworks/libswift_Concurrency.dylib" ]] \
        || fail "[$label] libswift_Concurrency не вложен — на Catalina приложение не запустится вовсе"

    [[ -f "$app/Contents/Resources/provisioning.json" ]] \
        || fail "[$label] в бандле нет provisioning.json — машины из такого выпуска встанут с «Управлением», открытым всякому"
    ok "конфиг провижининга в бандле"

    local bundle_version bundle_build
    bundle_version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
    bundle_build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$app/Contents/Info.plist")
    [[ "$bundle_version" == "$version" && "$bundle_build" == "$build_number" ]] \
        || fail "[$label] в бандле версия $bundle_version ($bundle_build), а выпускаем $version ($build_number)"
    ok "версия в бандле сходится: $bundle_version ($bundle_build)"

    # --- Нотарификация приложения ---
    #
    # Отправок две, и обе нужны. Билет прикрепляется к тому файлу, который
    # отправляли: степлинг DMG не кладёт билет внутрь приложения, а приложение
    # переживает свой DMG — его копируют, переносят и восстанавливают из архива.

    local suffix=""
    [[ $self_signed -eq 0 ]] || suffix="-nonotarized"

    if [[ $self_signed -eq 0 ]]; then
        step "[$label] Нотарификация приложения"
        local app_zip="$output_dir/EliteSIP-$version-$label.zip"
        rm -f "$app_zip"
        ditto -c -k --keepParent "$app" "$app_zip" || fail "[$label] не собрался архив для нотарификации"
        xcrun notarytool submit "$app_zip" --keychain-profile "$notary_profile" --wait \
            || fail "[$label] нотарификация приложения не прошла. Подробности: xcrun notarytool log <id> --keychain-profile $notary_profile"
        xcrun stapler staple "$app" || fail "[$label] не прикрепился билет к приложению"
        rm -f "$app_zip"
        ok "приложение нотарифицировано и заштемпелёвано"
    fi

    # --- DMG ---

    step "[$label] DMG"

    local dmg="$output_dir/EliteSIP-$version-$label$suffix.dmg"
    local staging="$output_dir/staging-$label"
    rm -rf "$staging" "$dmg"
    mkdir -p "$staging"
    ditto "$app" "$staging/EliteSIP.app" || fail "[$label] не скопировалось приложение в образ"
    ln -s /Applications "$staging/Applications"

    hdiutil create -volname "EliteSIP $label" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null \
        || fail "[$label] не собрался DMG"
    rm -rf "$staging"

    local dmg_sign_flags=""
    [[ $self_signed -eq 1 ]] || dmg_sign_flags="--timestamp"
    codesign --force --sign "$identity" $dmg_sign_flags "$dmg" || fail "[$label] не подписался DMG"
    ok "образ собран и подписан: $dmg"

    if [[ $self_signed -eq 0 ]]; then
        step "[$label] Нотарификация DMG"
        xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait \
            || fail "[$label] нотарификация DMG не прошла. Подробности: xcrun notarytool log <id> --keychain-profile $notary_profile"
        xcrun stapler staple "$dmg" || fail "[$label] не прикрепился билет к DMG"
        xcrun stapler validate "$dmg" || fail "[$label] билет на DMG не проверяется"
        ok "DMG нотарифицирован и заштемпелёван"
    fi

    artifacts+=("$dmg")
}

for target in "${targets[@]}"; do
    release_one "$target"
done

trap - INT TERM

# --- Итог --------------------------------------------------------------------

step "Готово"
printf '  версия: %s (%s)\n\n' "$version" "$build_number"
for dmg in "${artifacts[@]}"; do
    printf '  %s\n' "$dmg"
    printf '    размер:  %s\n' "$(du -h "$dmg" | cut -f1)"
    printf '    SHA-256: %s\n' "$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
done

printf '\nЧто осталось сделать руками:\n\n'
printf '  1. Закоммитить Config/Version.xcconfig и поставить метку версии:\n'
printf '     git commit -am "Выпуск %s" && git tag v%s\n' "$version" "$version"

if [[ $self_signed -eq 1 ]]; then
    cat <<'REMINDER'
  2. Принести образ на рабочее место так, чтобы он НЕ получил карантин:
     scp, rsync или флешка через терминал. Своя подпись Gatekeeper не проходит:
     с macOS 10.15 приложение с карантином обязано быть ещё и нотарифицировано,
     а это только по учётной записи Apple Developer.
     Если карантин всё-таки прилип, снять его на месте:
     xattr -dr com.apple.quarantine /Applications/EliteSIP.app
  3. Помнить, что такой выпуск нечем обновлять: Sparkle (M7h) стоит после
     настоящей подписи.

Полный чек-лист приёмки — docs/release.md.
REMINDER
else
    cat <<'REMINDER'
  2. Проверить образ на ЧИСТОЙ машине с включёнными проверками
     (`spctl --status` → assessments enabled) и с карантином:
     xattr -w com.apple.quarantine "0081;00000000;Safari;" /путь/EliteSIP.app
     На машине сборки проверка Gatekeeper не доказывает ничего: при
     выключенных проверках spctl принимает что угодно, включая ad-hoc.
  3. Открыть образ без сети — это и есть доказательство степлинга.

Полный чек-лист приёмки — docs/release.md.
REMINDER
fi
