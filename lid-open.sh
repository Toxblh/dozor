#!/bin/sh
# Гейт перед pam_fprintd. Возвращает 0, если отпечаток сейчас уместен, и 1,
# если его надо пропустить и сразу спрашивать пароль.
#
# Подключается так (см. system-auth-local-only на ALT):
#   auth  [success=ignore default=1]  pam_exec.so quiet /etc/security/lid-open.sh
#   auth  sufficient                  pam_fprintd.so
#
# ВАЖНО про безопасность: этот гейт умеет только ПОНИЗИТЬ отпечаток до пароля,
# он никогда никого не пускает. Любая его поломка (нет файла, ошибка, мусор на
# входе) даёт ненулевой код -> PAM перепрыгивает pam_fprintd -> обычный пароль.
# То есть отказ всегда безопасный.
#
# Пропускаем отпечаток в двух случаях:
#   1) крышка ноутбука закрыта — до сканера не дотянуться (док);
#   2) агент Dozor попросил флагом: пользователь уже начал вводить пароль,
#      ждать палец больше незачем.

FLAG_MAX_AGE=15   # секунд; более старый флаг считаем протухшим (агент упал)

# --- 1. одноразовый флаг от агента --------------------------------------
if [ -n "${PAM_USER:-}" ]; then
	uid=$(id -u "$PAM_USER" 2>/dev/null)
	if [ -n "$uid" ]; then
		flag="/run/user/$uid/dozor-skip-fp"
		if [ -e "$flag" ]; then
			now=$(date +%s 2>/dev/null || echo 0)
			ts=$(stat -c %Y "$flag" 2>/dev/null || echo 0)
			rm -f "$flag"     # флаг одноразовый: съедаем в любом случае
			# Протухший флаг НЕ honor'им: иначе упавший агент молча отключил бы
			# отпечаток на следующей аутентификации.
			if [ "$now" -gt 0 ] && [ "$ts" -gt 0 ] \
			   && [ $((now - ts)) -le "$FLAG_MAX_AGE" ]; then
				exit 1
			fi
		fi
	fi
fi

# --- 2. состояние крышки -------------------------------------------------
# Сначала /proc/acpi (дёшево, без зависимостей), затем logind как переносимый
# запасной вариант: на части машин ACPI-устройства крышки просто нет.
for state in /proc/acpi/button/lid/*/state; do
	[ -r "$state" ] || continue
	grep -qi 'closed' "$state" && exit 1
	exit 0
done

# Абсолютный путь намеренно: на ALT busctl идёт через alternatives, и пакеты
# предоставляют именно /usr/bin/busctl. Вызов по имени заставил бы rpm вывести
# зависимость от /bin/busctl, которую никто не предоставляет -> пакет стал бы
# неустанавливаемым.
if [ -x /usr/bin/busctl ]; then
	case "$(/usr/bin/busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
	        org.freedesktop.login1.Manager LidClosed 2>/dev/null)" in
		*true*) exit 1 ;;
	esac
fi

# Крышки нет (десктоп) или состояние неизвестно — отпечаток уместен.
exit 0
