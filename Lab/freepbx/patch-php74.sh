#!/bin/bash
# Правит несовместимости кода FreePBX 15 с PHP 7.4.
#
# FreePBX 15 писался под PHP 5–7.2. В 7.4 два его приёма стали deprecated, а
# обработчик ошибок Symfony превращает предупреждение в исключение — то есть
# команда падает там, где по сути всё сработало. Настройка error_reporting не
# помогает: обработчик регистрируется до чтения php.ini.
#
# Скрипт идемпотентен: повторный запуск ничего не меняет.
set -euo pipefail

ROOTS=("$@")
if [ ${#ROOTS[@]} -eq 0 ]; then
  ROOTS=(/var/www/html/admin /usr/src/freepbx)
fi

EXISTING=()
for root in "${ROOTS[@]}"; do
  [ -d "$root" ] && EXISTING+=("$root")
done
if [ ${#EXISTING[@]} -eq 0 ]; then
  echo "Нет ни одного из каталогов: ${ROOTS[*]}" >&2
  exit 1
fi

# --- 1. implode($array, 'glue') -> implode('glue', $array) --------------------
#
# Первый аргумент бывает не только простой переменной: место, которое блокирует
# загрузку модулей (modulefunctions.class.php), передаёт элемент массива
# $vinfo['vul']. Поэтому шаблон допускает индексы и обращения к свойствам.
IMPLODE_PATTERN='s/implode\((\$[A-Za-z_][A-Za-z_0-9]*(\[[^]]*\]|->[A-Za-z_][A-Za-z_0-9]*)*), *('"'"'[^'"'"']*'"'"'|"[^"]*")\)/implode(\3, \1)/g'

find "${EXISTING[@]}" -name '*.php' -not -path '*/vendor/*' -print0 2>/dev/null \
  | xargs -0 --no-run-if-empty sed -E -i "$IMPLODE_PATTERN"

# --- 2. $string{0} -> $string[0] ----------------------------------------------
#
# Правится ТОЛЬКО в одном известном файле, а не по всему дереву. Глобальная
# замена сломала бы интерполяцию вида "$foo{$bar}", которая в PHP означает
# совсем другое.
for root in "${EXISTING[@]}"; do
  ENCODING="$root/libraries/Composer/vendor/neitanod/forceutf8/src/ForceUTF8/Encoding.php"
  [ -f "$ENCODING" ] || ENCODING="$root/amp_conf/htdocs/admin/libraries/Composer/vendor/neitanod/forceutf8/src/ForceUTF8/Encoding.php"
  [ -f "$ENCODING" ] && sed -i 's/\$text{\([^}]*\)}/$text[\1]/g' "$ENCODING"
done

# --- Проверка ----------------------------------------------------------------
#
# Проверяем именно те два места, которые блокируют работу, а не «ноль по всему
# дереву». В дереве FreePBX есть и другие вызовы с обратным порядком, где первым
# аргументом идёт вызов функции — шаблон их намеренно не трогает, и валить из-за
# них сборку неправильно: до этих строк выполнение просто не доходит.
BLOCKERS=0
for root in "${EXISTING[@]}"; do
  for candidate in \
    "$root/libraries/modulefunctions.class.php" \
    "$root/amp_conf/htdocs/admin/libraries/modulefunctions.class.php"
  do
    [ -f "$candidate" ] || continue
    if grep -qE 'implode\(\$[A-Za-z_][A-Za-z_0-9]*(\[[^]]*\]|->[A-Za-z_][A-Za-z_0-9]*)*, *('"'"'|")' "$candidate"; then
      echo "НЕ ИСПРАВЛЕНО: $candidate" >&2
      BLOCKERS=$((BLOCKERS + 1))
    fi
  done
done

echo "Патч PHP 7.4 применён к: ${EXISTING[*]}"
[ "$BLOCKERS" = "0" ]
