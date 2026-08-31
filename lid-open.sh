#!/bin/sh
# Возвращает 0, если отпечаток сейчас уместен: крышка ноутбука ОТКРЫТА
# (или состояние неизвестно) и агент Dozor не просил его пропустить.
# Возвращает 1, если крышка ЗАКРЫТА или пользователь уже вводит пароль.
#
# Используется из PAM (pam_exec) перед pam_fprintd, чтобы не ждать палец,
# когда до сканера не дотянуться или пароль уже набирается.

# Одноразовый флаг от агента Dozor: пользователь начал вводить пароль --
# отпечаток не нужен, флаг сжигаем.
if [ -n "${PAM_USER:-}" ]; then
	uid=$(id -u "$PAM_USER" 2>/dev/null)
	flag="/run/user/${uid:-}/dozor-skip-fp"
	if [ -n "$uid" ] && [ -e "$flag" ]; then
		rm -f "$flag"
		exit 1
	fi
fi

for state in /proc/acpi/button/lid/*/state; do
	[ -r "$state" ] || continue
	if grep -qi 'closed' "$state"; then
		exit 1
	fi
done

exit 0
