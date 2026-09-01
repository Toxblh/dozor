# Dozor

**🇬🇧 [English version](README.md)**

Polkit-агент с провенансом: показывает, **кто** просит права (реальный
инициатор в заголовке — «Разрешить **claude** из **Терминал**…» — и полная
цепочка процессов `sudo ← timeout ← zsh ← claude ← … ← ptyxis`), **какую
команду** выполняет, из какого каталога и терминала, с кнопкой перехода к
окну приложения-источника. GTK4 + libadwaita, GNOME-стиль, тёмная тема,
анимации. Работает для всех polkit-запросов и для sudo (через PAM-хук).

<p align="center">
  <img src="docs/dozor.gif" width="380" alt="Dozor в действии: отпечаток, слайд пароля, shake при ошибке">
</p>

| Тёмная | Светлая |
|--------|---------|
| ![тёмная](docs/hero-dark.png) | ![светлая](docs/hero-light.png) |

У каждого метода аутентификации PAM — свой стейт: определяется по
PAM-сообщениям, иконка пульсирует, пока ждём:

| Отпечаток (pam_fprintd) | Лицо (howdy) | Ключ / смарт-карта (pam_u2f, pam_pkcs11) |
|-------------------------|--------------|------------------------------------------|
| ![отпечаток](docs/state-fingerprint.gif) | ![лицо](docs/state-face.gif) | ![ключ](docs/state-token.gif) |

## Как это работает

```
sudo → PAM (pam_exec) → dozor-sudo.sh → pkcheck(ru.toxblh.dozor.sudo)
                              │                    │
                              │ пишет контекст     ▼
                              │ /run/user/UID/  polkitd ── BeginAuthentication
                              ▼ dozor.ctx          │
                                                   ▼
                                        dozor-agent (окно Dozor)
                                                   │ PolkitAgent.Session
                                                   ▼
                                   polkit-agent-helper-1 (setuid) → PAM → ok
```

- `src/dozor.vala` — агент (Vala, компилируемый): реализация DBus-интерфейса
  `org.freedesktop.PolicyKit1.AuthenticationAgent` (PolkitAgent.Listener из
  Python segfault-ится — pygobject теряет user_data async-vfunc). Регистрируется
  на сессию вместо встроенного агента GNOME Shell, обслуживает **все**
  polkit-запросы: polkitd передаёт `polkit.subject-pid`, по нему резолвится
  приложение-источник (иконка, имя, кнопка фокуса).
- Методы аутентификации визуализируются по PAM-сообщениям: пароль, отпечаток
  (pam_fprintd), лицо (howdy), ключ/смарт-карта (pam_u2f/pam_pkcs11, PIN).
- `dozor-sudo.sh` — PAM-хук: сбрасывает контекст запроса для окна и зовёт
  `pkcheck`. Контекст только для отображения, аутентификация — целиком polkit.
- `extension/dozor@toxblh.ru` — расширение GNOME Shell: глушит встроенный агент
  (`Main.componentManager._disableComponent('polkitAgent')`) и экспортирует
  `ru.toxblh.Dozor.FocusApp` (изнутри Shell фокусировать окна можно).
- Фокус окна на любом Wayland-композиторе: **niri**, **Hyprland** и **sway** —
  точный фокус по pid через их IPC (расширение там не нужно); GNOME — через
  расширение; универсальный фолбэк — `org.freedesktop.Application.Activate`.
- `src/collector.vala` — сбор провенанса **отдельным процессом** (агент
  ре-exec'ает себя с `--collect`): один подписываемый артефакт, но парсинг
  недоверенного `/proc` идёт там, где нет пароля.
- `src/animation.vala`, `src/focus.vala` — Cairo-анимации методов и фокус окна.
- `dozor.service` — systemd user unit, автозапуск агента (с hardening:
  `NoNewPrivileges`, `ProtectSystem=strict`, пустой `CapabilityBoundingSet`,
  `SystemCallFilter=@system-service`).
- Биометрия с учётом контекста: PAM-гейт `lid-open.sh` пропускает отпечаток,
  когда крышка ноутбука закрыта (док), а поле пароля доступно **во время**
  ожидания пальца — начали вводить, нажали Enter, агент перезапустит
  PAM-разговор мимо сканера (одноразовый skip-флаг) и сам подставит пароль.
  Палец или пароль — что случится первым.

## Установка

```sh
./install.sh          # сборка meson, установка в ~/.local/bin
```

Нужны `vala`, `meson` и dev-пакеты gtk4 / libadwaita / polkit / json-glib.
Для самого агента root не нужен — только для PAM-хука и polkit-действия.
На GNOME затем перелогиниться (Wayland подхватывает новые расширения только при входе).

Отпечаток ожидается в системном PAM-стеке за гейтом `lid-open.sh`
(на ALT — в `system-auth-local-only`):

```
auth  [success=ignore default=1]  pam_exec.so quiet /etc/security/lid-open.sh
auth  sufficient                  pam_fprintd.so
```

## Отладка

```sh
meson compile -C build                       # пересборка после правки src/*.vala
build/dozor-agent --test-pid $$              # агент только для этого шелла
build/dozor-agent --collect $$ ru.toxblh.dozor.sudo   # только коллектор провенанса
journalctl --user -u dozor -f                # логи агента
DOZOR_SHOT=/tmp/x.png build/dozor-agent ...  # скриншот реального окна
```

Известные углы: на экране блокировки агент не показывает окно (запросы
с lockscreen редки и истекают по таймауту); выбор учётной записи не
реализован — берётся текущий пользователь.

## Отладка и вклад

Если отлаживаете или чините Dozor через ИИ-ассистента — дайте ему
**[LLM.md](LLM.md)**: там архитектура, сбор *очищенного* отчёта
(`./contrib/dozor-report.sh`) и как завести issue или PR без утечки данных.
