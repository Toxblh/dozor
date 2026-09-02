#!/bin/sh
# Установка Dozor. Идемпотентно, умеет мигрировать со старых имён.
# Агент — скомпилированный бинарь (Vala), ставится в ~/.local/bin, поэтому
# на immutable-системах (ALT Atomic и т.п.) root для него не нужен вовсе.
# Root нужен только для PAM-хука, гейта отпечатка и polkit-действия.
#
# Отпечаток решает гейт lid-open.sh перед pam_fprintd в системном PAM-стеке:
# крышка закрыта или пользователь уже вводит пароль -> отпечаток пропускается.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PAM_LINE='auth\t\tsufficient\tpam_exec.so quiet /etc/security/dozor-sudo.sh'

echo '== сборка агента =='
command -v valac >/dev/null || { echo 'нужен valac (apm system install -y vala)'; exit 1; }
command -v meson >/dev/null || { echo 'нужен meson (apm system install -y meson)'; exit 1; }
[ -d "$HERE/build" ] || command meson setup "$HERE/build" --prefix="$HOME/.local" \
    -Dsystemd_userunitdir="$HOME/.config/systemd/user" \
    -Dgnome_extensiondir="$HOME/.local/share/gnome-shell/extensions" \
    --sysconfdir=/etc
command meson compile -C "$HERE/build"
command meson install -C "$HERE/build" >/dev/null
echo "агент: $HOME/.local/bin/dozor-agent"

echo '== системная часть (sudo) =='
sudo sh -eu -c "
    install -m 0755 -o root -g root '$HERE/dozor-sudo.sh' /etc/security/dozor-sudo.sh
    install -m 0755 -o root -g root '$HERE/lid-open.sh'   /etc/security/lid-open.sh
    install -m 0644 -o root -g root '$HERE/ru.toxblh.dozor.policy' /etc/polkit-1/actions/ru.toxblh.dozor.policy

    # миграция со старых имён и от ранней безусловной строки fprintd
    rm -f /etc/security/sudo-polkit.sh /etc/polkit-1/actions/dev.toxblh.sudo.policy
    sed -i 's#pam_exec.so quiet /etc/security/sudo-polkit.sh#pam_exec.so quiet /etc/security/dozor-sudo.sh#' /etc/pam.d/sudo
    sed -i '/pam_fprintd.so max_tries=1 timeout=10/d' /etc/pam.d/polkit-1

    grep -q dozor-sudo.sh /etc/pam.d/sudo || sed -i '1a $PAM_LINE' /etc/pam.d/sudo
"

echo '== пользовательская часть =='
mkdir -p ~/.local/share/gnome-shell/extensions ~/.config/systemd/user

# миграция со старых имён
systemctl --user disable awesome-sudo-agent.service 2>/dev/null || true
rm -f ~/.config/systemd/user/awesome-sudo-agent.service
rm -rf ~/.local/share/gnome-shell/extensions/awesome-sudo-agent@toxblh.me
gnome-extensions disable awesome-sudo-agent@toxblh.me 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable dozor.service

# На GNOME нужно расширение (глушит встроенный агент Shell). Wayland подхватывает
# новые расширения только при входе, поэтому пишем uuid прямо в gsettings.
if command -v gsettings >/dev/null && gsettings writable org.gnome.shell enabled-extensions >/dev/null 2>&1; then
    if ! gsettings get org.gnome.shell enabled-extensions | grep -q "dozor@toxblh.ru"; then
        cur=$(gsettings get org.gnome.shell enabled-extensions)
        case "$cur" in
            "@as []"|"[]") new="['dozor@toxblh.ru']" ;;
            *) new=$(printf '%s' "$cur" | sed "s/]\$/, 'dozor@toxblh.ru']/") ;;
        esac
        gsettings set org.gnome.shell enabled-extensions "$new"
    fi
    gnome-extensions enable dozor@toxblh.ru 2>/dev/null || true
    echo
    echo 'GNOME: расширение подхватится после выхода из сеанса и входа обратно.'
else
    echo
    echo 'Не GNOME: расширение не нужно, агент работает сам.'
    echo 'Запусти его в автостарте композитора: systemctl --user start dozor.service'
fi

echo 'Проверка: sudo true  ->  должно появиться окно Dozor.'
