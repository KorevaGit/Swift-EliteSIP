#!/bin/bash
#
# Проверка совместимости выпуска: одна universal-сборка, две нижние планки.
#
#   x86_64 — macOS 10.15 Catalina и новее;
#   arm64  — macOS 11 Big Sur и новее.
#
# Что скрипт доказывает: код компилируется и линкуется под обе планки, а готовый
# бинарь действительно несёт оба среза с нужным minos и Swift-конкурентность,
# развёрнутую назад. Чего он НЕ доказывает: поведение CoreAudio,
# VoiceProcessingIO и агрегатного устройства на живом старом Mac — это только
# ручная проверка на железе, см. docs/audio.md.
#
# Запуск: Tools/check-compat.sh

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

failures=0

step() {
    printf '\n=== %s\n' "$1"
}

fail() {
    printf '  ПРОВАЛ: %s\n' "$1"
    failures=$((failures + 1))
}

ok() {
    printf '  ок: %s\n' "$1"
}

# 1. Пакеты компилируются под оба среза.
#
# `swift build --arch` подставляет нижнюю планку из Package.swift, поэтому
# срез x86_64 собирается ровно под Catalina — это и проверяется.
for package in Compat Diagnostics MediaCore SIPCore CallGuard AdminAccess CallHistory; do
    for arch in x86_64 arm64; do
        step "$package: сборка $arch"
        if (cd "Packages/$package" && swift build --arch "$arch" >/dev/null 2>&1); then
            ok "собрался"
        else
            fail "$package не собирается под $arch"
        fi
    done
done

# 2. Тесты на своей архитектуре. Кросс-запускать нечем: Rosetta есть не у всех,
#    а тесты проверяют логику, а не машинный код.
for package in Compat Diagnostics MediaCore SIPCore CallGuard AdminAccess CallHistory; do
    step "$package: тесты"
    if (cd "Packages/$package" && swift test >/dev/null 2>&1); then
        ok "прошли"
    else
        fail "$package: тесты падают"
    fi
done

# 3. Каждое имя символа есть в каталоге.
#
# Это проверка совместимости, а не аккуратности. Каталог `Symbols` существует
# ровно потому, что SF Symbols нет до macOS 11: `CompatSymbol` рисует
# `Image(name)` по имени из ассетов. Опечатка в имени не ломает ни сборку, ни
# работу — иконка просто не рисуется, и заметить это можно только глазами на
# том экране, куда редко заходят. Так в приложении одновременно жили четыре
# невидимые иконки, три из них на кнопках управления звонком.
step "Символы: имена сходятся с каталогом"
missing=$(
    ls -d EliteSIP/Assets.xcassets/Symbols/*.imageset 2>/dev/null |
        sed 's|.*/||; s|\.imageset$||' | sort > /tmp/elitesip-symbols.$$
    # Кандидат — строковый литерал вида `phone.arrow.right`: строчные слова
    # через точку. Имена файлов той же формы (`settings.json`) отсеиваются
    # расширением, а не догадкой.
    #
    # Обратный DNS (`com.elitesochi.elitesip.network` — метка очереди в
    # `AppModel+AutoConnect`) отсеивается первым сегментом: `com` не может
    # начинать имя иконки, потому что имена SF Symbols — английские слова, а не
    # идентификаторы. Сужать иначе не вышло, и обе отвергнутые попытки стоит
    # назвать, чтобы их не повторяли. По числу сегментов нельзя: в каталоге
    # лежит `phone.arrow.down.left.fill`, то есть отсев длинных ослепил бы
    # проверку там, где опечатка вероятнее всего. По контексту вызова
    # (`CompatSymbol(...)`, аргумент `label:`) — тоже нельзя: до `CompatSymbol`
    # девять имён из двадцати одного доезжают через переменную или вычисляемое
    # свойство, а это ровно тот случай, ради которого проверка и написана.
    # Доменное имя (`crm.elitesochi.com` — боевая АТС в `Provisioning`)
    # отсеивается по домену верхнего уровня, а не по первому сегменту: у хоста
    # он как раз осмысленное слово, и `crm` от имени иконки не отличить.
    #
    # Имя нашего формата файлов (`elitesip.preset`, `elitesip.config` в
    # `EliteSIPDocument`) — по первому сегменту: иконки с таким именем не
    # бывает, а расширения у этих строк нет, они и есть идентификаторы формата.
    grep -rhoE '"[a-z][a-z0-9]*(\.[a-z0-9]+)+"' EliteSIP --include='*.swift' |
        tr -d '"' | grep -vE '\.(json|log|sqlite|swift|plist|txt|zip)$' |
        grep -vE '\.(com|ru|net|org|local)$' |
        grep -vE '^(com|elitesip)\.' | sort -u |
        comm -23 - /tmp/elitesip-symbols.$$
    rm -f /tmp/elitesip-symbols.$$
)
if [[ -z "$missing" ]]; then
    ok "все имена символов есть в каталоге"
else
    fail "нет ассетов для символов: $(echo "$missing" | tr '\n' ' ')"
fi

# 4. Приложение целиком, оба среза сразу.
step "Приложение: universal Release"
if xcodebuild -project EliteSIP.xcodeproj -scheme EliteSIP -configuration Release \
    -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO ARCHS="x86_64 arm64" \
    build >/dev/null 2>&1; then
    ok "собрался"
else
    fail "universal-сборка не удалась"
fi

app=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/EliteSIP-*/Build/Products/Release/EliteSIP.app 2>/dev/null | head -1)
binary="$app/Contents/MacOS/EliteSIP"

if [[ ! -x "$binary" ]]; then
    fail "не нашёл собранный бинарь"
else
    step "Бинарь: срезы и нижние планки"
    architectures=$(lipo -archs "$binary")
    for arch in x86_64 arm64; do
        if [[ " $architectures " == *" $arch "* ]]; then
            ok "срез $arch на месте"
        else
            fail "нет среза $arch (есть: $architectures)"
        fi
    done

    check_minos() {
        local arch=$1 expected=$2 actual
        actual=$(vtool -arch "$arch" -show-build-version "$binary" 2>/dev/null \
            | awk '/minos/ {print $2}')
        if [[ "$actual" == "$expected" ]]; then
            ok "$arch: minos $actual"
        else
            fail "$arch: minos $actual вместо $expected"
        fi
    }
    check_minos x86_64 10.15
    check_minos arm64 11.0

    step "Release: отладочного права get-task-allow нет"
    # Проверка настройки, а не подписи. `CODE_SIGN_INJECT_BASE_ENTITLEMENTS =
    # NO` в Release убирает право, которое Xcode добавляет сам при ad-hoc
    # подписи; нотарификация бинарь с ним отклоняет. Настройка невидимая, и
    # пропажу её замечает служба Apple в день выпуска — то есть поздно.
    # Вывод сперва в переменную: при `pipefail` нашедший `grep -q` закрывает
    # трубу, `codesign` получает SIGPIPE, и конвейер возвращает ошибку — то есть
    # находка теряется ровно тогда, когда она есть.
    entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null)
    if grep -q "get-task-allow" <<<"$entitlements"; then
        fail "в подписи есть com.apple.security.get-task-allow — нотарификация такую сборку отклонит"
    else
        ok "get-task-allow нет"
    fi

    step "Release: конфиг провижининга вшит"
    # Пустая проверка на машине сборщика и осмысленная везде ещё: без этого
    # файла в бандле рабочее место встаёт с «Управлением» без пароля, а сборка
    # при этом выглядит рабочей.
    if [[ -f "$app/Contents/Resources/provisioning.json" ]]; then
        ok "provisioning.json в бандле"
    else
        fail "в Release-бандле нет provisioning.json"
    fi

    step "Бинарь: Swift-конкурентность развёрнута назад"
    # На Catalina libswift_Concurrency в системе нет, и без вложенной копии
    # приложение не запустится вовсе — падение на dyld, ещё до первого экрана.
    if [[ -f "$app/Contents/Frameworks/libswift_Concurrency.dylib" ]]; then
        ok "libswift_Concurrency вложен в бандл"
    else
        fail "libswift_Concurrency не вложен — на Catalina приложение не запустится"
    fi
fi

printf '\n'
if [[ $failures -eq 0 ]]; then
    printf 'Совместимость: всё сошлось.\n'
else
    printf 'Совместимость: провалов %d.\n' "$failures"
fi
exit $((failures > 0))
