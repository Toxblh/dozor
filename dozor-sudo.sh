#!/bin/sh
# Dozor: pam_exec-хук для sudo. Просит polkit показать графическое окно
# аутентификации и возвращает 0 при успехе. Перед этим сбрасывает контекст
# запроса (команда, процесс, каталог, tty) в /run/user/$uid/dozor.ctx — его
# читает агент Dozor, чтобы показать, кто и зачем просит права.
# Контекст — только для отображения; аутентификацию делает polkit.
#
# Любая осечка -- нет агента, ssh-сессия, отмена, таймаут -- даёт ненулевой код,
# и PAM просто продолжает обычным путём, спрашивая пароль в терминале.

ACTION=ru.toxblh.dozor.sudo

# Поля /proc/<pid>/stat после "pid (comm) ": 1=state, 2=ppid, ... 20=starttime.
# Отрезаем всё по последнюю ')', иначе пробелы в comm сдвигают нумерацию.
stat_field() {
	sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk -v i="$2" '{print $i}'
}

# Сам sudo уже работает от root, поэтому субъектом для polkit берём процесс,
# из которого sudo был запущен, -- шелл пользователя.
[ -r "/proc/$PPID/stat" ] || exit 1
caller=$(stat_field "$PPID" 2)
[ -n "$caller" ] && [ "$caller" -gt 1 ] 2>/dev/null || exit 1
[ -r "/proc/$caller/stat" ] || exit 1

start=$(stat_field "$caller" 20)
[ -n "$start" ] || exit 1

uid=$(stat -c %u "/proc/$caller" 2>/dev/null)
[ -n "$uid" ] && [ "$uid" -ne 0 ] || exit 1

# Нет пользовательской шины -- нет и агента, не тратим время на попытку.
[ -S "/run/user/$uid/bus" ] || exit 1

# Контекст для окна агента. Пишем атомарно, мир может читать (то же самое
# и так видно в /proc), b64 спасает от переводов строк в cmdline.
ctx="/run/user/$uid/dozor.ctx"
{
	echo "ts=$(date +%s)"
	echo "action=$ACTION"
	echo "caller_pid=$caller"
	echo "caller_comm=$(cat "/proc/$caller/comm" 2>/dev/null)"
	echo "sudo_pid=$PPID"
	echo "sudo_cmdline_b64=$(tr '\0' ' ' <"/proc/$PPID/cmdline" 2>/dev/null | base64 -w0)"
	echo "cwd=$(readlink "/proc/$caller/cwd" 2>/dev/null)"
	echo "tty=${PAM_TTY:-}"
	echo "pam_user=${PAM_USER:-}"
} >"$ctx.tmp" 2>/dev/null && chmod 0644 "$ctx.tmp" && mv "$ctx.tmp" "$ctx"

exec timeout 120 pkcheck \
	--action-id "$ACTION" \
	--process "$caller,$start,$uid" \
	--allow-user-interaction
