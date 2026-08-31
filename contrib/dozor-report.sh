#!/bin/sh
# Dozor diagnostics collector. Собирает всё нужное для issue В ОДИН файл и
# ПО УМОЛЧАНИЮ вычищает приватное: имя пользователя, hostname, домашний путь.
#
# Dozor — агент аутентификации: его логи содержат чувствительное. Поэтому:
#   - отчёт пишется В ФАЙЛ, никуда не отправляется;
#   - user/host/home заменяются на USER/HOST/~ до записи;
#   - командные строки (что запускалось под root) СОХРАНЯЮТСЯ для отладки, но
#     помечены маркером >>> REVIEW — их обязан просмотреть человек перед отправкой.
#
# Использование:
#   ./contrib/dozor-report.sh            # почищенный отчёт -> ./dozor-report.txt
#   ./contrib/dozor-report.sh --full     # без чистки (только локально!)
#   ./contrib/dozor-report.sh --selftest # проверить, что чистка реально чистит
set -eu

OUT="${DOZOR_REPORT_OUT:-./dozor-report.txt}"
REDACT=1
[ "${1:-}" = --full ] && REDACT=0

U=$(id -un); H=$(hostname 2>/dev/null || echo localhost); HOME_DIR=${HOME:-/home/$U}

redact() {
	if [ "$REDACT" = 0 ]; then cat; return; fi
	# порядок важен: home раньше user (в пути есть имя), fqdn раньше hostname
	sed -e "s#$HOME_DIR#~#g" \
	    -e "s#\\b$U\\b#USER#g" \
	    -e "s#$H\\([.a-z0-9-]*\\)#HOST#g"
}

section() { printf '\n===== %s =====\n' "$1"; }

collect() {
	section "Dozor report ($(date -u +%FT%TZ), redact=$REDACT)"

	section versions
	. /etc/os-release 2>/dev/null && echo "OS: ${PRETTY_NAME:-?}"
	echo "GNOME Shell: $(gnome-shell --version 2>/dev/null || echo n/a)"
	echo "polkit: $(pkaction --version 2>/dev/null || echo n/a)"
	echo "sudo: $(sudo --version 2>/dev/null | head -1 || echo n/a)"
	echo "compositor: ${XDG_SESSION_TYPE:-?} / ${XDG_CURRENT_DESKTOP:-?}"

	section "installed files"
	for f in /etc/security/dozor-sudo.sh /etc/security/lid-open.sh \
	         /etc/polkit-1/actions/ru.toxblh.dozor.policy \
	         "$HOME_DIR/.local/share/gnome-shell/extensions/dozor@toxblh.ru/metadata.json" \
	         "$HOME_DIR/.config/systemd/user/dozor.service"; do
		[ -e "$f" ] && echo "OK   $f" || echo "MISS $f"
	done

	section "agent unit"
	systemctl --user is-active dozor.service 2>&1 || true
	systemctl --user status dozor.service --no-pager 2>&1 | head -8 || true

	section "extension"
	gnome-extensions info dozor@toxblh.ru 2>&1 | grep -E 'State|Enabled|Version' || echo n/a

	section "PAM (нужен root; пусто = не смогли прочитать)"
	sudo -n cat /etc/pam.d/sudo /etc/pam.d/polkit-1 2>/dev/null || \
		echo "(перезапусти под sudo для PAM-стека)"

	section "agent journal (last 120) >>> REVIEW: команды/пути"
	journalctl --user -u dozor.service -n 120 --no-pager 2>&1 || true

	section "polkitd journal for dozor action (last 40) >>> REVIEW"
	journalctl -u polkit -n 400 --no-pager 2>&1 | grep -i dozor | tail -40 || true

	section "gnome-shell extension errors this boot"
	journalctl --user -b --no-pager 2>&1 | grep -iE 'dozor|polkitAgent' | tail -20 || true
}

if [ "${1:-}" = --selftest ]; then
	U=alice H=secret.example.com HOME_DIR=/home/alice
	got=$(printf '/home/alice/x by alice on secret.example.com\n' | redact)
	echo "$got"
	case "$got" in
		*alice*|*secret*) echo "SELFTEST FAIL: приватное просочилось"; exit 1 ;;
		"~/x by USER on HOST") echo "SELFTEST OK" ;;
		*) echo "SELFTEST FAIL: неожиданный вывод"; exit 1 ;;
	esac
	exit 0
fi

collect | redact > "$OUT"
echo "Отчёт: $OUT  (redact=$REDACT). ПРОЧИТАЙ его перед отправкой:"
echo "  less $OUT   # особенно строки с маркером >>> REVIEW"
