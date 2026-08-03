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

# 3. Приложение целиком, оба среза сразу.
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
