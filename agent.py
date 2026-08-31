#!/usr/bin/env python3
"""Dozor: polkit-агент с человеческим лицом.

Регистрируется вместо встроенного агента GNOME Shell (его отключает
расширение dozor@toxblh.ru) и показывает окно c данными:
кто просит, что именно, из какого каталога, с кнопкой
перехода к окну приложения-источника.

Для действия ru.toxblh.dozor.sudo контекст (команда, pid, cwd, tty) приходит
из /run/user/$UID/dozor.ctx, который пишет PAM-хук
/etc/security/dozor-sudo.sh. Контекст — только для отображения:
саму аутентификацию по-прежнему делает polkit через setuid-хелпер.
"""

import base64
import json
import math
import os
import re
import signal
import subprocess
import sys
import time

import cairo
import gi

gi.require_version('Gtk', '4.0')
gi.require_version('Adw', '1')
gi.require_version('Polkit', '1.0')
gi.require_version('PolkitAgent', '1.0')
from gi.repository import Adw, Gdk, Gio, GLib, Gtk, Pango, Polkit, PolkitAgent  # noqa: E402

CTX_PATH = f'/run/user/{os.getuid()}/dozor.ctx'
CTX_MAX_AGE = 20  # секунд; более старый файл считаем чужим/протухшим
SUDO_ACTION = 'ru.toxblh.dozor.sudo'
# одноразовый флаг «пропусти отпечаток»: его читает /etc/security/lid-open.sh
SKIP_FP_FLAG = f'/run/user/{os.getuid()}/dozor-skip-fp'

# app-gnome-org.gnome.Ptyxis-2288.scope / app-flatpak-org.gimp.GIMP-33.scope
APP_SCOPE_RE = re.compile(r'app-(?:gnome-|flatpak-|wayland-|KDE-)?(.+?)(?:-\d+)?\.scope$')


def log(*args):
    print('[dozor]', *args, file=sys.stderr, flush=True)


# --- разбор /proc -----------------------------------------------------------

def proc_ppid(pid):
    try:
        with open(f'/proc/{pid}/stat') as f:
            return int(f.read().rsplit(')', 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        return None


def proc_comm(pid):
    try:
        with open(f'/proc/{pid}/comm') as f:
            return f.read().strip()
    except OSError:
        return None


def proc_cgroup(pid):
    try:
        with open(f'/proc/{pid}/cgroup') as f:
            return f.read().strip().splitlines()[-1]
    except (OSError, IndexError):
        return ''


def resolve_app(pid):
    """pid -> (Gio.DesktopAppInfo | None, имя для показа, найденный pid).

    Идём вверх по родителям и ищем systemd-scope приложения в cgroup.
    ptyxis-spawn-* — особый случай: терминал Ptyxis запускает шеллы
    в отдельных scope вне app.slice.
    """
    cur, hops = pid, 0
    fallback_comm = proc_comm(pid)
    while cur and cur > 1 and hops < 12:
        cg = proc_cgroup(cur)
        unit = cg.rsplit('/', 1)[-1]
        m = APP_SCOPE_RE.search(unit)
        app_id = None
        if m:
            app_id = m.group(1).replace('\\x2d', '-')
        elif unit.startswith('ptyxis-spawn-'):
            app_id = 'org.gnome.Ptyxis'
        if app_id:
            info = Gio.DesktopAppInfo.new(app_id + '.desktop')
            if info:
                return info, info.get_display_name(), cur
            return None, app_id, cur
        cur, hops = proc_ppid(cur), hops + 1
    return None, fallback_comm or '?', pid


def read_sudo_ctx():
    """KV-файл от PAM-хука. Возвращает dict или None (протух/нет)."""
    try:
        with open(CTX_PATH) as f:
            kv = dict(line.split('=', 1) for line in f.read().splitlines() if '=' in line)
        os.unlink(CTX_PATH)
    except OSError:
        return None
    try:
        if time.time() - int(kv.get('ts', 0)) > CTX_MAX_AGE:
            return None
    except ValueError:
        return None
    if 'sudo_cmdline_b64' in kv:
        try:
            kv['cmdline'] = base64.b64decode(kv['sudo_cmdline_b64']).decode(errors='replace').strip()
        except ValueError:
            pass
    return kv


def proc_chain(pid, limit=10):
    """«sudo (11100) ← timeout ← zsh ← claude ← zsh ← ptyxis»: кто на самом
    деле запустил. Идём вверх до systemd/init, не останавливаясь на первом
    процессе scope'а — иначе из цепочки выпадает всё интересное."""
    parts, cur = [], pid
    while cur and cur > 1 and len(parts) < limit:
        comm = proc_comm(cur)
        if not comm or comm in ('systemd', 'init'):
            break
        parts.append(f'{comm} ({cur})')
        cur = proc_ppid(cur)
    return ' ← '.join(parts)


# обёртки, которые ничего не говорят о том, кто на самом деле действует
TRIVIAL_COMMS = {'sudo', 'timeout', 'sh', 'bash', 'zsh', 'fish', 'dash', 'env',
                 'nice', 'ionice', 'doas', 'time', 'xargs', 'script', 'su'}


def actor_in_scope(pid):
    """Первый содержательный процесс среди предков pid в той же cgroup-scope:
    для `claude → zsh → timeout → sudo` внутри терминала это claude."""
    scope = proc_cgroup(pid)
    cur, hops = pid, 0
    while cur and cur > 1 and hops < 12 and proc_cgroup(cur) == scope:
        comm = proc_comm(cur)
        if comm and comm not in TRIVIAL_COMMS:
            return comm
        cur, hops = proc_ppid(cur), hops + 1
    return None


def home_relative(path):
    home = os.path.expanduser('~')
    return '~' + path[len(home):] if path and path.startswith(home) else path


NIRI_SOCKET = os.environ.get('NIRI_SOCKET')


def focus_niri_window(caller_pid):
    """niri IPC: найти окно, чей pid — предок вызвавшего процесса, и сфокусировать.

    ponytail: через `niri msg`, а не сырой сокет; хватает, пока не понадобится
    работать без утилиты niri в PATH.
    """
    if not caller_pid:
        return False
    ancestors = set()
    cur, hops = caller_pid, 0
    while cur and cur > 1 and hops < 15:
        ancestors.add(cur)
        cur, hops = proc_ppid(cur), hops + 1
    try:
        out = subprocess.run(['niri', 'msg', '-j', 'windows'],
                             capture_output=True, text=True, timeout=3)
        for win in json.loads(out.stdout or '[]'):
            if win.get('pid') in ancestors:
                subprocess.run(['niri', 'msg', 'action', 'focus-window',
                                '--id', str(win['id'])], timeout=3)
                return True
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        log('niri focus failed:', e)
    return False


# --- окно аутентификации ----------------------------------------------------

CSS = """
window.dozor-auth { border-radius: 18px; }
.dozor-title { font-weight: 800; }
.dozor-cmd { font-family: monospace; font-size: 0.92em; }
.dozor-chain-line { color: alpha(currentColor, 0.35); font-weight: 700; letter-spacing: 3px; }
.dozor-check { color: @success_color; }
.dozor-lock { color: @accent_color; }

/* как в GNOME Shell: у поля пароля нет карандаша-индикатора.
   1px вместо 0 — нулевой размер роняет ассерты в gtk_icon_theme_lookup */
.dozor-auth row.entry image.edit-icon {
    -gtk-icon-size: 1px; opacity: 0; min-width: 0; margin: 0; padding: 0;
}

/* зона метода аутентификации: пульс, пока ждём палец/лицо/токен */
@keyframes dz-pulse {
    0% { opacity: 1; } 50% { opacity: 0.3; } 100% { opacity: 1; }
}
.dozor-method-icon { color: @accent_color; }
.dozor-pulse { animation: dz-pulse 1.6s ease-in-out infinite; }
.dozor-state-error { color: @error_color; }
"""


def icon_or(name, fallback):
    """Имя иконки, если она есть в теме, иначе фолбэк — потерянных иконок нет."""
    theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default())
    return name if name and theme.has_icon(name) else fallback


# Классификация PAM-сообщений: каким способом сейчас аутентифицируемся.
# pam_fprintd, howdy, pam_u2f/pam_pkcs11 говорят разными фразами.
METHOD_HINTS = (
    ('fingerprint', 'auth-fingerprint-symbolic',
     ('finger', 'палец', 'отпечат', 'swipe', 'fprint')),
    ('face', 'camera-web-symbolic',
     ('face', 'лицо', 'camera', 'камер', 'смотрите', 'howdy')),
    ('token', 'auth-smartcard-symbolic',
     ('security key', 'yubikey', 'token', 'токен', 'smart card', 'смарт-карт',
      'card', 'карт', 'insert', 'touch your', 'u2f', 'fido')),
)


def classify_method(text):
    low = text.lower()
    for kind, icon, needles in METHOD_HINTS:
        if any(n in low for n in needles):
            return kind, icon
    return None, None


def _ease_out(x):
    return 1 - (1 - x) ** 3


def _ease_in(x):
    return x ** 3


def _rounded_rect(cr, x, y, w, h, r):
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cr.close_path()


class MethodAnimation(Gtk.DrawingArea):
    """Рисованные зацикленные анимации методов аутентификации (Cairo).

    face  — визир из четырёх уголков; лицо выезжает снизу, улыбается, уходит.
    token — смарт-карта с чипом, сканирующая линия со шлейфом, мерцание данных.
    Цвет берём из CSS (@accent_color через .dozor-method-icon).
    DOZOR_ANIM_PHASE=0..1 фиксирует фазу — для скриншотов.
    """

    PERIOD = {'face': 3.6, 'token': 2.4}

    def __init__(self, size=52):
        super().__init__(content_width=size, content_height=size,
                         halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        self.kind = None
        self.add_css_class('dozor-method-icon')
        self.set_draw_func(self._draw)
        self.add_tick_callback(lambda *_: (self.queue_draw(), True)[1])

    def set_kind(self, kind):
        self.kind = kind
        self.queue_draw()

    def _phase(self):
        fixed = os.environ.get('DOZOR_ANIM_PHASE')
        if fixed:
            return float(fixed)
        clock = self.get_frame_clock()
        t = (clock.get_frame_time() if clock else 0) / 1e6
        period = self.PERIOD[self.kind]
        return (t % period) / period

    def _draw(self, _area, cr, w, h):
        if not self.kind:
            return
        c = self.get_color()
        self._rgb = (c.red, c.green, c.blue)
        cr.set_source_rgba(*self._rgb, 1.0)
        cr.set_line_width(2.2)
        cr.set_line_cap(cairo.LINE_CAP_ROUND)
        cr.set_line_join(cairo.LINE_JOIN_ROUND)
        if self.kind == 'face':
            self._draw_face(cr, w, h, self._phase())
        else:
            self._draw_token(cr, w, h, self._phase())

    def _draw_face(self, cr, w, h, p):
        s = min(w, h)
        m, L = s * 0.06, s * 0.24
        for x, y, dx, dy in ((m, m, 1, 1), (w - m, m, -1, 1),
                             (m, h - m, 1, -1), (w - m, h - m, -1, -1)):
            cr.move_to(x, y + dy * L)
            cr.line_to(x, y)
            cr.line_to(x + dx * L, y)
        cr.stroke()

        cy_home = h * 0.52
        if p < 0.22:            # выезжает снизу
            cy, smile = h * 1.2 - (h * 1.2 - cy_home) * _ease_out(p / 0.22), 0.0
        elif p < 0.40:          # улыбается
            cy, smile = cy_home, _ease_out((p - 0.22) / 0.18)
        elif p < 0.70:          # держит улыбку
            cy, smile = cy_home, 1.0
        elif p < 0.90:          # опускается
            k = _ease_in((p - 0.70) / 0.20)
            cy, smile = cy_home + (h * 0.75) * k, 1.0 - 0.6 * k
        else:                   # пауза, кадр пустой
            return

        r = s * 0.27
        cx = w / 2
        cr.save()
        cr.rectangle(m + 2, m + 2, w - 2 * m - 4, h - 2 * m - 4)
        cr.clip()
        cr.arc(cx, cy, r, 0, 2 * math.pi)
        cr.stroke()
        for ex in (cx - r * 0.38, cx + r * 0.38):
            cr.arc(ex, cy - r * 0.2, 1.7, 0, 2 * math.pi)
            cr.fill()
        mw, my = r * 0.55, cy + r * 0.3
        if smile < 0.05:
            cr.move_to(cx - mw, my)
            cr.line_to(cx + mw, my)
        else:
            d = r * 0.5 * smile
            cr.move_to(cx - mw, my - d * 0.25)
            cr.curve_to(cx - mw * 0.5, my + d, cx + mw * 0.5, my + d,
                        cx + mw, my - d * 0.25)
        cr.stroke()
        cr.restore()

    def _draw_token(self, cr, w, h, p):
        s = min(w, h)
        cw, ch = s * 0.9, s * 0.6
        x0, y0 = (w - cw) / 2, (h - ch) / 2
        rad = s * 0.09
        _rounded_rect(cr, x0, y0, cw, ch, rad)
        cr.stroke()

        # чип с контактной сеткой
        chw, chh = cw * 0.26, ch * 0.36
        chx, chy = x0 + cw * 0.12, y0 + ch * 0.2
        cr.set_line_width(1.6)
        _rounded_rect(cr, chx, chy, chw, chh, 2)
        cr.stroke()
        cr.set_line_width(1.1)
        cr.move_to(chx, chy + chh / 2)
        cr.line_to(chx + chw, chy + chh / 2)
        cr.move_to(chx + chw / 2, chy)
        cr.line_to(chx + chw / 2, chy + chh)
        cr.stroke()

        # мерцающие «данные» справа
        bx = x0 + cw * 0.52
        cr.set_line_width(2.4)
        for i in range(3):
            by = y0 + ch * (0.3 + 0.2 * i)
            flick = 0.5 + 0.5 * math.sin(p * 2 * math.pi * (1 + i) + i * 1.9)
            L = cw * 0.34 * (0.35 + 0.65 * flick)
            cr.set_source_rgba(*self._rgb, 0.55 + 0.45 * flick)
            cr.move_to(bx, by)
            cr.line_to(bx + L, by)
            cr.stroke()

        # сканирующая линия со шлейфом и «засканированной» подложкой
        k = min(max((p - 0.08) / 0.84, 0.0), 1.0)
        sy = y0 + ch * k
        bright = tuple(min(1.0, c + (1 - c) * 0.6) for c in self._rgb)
        cr.save()
        _rounded_rect(cr, x0 + 1, y0 + 1, cw - 2, ch - 2, rad)
        cr.clip()
        cr.set_source_rgba(*self._rgb, 0.10)
        cr.rectangle(x0, y0, cw, sy - y0)
        cr.fill()
        for i in range(9):
            a = (1 - i / 9) ** 2
            cr.set_source_rgba(*bright, a)
            cr.set_line_width(2.2 if i == 0 else 1.3)
            yy = sy - i * 2.3
            cr.move_to(x0, yy)
            cr.line_to(x0 + cw, yy)
            cr.stroke()
        cr.restore()

        # короткий глитч раз в цикл: контур карты расходится на два цветных
        if 0.50 < p < 0.56:
            g = math.sin((p - 0.50) / 0.06 * math.pi) * 2.2
            cr.set_line_width(1.4)
            cr.set_source_rgba(*bright, 0.45)
            _rounded_rect(cr, x0 + g, y0, cw, ch, rad)
            cr.stroke()
            cr.set_source_rgba(*self._rgb, 0.45)
            _rounded_rect(cr, x0 - g, y0 + 0.5, cw, ch, rad)
            cr.stroke()


class AuthDialog(Adw.Window):
    """Одно окно на один запрос аутентификации."""

    def __init__(self, ctx, on_done):
        super().__init__(title='Запрос доступа', resizable=False,
                         default_width=420, modal=False)
        self.add_css_class('dozor-auth')
        self.ctx = ctx            # dict со всем, что удалось узнать
        self.on_done = on_done    # callable(bool authorized, bool dismissed)
        self.session = None
        self._finished = False
        self._build()
        self.connect('close-request', self._on_close_request)

    # -- UI --

    def _build(self):
        c = self.ctx
        outer = Gtk.WindowHandle()
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14,
                      margin_top=22, margin_bottom=22, margin_start=22, margin_end=22)
        outer.set_child(box)
        self.set_content(outer)

        title = Gtk.Label(label=c['title'], wrap=True, justify=Gtk.Justification.CENTER)
        title.add_css_class('title-2')
        title.add_css_class('dozor-title')
        box.append(title)

        box.append(self._icon_chain())

        head = Gtk.Label(wrap=True, justify=Gtk.Justification.CENTER, use_markup=True)
        head.set_markup(c['headline'])
        box.append(head)

        if c.get('cmdline'):
            cmd = Gtk.Label(label=c['cmdline'], wrap=True,
                            justify=Gtk.Justification.CENTER, selectable=True,
                            max_width_chars=44)
            cmd.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
            cmd.add_css_class('dozor-cmd')
            cmd.add_css_class('dim-label')
            box.append(cmd)

        details = self._details_card()
        if details:
            box.append(details)

        # Зона метода аутентификации: иконка (пульсирует, пока ждём
        # палец/лицо/токен) + текст состояния. Прячется, когда нечего сказать.
        self.state_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8,
                                 halign=Gtk.Align.CENTER, visible=False)
        self.state_icon = Gtk.Image(pixel_size=32)
        self.state_icon.add_css_class('dozor-method-icon')
        self.state_label = Gtk.Label(wrap=True, justify=Gtk.Justification.CENTER,
                                     max_width_chars=40)
        self.state_label.add_css_class('dim-label')
        self.state_box.append(self.state_icon)
        self.state_anim = MethodAnimation()
        self.state_anim.set_visible(False)
        self.state_box.append(self.state_anim)
        self.state_box.append(self.state_label)
        box.append(self.state_box)

        # Поле пароля выезжает, только когда PAM реально просит пароль:
        # при биометрии диалог не пугает пустым полем.
        self.pw_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        self.pw_list.add_css_class('boxed-list')
        self.pw_row = Adw.PasswordEntryRow(title='Пароль', sensitive=False)
        self.pw_row.connect('entry-activated', lambda *_: self._submit())
        self.pw_list.append(self.pw_row)
        self.pw_revealer = Gtk.Revealer(
            child=self.pw_list, reveal_child=False,
            transition_type=Gtk.RevealerTransitionType.SLIDE_DOWN,
            transition_duration=250)
        box.append(self.pw_revealer)

        btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8,
                       margin_top=4, homogeneous=True)
        deny = Gtk.Button(label='Отклонить')
        deny.add_css_class('pill')
        deny.connect('clicked', lambda *_: self.dismiss())
        self.allow = Gtk.Button(label='Разрешить', sensitive=False)
        self.allow.add_css_class('pill')
        self.allow.add_css_class('suggested-action')
        self.allow.connect('clicked', lambda *_: self._submit())
        btns.append(deny)
        btns.append(self.allow)
        box.append(btns)
        self.set_default_widget(self.allow)

        esc = Gtk.ShortcutController()
        esc.add_shortcut(Gtk.Shortcut.new(
            Gtk.ShortcutTrigger.parse_string('Escape'),
            Gtk.CallbackAction.new(lambda *_: self.dismiss() or True)))
        self.add_controller(esc)

    def _icon_chain(self):
        c = self.ctx
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10,
                      halign=Gtk.Align.CENTER, margin_top=4, margin_bottom=4)
        app_icon = Gtk.Image(pixel_size=64)
        if c.get('app_info'):
            app_icon.set_from_gicon(c['app_info'].get_icon())
        else:
            app_icon.set_from_icon_name(icon_or(
                c.get('fallback_icon'), 'application-x-executable'))
        row.append(app_icon)

        for part in ('line', 'check', 'line'):
            if part == 'line':
                lbl = Gtk.Label(label='····')
                lbl.add_css_class('dozor-chain-line')
                row.append(lbl)
            else:
                chk = Gtk.Image(icon_name='emblem-ok-symbolic', pixel_size=18)
                chk.add_css_class('dozor-check')
                row.append(chk)

        lock = Gtk.Image(pixel_size=52, icon_name='security-high-symbolic')
        lock.add_css_class('dozor-lock')
        row.append(lock)
        return row

    def _details_card(self):
        c = self.ctx
        rows = c.get('detail_rows') or []
        if not rows and not c.get('focus_app_id'):
            return None
        lb = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        lb.add_css_class('boxed-list')
        exp = Adw.ExpanderRow(title='Подробности', expanded=True)
        exp.add_prefix(Gtk.Image(icon_name='utilities-terminal-symbolic'))
        for key, val in rows:
            r = Adw.ActionRow(title=key, subtitle=val, subtitle_selectable=True)
            r.add_css_class('property')
            exp.add_row(r)
        lb.append(exp)
        if c.get('focus_app_id') or (NIRI_SOCKET and c.get('caller_pid')):
            btn_row = Adw.ButtonRow(title='Показать окно приложения')
            btn_row.set_start_icon_name(
                icon_or('focus-windows-symbolic', 'window-restore-symbolic'))
            btn_row.connect('activated', self._focus_app)
            exp.add_row(btn_row)
        return lb

    def _focus_app(self, *_):
        # niri: точный фокус по pid через IPC. GNOME: метод нашего расширения
        # внутри gnome-shell (напрямую org.gnome.Shell.FocusApp чужим нельзя),
        # запасной путь — org.freedesktop.Application.Activate: DBus-активируемые
        # приложения (Ptyxis и большинство GNOME-приложений) поднимают окно сами.
        if NIRI_SOCKET and focus_niri_window(self.ctx.get('caller_pid')):
            return
        desktop_id = self.ctx.get('focus_app_id')
        if not desktop_id:
            return
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        try:
            bus.call_sync('org.gnome.Shell', '/ru/toxblh/Dozor',
                          'ru.toxblh.Dozor', 'FocusApp',
                          GLib.Variant('(s)', (desktop_id,)),
                          None, Gio.DBusCallFlags.NONE, 2000, None)
            return
        except GLib.Error as e:
            log('extension FocusApp failed:', e.message)
        app_id = desktop_id.removesuffix('.desktop')
        try:
            bus.call_sync(app_id, '/' + app_id.replace('.', '/').replace('-', '_'),
                          'org.freedesktop.Application', 'Activate',
                          GLib.Variant('(a{sv})', ({},)),
                          None, Gio.DBusCallFlags.NONE, 2000, None)
        except GLib.Error as e:
            log('Application.Activate failed:', e.message)

    # -- поток аутентификации --
    #
    # «И то и другое сразу»: пока PAM ждёт палец (pam_fprintd — серийный),
    # поле пароля тоже открыто. Ввёл пароль -> пишем одноразовый флаг
    # dozor-skip-fp, перезапускаем PAM-сессию; гейт lid-open.sh видит флаг,
    # пропускает отпечаток, и на запрос пароля отвечаем сохранённым вводом.

    def start_auth(self, identity, cookie):
        self._identity, self._cookie = identity, cookie
        self._stash = None
        self._new_session()

    def _new_session(self):
        self._pw_requested = False
        self.session = PolkitAgent.Session.new(self._identity, self._cookie)
        self.session.connect('request', self._on_request)
        self.session.connect('completed', self._on_completed)
        self.session.connect('show-error', self._on_show_error)
        self.session.connect('show-info', self._on_show_info)
        self.session.initiate()

    def _stale(self, session):
        return session is not self.session  # сигнал от отменённой нами сессии

    def _on_request(self, session, text, echo_on):
        if self._stale(session):
            return
        # PAM просит ввод. Обычно пароль; при pam_pkcs11/pam_u2f бывает PIN.
        log('pam request:', repr(text), 'echo:', echo_on)
        prompt = text.strip().rstrip(':').strip()
        low = prompt.lower()
        method, icon = classify_method(prompt)
        if method:
            # «приложите палец» и т.п. — пульсируем, но пароль тоже доступен
            self._set_state(icon, prompt, pulse=True, method=method)
            self._open_password_entry()
            return
        self._pw_requested = True
        if self._stash is not None:
            pw, self._stash = self._stash, None
            self._set_state(None, 'Проверка…')
            session.response(pw)
            return
        if 'pin' in low:
            self.pw_row.set_title('PIN-код')
        if low not in ('password', 'пароль', 'pin'):
            self._set_state(None, prompt)
        else:
            self._set_state(None, None)
        self._open_password_entry()

    def _open_password_entry(self):
        self.pw_revealer.set_reveal_child(True)
        self.pw_row.set_sensitive(True)
        self.allow.set_sensitive(True)
        self.pw_row.grab_focus()

    def _on_show_info(self, session, text):
        if self._stale(session):
            return
        # pam_fprintd и howdy шлют "Place your finger…" как PAM-info
        log('pam info:', repr(text))
        method, icon = classify_method(text)
        self._set_state(icon, text.strip(), pulse=bool(method), method=method)
        if method:
            self._open_password_entry()
            auto = os.environ.get('DOZOR_AUTO_SUBMIT')  # отладка пути «оба сразу»
            if auto:
                GLib.timeout_add(1500, lambda: (
                    self.pw_row.set_text(auto), self._submit(), False)[2])

    def _on_show_error(self, session, text):
        if self._stale(session):
            return
        self._set_state(None, text, error=True)

    def _submit(self):
        if not self.session or not self.pw_row.get_sensitive():
            return
        text = self.pw_row.get_text()
        if not self._pw_requested:
            # PAM ещё ждёт биометрию: флаг + перезапуск, пароль подставим сами
            if not text:
                return
            self._stash = text
            log('password typed during biometrics: skip-fp flag + PAM restart')
            try:
                open(SKIP_FP_FLAG, 'w').close()
            except OSError as e:
                log('skip-fp flag failed:', e)
            self.pw_row.set_sensitive(False)
            self.allow.set_sensitive(False)
            self._set_state(None, 'Проверка…')
            old, self.session = self.session, None
            old.cancel()
            self._new_session()
            return
        self.pw_row.set_sensitive(False)
        self.allow.set_sensitive(False)
        self._set_state(None, 'Проверка…')
        self.session.response(text)

    def _on_completed(self, session, gained):
        if self._stale(session):
            return
        log('pam completed, gained:', gained)
        self.session = None
        if gained:
            self._finish(True)
        elif self._finished:
            pass  # уже отклонили сами
        else:
            self._set_state(None, 'Не удалось подтвердить. Попробуйте ещё раз.',
                            error=True)
            self.pw_row.set_text('')
            self._shake(self.pw_list)
            self._new_session()

    def _set_state(self, icon_name, text, pulse=False, error=False, method=None):
        self.state_box.set_visible(bool(text))
        self.state_label.set_label(text or '')
        animated = method in MethodAnimation.PERIOD
        self.state_anim.set_visible(animated)
        if animated:
            self.state_anim.set_kind(method)
        self.state_icon.set_visible(bool(icon_name) and not animated)
        if icon_name and not animated:
            self.state_icon.set_from_icon_name(
                icon_or(icon_name, 'dialog-password-symbolic'))
        for widget, cls, on in (
                (self.state_icon, 'dozor-pulse', pulse),
                (self.state_icon, 'dozor-state-error', error),
                (self.state_label, 'dozor-state-error', error)):
            (widget.add_css_class if on else widget.remove_css_class)(cls)
        if error:
            self.state_label.remove_css_class('dim-label')
        else:
            self.state_label.add_css_class('dim-label')

    def _shake(self, widget):
        # лёгкое «нет-нет», как у GNOME Shell при неверном пароле
        target = Adw.CallbackAnimationTarget.new(
            lambda v: self._shake_step(widget, v))
        Adw.TimedAnimation.new(widget, 0.0, 1.0, 450, target).play()

    @staticmethod
    def _shake_step(widget, v):
        dx = int(math.sin(v * math.pi * 5) * 14 * (1.0 - v))
        widget.set_margin_start(max(0, dx))
        widget.set_margin_end(max(0, -dx))

    def dismiss(self):
        self._finish(False, dismissed=True)

    def _on_close_request(self, *_):
        if not self._finished:
            self._finish(False, dismissed=True)
        return False

    def _finish(self, authorized, dismissed=False):
        if self._finished:
            return
        log('finish: authorized =', authorized, 'dismissed =', dismissed)
        self._finished = True
        if self.session:
            self.session.cancel()
            self.session = None
        self.on_done(authorized, dismissed)
        self.close()


# --- сборка контекста для окна ---------------------------------------------

def build_ctx(action_id, message, icon_name, details):
    ctx = {'detail_rows': []}
    sudo_ctx = read_sudo_ctx() if action_id == SUDO_ACTION else None

    # polkitd сообщает агенту pid субъекта — процесса, от имени которого
    # запрошена авторизация. Это работает для любых действий, не только sudo.
    try:
        subject_pid = int(details.get('polkit.subject-pid', 0))
    except (TypeError, ValueError):
        subject_pid = 0

    if sudo_ctx:
        caller_pid = int(sudo_ctx.get('caller_pid', 0) or 0) or subject_pid
        app_info, app_name, app_pid = resolve_app(caller_pid) if caller_pid else (None, '?', 0)
        cmdline = sudo_ctx.get('cmdline', '')
        command = re.sub(r'^sudo\s+', '', cmdline)
        actor = actor_in_scope(caller_pid) if caller_pid else None
        who = f'<b>{GLib.markup_escape_text(app_name)}</b>'
        if actor and actor != proc_comm(app_pid) and actor.lower() not in app_name.lower():
            who = f'<b>{GLib.markup_escape_text(actor)}</b> из {who}'
        ctx.update(
            title='Требуется доступ администратора',
            headline=f'Разрешить {who} выполнить команду от имени <b>root</b>?',
            cmdline=command or cmdline,
            app_info=app_info,
            fallback_icon='utilities-terminal',
        )
        ctx['caller_pid'] = caller_pid
        if app_info:
            ctx['focus_app_id'] = app_info.get_id()
        rows = ctx['detail_rows']
        if cmdline:
            rows.append(('Команда', cmdline))
        start_pid = int(sudo_ctx.get('sudo_pid', 0) or 0) or caller_pid
        chain = proc_chain(start_pid) if start_pid else ''
        if chain:
            rows.append(('Процессы', chain))
        elif caller_pid:
            rows.append(('Процесс', f"{sudo_ctx.get('caller_comm', '?')} (pid {caller_pid})"))
        if sudo_ctx.get('cwd'):
            rows.append(('Каталог', home_relative(sudo_ctx['cwd'])))
        if sudo_ctx.get('tty'):
            rows.append(('Терминал', sudo_ctx['tty']))
        rows.append(('Пользователь', f"{sudo_ctx.get('pam_user') or GLib.get_user_name()} → root"))
        rows.append(('Действие polkit', action_id))
    else:
        app_info, app_name, matched_pid = \
            resolve_app(subject_pid) if subject_pid else (None, None, 0)
        ctx.update(
            title='Требуется подтверждение',
            headline=GLib.markup_escape_text(message or 'Приложение запрашивает права'),
            app_info=app_info,
            fallback_icon=icon_name or 'system-lock-screen',
        )
        ctx['caller_pid'] = subject_pid
        if app_info:
            ctx['focus_app_id'] = app_info.get_id()
        rows = ctx['detail_rows']
        if subject_pid:
            chain = proc_chain(subject_pid)
            rows.append(('Процессы', chain or f'pid {subject_pid}'))
            if app_name and app_name not in chain:
                rows.append(('Приложение', app_name))
        rows.append(('Действие polkit', action_id))
        # всё, что polkit передал агенту, показываем как есть — visibility прежде всего
        for key, val in details.items():
            if not key.startswith('polkit.'):
                rows.append((key, val))
    return ctx


# --- агент: собственная реализация DBus-интерфейса --------------------------
# PolkitAgent.Listener не используем: pygobject теряет user_data C-коллбека
# (server*) в async-vfunc, и libpolkit-agent падает в segfault при ответе.
# Реализуем org.freedesktop.PolicyKit1.AuthenticationAgent сами, как это
# делает GNOME Shell. PAM-часть остаётся на PolkitAgent.Session.

AGENT_PATH = '/ru/toxblh/DozorAgent'
AGENT_XML = """
<node>
 <interface name="org.freedesktop.PolicyKit1.AuthenticationAgent">
  <method name="BeginAuthentication">
   <arg type="s" name="action_id" direction="in"/>
   <arg type="s" name="message" direction="in"/>
   <arg type="s" name="icon_name" direction="in"/>
   <arg type="a{ss}" name="details" direction="in"/>
   <arg type="s" name="cookie" direction="in"/>
   <arg type="a(sa{sv})" name="identities" direction="in"/>
  </method>
  <method name="CancelAuthentication">
   <arg type="s" name="cookie" direction="in"/>
  </method>
 </interface>
</node>
"""


class Agent:
    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self.dialogs = {}  # cookie -> AuthDialog
        node = Gio.DBusNodeInfo.new_for_xml(AGENT_XML)
        self.bus.register_object(AGENT_PATH, node.interfaces[0],
                                 self._method_call, None, None)

    def _method_call(self, _bus, _sender, _path, _iface, method, params, invocation):
        if method == 'BeginAuthentication':
            self._begin(invocation, *params.unpack())
        elif method == 'CancelAuthentication':
            (cookie,) = params.unpack()
            dialog = self.dialogs.get(cookie)
            if dialog:
                dialog.dismiss()
            invocation.return_value(None)

    def _begin(self, invocation, action_id, message, icon_name, details,
               cookie, identities):
        log('auth request:', action_id, 'details:', details)
        identity = None
        for kind, props in identities:
            if kind == 'unix-user':
                identity = Polkit.UnixUser.new(props['uid'])
                if props['uid'] == os.getuid():
                    break
        # ponytail: без выбора учётки — текущий пользователь или первый unix-user
        if identity is None:
            invocation.return_dbus_error(
                'org.freedesktop.PolicyKit1.Error.Failed', 'no usable identity')
            return

        ctx = build_ctx(action_id, message, icon_name, details)
        dialog = AuthDialog(ctx, lambda ok, dismissed:
                            self._done(invocation, cookie, ok))
        self.dialogs[cookie] = dialog
        dialog.present()
        dialog.start_auth(identity, cookie)
        shot = os.environ.get('DOZOR_SHOT')
        if shot:
            GLib.timeout_add(800, lambda: screenshot(dialog, shot, None))

    def _done(self, invocation, cookie, authorized):
        # При успехе polkitd уже получил ответ от setuid-хелпера
        # (AuthenticationAgentResponse2); наш return лишь завершает метод.
        self.dialogs.pop(cookie, None)
        if authorized:
            invocation.return_value(None)
        else:
            invocation.return_dbus_error(
                'org.freedesktop.PolicyKit1.Error.Cancelled',
                'Запрос отклонён пользователем')

    # -- регистрация --

    def _subject_variant(self, test_pid=None):
        if test_pid:
            with open(f'/proc/{test_pid}/stat') as f:
                start = int(f.read().rsplit(')', 1)[1].split()[19])
            return ('unix-process', {
                'pid': GLib.Variant('u', test_pid),
                'start-time': GLib.Variant('t', start),
                'uid': GLib.Variant('i', os.getuid()),
            })
        session = Polkit.UnixSession.new_for_process_sync(os.getpid(), None)
        return ('unix-session',
                {'session-id': GLib.Variant('s', session.get_session_id())})

    def register(self, test_pid=None, delay=2):
        """Shell мог ещё не отпустить агент (расширение гасит его чуть позже
        старта) — ретраимся бесконечно, но не спамим в журнал."""
        subject = self._subject_variant(test_pid)
        locale = os.environ.get('LANG', 'ru_RU.UTF-8')
        args = GLib.Variant('((sa{sv})ss)', (subject, locale, AGENT_PATH))
        attempt = 0
        while True:
            try:
                self.bus.call_sync(
                    'org.freedesktop.PolicyKit1',
                    '/org/freedesktop/PolicyKit1/Authority',
                    'org.freedesktop.PolicyKit1.Authority',
                    'RegisterAuthenticationAgent', args,
                    None, Gio.DBusCallFlags.NONE, 5000, None)
                log('registered as polkit agent for', subject[0])
                return
            except GLib.Error as e:
                if attempt % 30 == 0:
                    log(f'register failed ({e.message}), retrying every {delay}s')
                attempt += 1
                time.sleep(delay)


def main():
    Adw.init()
    provider = Gtk.CssProvider()
    provider.load_from_data(CSS.encode())
    Gtk.StyleContext.add_provider_for_display(
        Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    loop = GLib.MainLoop()

    if '--demo' in sys.argv:
        demo(loop)
        loop.run()
        return

    agent = Agent()
    test_pid = None
    if '--test-pid' in sys.argv:
        test_pid = int(sys.argv[sys.argv.index('--test-pid') + 1])
        log(f'TEST MODE: agent only for pid {test_pid}')
    agent.register(test_pid)

    signal.signal(signal.SIGTERM, lambda *_: loop.quit())
    signal.signal(signal.SIGINT, lambda *_: loop.quit())
    loop.run()


def demo(loop):
    """Окно с реальным контекстом текущего терминала, без polkit. Для UI-итераций."""
    ppid = os.getppid()
    app_info, app_name, _ = resolve_app(ppid)
    ctx = {
        'title': 'Требуется доступ администратора',
        'headline': f'Разрешить <b>{GLib.markup_escape_text(app_name)}</b> '
                    f'выполнить команду от имени <b>root</b>?',
        'cmdline': 'systemctl restart nginx.service',
        'app_info': app_info,
        'fallback_icon': 'utilities-terminal',
        'action_icon': 'dialog-password-symbolic',
        'focus_app_id': app_info.get_id() if app_info else None,
        'detail_rows': [
            ('Команда', 'sudo systemctl restart nginx.service'),
            ('Процессы', proc_chain(ppid)),
            ('Каталог', '~/git/dozor'),
            ('Терминал', '/dev/pts/2'),
            ('Пользователь', 'toxblh → root'),
            ('Действие polkit', SUDO_ACTION),
        ],
    }
    dialog = AuthDialog(ctx, lambda ok, dismissed: loop.quit())
    if '--demo-movie' in sys.argv:
        demo_movie(dialog, sys.argv[sys.argv.index('--demo-movie') + 1], loop)
        dialog.present()
        return
    state = (sys.argv[sys.argv.index('--demo-state') + 1]
             if '--demo-state' in sys.argv else 'password')
    if state == 'password':
        dialog.pw_revealer.set_reveal_child(True)
        dialog.pw_row.set_sensitive(True)
        dialog.allow.set_sensitive(True)
    elif state == 'fingerprint':
        dialog._set_state('auth-fingerprint-symbolic',
                          'Приложите палец к сканеру', pulse=True)
    elif state == 'face':
        dialog._set_state('camera-web-symbolic',
                          'Смотрите в камеру…', pulse=True, method='face')
    elif state == 'token':
        dialog._set_state('auth-smartcard-symbolic',
                          'Коснитесь ключа безопасности', pulse=True, method='token')
    elif state == 'error':
        dialog.pw_revealer.set_reveal_child(True)
        dialog.pw_row.set_sensitive(True)
        dialog.allow.set_sensitive(True)
        dialog._set_state(None, 'Не удалось подтвердить. Попробуйте ещё раз.',
                          error=True)
        GLib.timeout_add(400, lambda: dialog._shake(dialog.pw_list) or False)
    dialog.present()

    if '--screenshot' in sys.argv:
        path = sys.argv[sys.argv.index('--screenshot') + 1]
        GLib.timeout_add(700, lambda: screenshot(dialog, path, loop))
    if '--record' in sys.argv:
        # покадровая запись текущего стейта: --record DIR N_FRAMES (75 мс/кадр)
        i = sys.argv.index('--record')
        outdir, n_frames = sys.argv[i + 1], int(sys.argv[i + 2])
        os.makedirs(outdir, exist_ok=True)
        t0 = time.monotonic() + 0.6

        def capture():
            idx = int((time.monotonic() - t0) / 0.075)
            if idx >= 0:
                screenshot(dialog, f'{outdir}/f{idx:04d}.png', None)
            if idx >= n_frames:
                loop.quit()
                return False
            return True
        GLib.timeout_add(75, capture)


def demo_movie(dialog, outdir, loop):
    """Кадры демо-сценария для GIF в README: палец → пароль → ошибка → успех."""
    os.makedirs(outdir, exist_ok=True)

    def reveal_password():
        dialog._set_state(None, None)
        dialog.pw_revealer.set_reveal_child(True)
        dialog.pw_row.set_sensitive(True)
        dialog.allow.set_sensitive(True)
        dialog.pw_row.grab_focus()

    def wrong_password():
        dialog.pw_row.set_text('')
        dialog._set_state(None, 'Не удалось подтвердить. Попробуйте ещё раз.',
                          error=True)
        dialog._shake(dialog.pw_list)

    def verifying():
        dialog._set_state(None, 'Проверка…')
        dialog.pw_row.set_sensitive(False)
        dialog.allow.set_sensitive(False)

    steps = [
        (100, lambda: dialog._set_state('auth-fingerprint-symbolic',
                                        'Приложите палец к сканеру', pulse=True)),
        (2400, reveal_password),
        (3200, lambda: dialog.pw_row.set_text('correct horse')),
        (4000, wrong_password),
        (5400, lambda: dialog.pw_row.set_text('battery staple')),
        (6200, verifying),
    ]
    t0 = time.monotonic()
    for t, fn in steps:
        GLib.timeout_add(t, lambda f=fn: (
            log(f'movie step at {time.monotonic() - t0:.2f}s'), f(), False)[2])

    frame = {'n': 0}

    def capture():
        # кадры нумеруем по реальному времени: сохранение PNG медленнее тика,
        # а gif собирается из равномерной шкалы
        idx = int((time.monotonic() - t0) / 0.075)
        screenshot(dialog, f'{outdir}/f{idx:04d}.png', None)
        frame['n'] = idx
        if idx > 93:
            loop.quit()
            return False
        return True

    GLib.timeout_add(75, capture)


def screenshot(widget, path, loop):
    try:
        paintable = Gtk.WidgetPaintable.new(widget)
        w, h = widget.get_width(), widget.get_height()
        snap = Gtk.Snapshot()
        paintable.snapshot(snap, w, h)
        node = snap.to_node()
        if node is None:
            raise RuntimeError('empty render node')
        texture = widget.get_native().get_renderer().render_texture(node, None)
        texture.save_to_png(path)
        log('screenshot saved:', path)
    except Exception as e:
        log('screenshot failed:', e)
    if loop:
        loop.quit()
    return False


if __name__ == '__main__':
    main()
