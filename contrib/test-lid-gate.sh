#!/bin/sh
# Проверка гейта отпечатка (lid-open.sh). Запускать после правок гейта.
# Гейт умеет только понизить отпечаток до пароля, поэтому "безопасный" исход
# везде — exit 0 (отпечаток запрашивается) либо 1 (сразу пароль), но НЕ допуск.
set -eu
GATE=${1:-/etc/security/lid-open.sh}
U=$(id -u); F="/run/user/$U/dozor-skip-fp"
fail=0
check() { # описание ожидаемый_код фактический_код
    if [ "$2" = "$3" ]; then echo "  OK   $1"; else echo "  FAIL $1 (ждали $2, получили $3)"; fail=1; fi
}
# && / || иначе set -e обрывает функцию на ненулевом коде гейта
run() { PAM_USER=$(id -un) sh "$GATE" && echo 0 || echo $?; }

lid=$(cat /proc/acpi/button/lid/*/state 2>/dev/null | grep -o 'closed\|open' | head -1 || echo unknown)
echo "состояние крышки: $lid"
rm -f "$F"
[ "$lid" = closed ] && want=1 || want=0
check "крышка $lid, флага нет" "$want" "$(run)"

touch "$F";                     check "свежий флаг -> пропустить отпечаток" 1 "$(run)"
                                check "флаг одноразовый (съеден)" "$want" "$(run)"
touch -d '1 hour ago' "$F";     check "протухший флаг игнорируется" "$want" "$(run)"
[ -e "$F" ] && { echo "  FAIL протухший флаг не удалён"; fail=1; } || echo "  OK   протухший флаг удалён"
rm -f "$F"

check "PAM_USER не задан" "$want" "$(env -u PAM_USER sh "$GATE" && echo 0 || echo $?)"
check "несуществующий PAM_USER" "$want" "$(PAM_USER=nonexistent-xyz sh "$GATE" && echo 0 || echo $?)"

[ "$fail" = 0 ] && echo "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ" || { echo "ЕСТЬ ОШИБКИ"; exit 1; }
