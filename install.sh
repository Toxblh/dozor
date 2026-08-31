#!/bin/sh
# Установка Dozor. Идемпотентно, умеет мигрировать со старых имён
# (awesome-sudo / dev.toxblh.sudo). Отпечаток решает гейт lid-open.sh перед
# pam_fprintd в системном PAM-стеке: крышка закрыта или пользователь уже
# вводит пароль (skip-флаг от агента) -> отпечаток пропускается сразу.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PAM_LINE='auth\t\tsufficient\tpam_exec.so quiet /etc/security/dozor-sudo.sh'

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
cp -r "$HERE/extension/dozor@toxblh.ru" ~/.local/share/gnome-shell/extensions/
cp "$HERE/dozor.service" ~/.config/systemd/user/

# миграция со старых имён
systemctl --user disable awesome-sudo-agent.service 2>/dev/null || true
rm -f ~/.config/systemd/user/awesome-sudo-agent.service
rm -rf ~/.local/share/gnome-shell/extensions/awesome-sudo-agent@toxblh.me
gnome-extensions disable awesome-sudo-agent@toxblh.me 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable dozor.service
# gnome-extensions enable не знает о ещё не загруженном расширении (Wayland
# подхватывает новые только при входе) -- правим список включённых напрямую.
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
echo 'Готово. Новое расширение GNOME Shell на Wayland подхватится после'
echo 'выхода из сеанса и входа обратно. После этого агент стартует сам.'
echo 'Проверка: sudo true  ->  должно появиться окно Dozor.'
