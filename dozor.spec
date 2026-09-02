Name: dozor
Version: 0.2.0
Release: alt1
Summary: Polkit authentication agent that shows who is asking for privileges
License: GPL-3.0-or-later
Group: Graphical desktop/GNOME
Url: https://github.com/Toxblh/dozor

Source: %name-%version.tar

BuildRequires: vala
BuildRequires: meson
BuildRequires: ninja-build
BuildRequires: gcc
BuildRequires: libgtk4-devel
BuildRequires: libadwaita-devel
BuildRequires: libpolkit-devel
BuildRequires: libjson-glib-devel
BuildRequires: libgio-devel

Requires: polkit

%description
Dozor is a polkit authentication agent with provenance: instead of a bare
password box it shows which application is asking for privileges, the exact
command being run, the full process ancestry, the working directory and the
terminal, plus a button that jumps to the requesting application window.

It replaces the built-in GNOME Shell dialog (via a small Shell extension) and
serves every polkit request in the session. A PAM hook can route terminal sudo
through the same window, so sudo from a terminal or from an AI agent session
raises a graphical prompt with full context.

Authentication itself is never done by Dozor: the password is verified by the
setuid polkit-agent-helper-1 through PAM, exactly as with any other agent.
Parsing of untrusted data (/proc of other processes) runs in a separate
process without access to the password.

Window focus works on any Wayland compositor: niri, Hyprland and sway get
precise per-pid focus through their IPC, GNOME goes through the extension.

%prep
%setup -q

%build
%meson
%meson_build

%install
%meson_install

%post
cat <<'EOF'

Dozor installed. Two steps remain, both intentionally manual:

  1. sudo dozor-setup enable      # wire the PAM hook into /etc/pam.d/sudo
  2. systemctl --user enable --now dozor.service

On GNOME also enable the Shell extension (needs a re-login on Wayland):
  gnome-extensions enable dozor@toxblh.ru

EOF

%preun
if [ $1 -eq 0 ]; then
	# снимаем строку из PAM-стека, иначе останется ссылка на удалённый хук
	%_sbindir/dozor-setup disable >/dev/null 2>&1 ||:
fi

%files
%_bindir/dozor-agent
%_sbindir/dozor-setup
/lib/systemd/user/dozor.service
%_datadir/polkit-1/actions/ru.toxblh.dozor.policy
%_datadir/gnome-shell/extensions/dozor@toxblh.ru
%config(noreplace) %attr(755,root,root) %_sysconfdir/security/dozor-sudo.sh
%config(noreplace) %attr(755,root,root) %_sysconfdir/security/lid-open.sh
%doc README.md README.ru.md LLM.md

%changelog
* Mon Sep 01 2026 Builder <hasherc-ci@altlinux.org> 0.2.0-alt1
- Initial build for ALT: Vala agent, no Python at runtime
- privilege separation: provenance collector runs as a separate process
  without access to the password
- Cairo animations for fingerprint, face and security key states
- window focus on niri, Hyprland, sway and GNOME
- fingerprint gate: skips the reader when the laptop lid is closed
- PAM wiring is not done automatically, use dozor-setup enable
