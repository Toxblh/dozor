/* Dozor — polkit authentication agent (секретное ядро), Vala.
 *
 * Архитектура разделения (модель OpenSSH):
 *  - ЭТОТ процесс держит пароль и говорит с polkit. Он НЕ парсит сырой /proc.
 *  - Провенанс («кто/что/откуда») собирает отдельный непривилегированный
 *    коллектор dozor-provenance без доступа к паролю; сюда приходит только
 *    короткий key=value, который читается GLib-строками (без ручных буферов).
 *
 * PolkitAgent.Listener здесь работает штатно (segfault был багом PyGObject):
 * PAM ведёт setuid polkit-agent-helper-1 через PolkitAgent.Session, он же
 * шлёт AuthenticationAgentResponse2; наш возврат лишь завершает вызов.
 */

const string SUDO_ACTION = "ru.toxblh.dozor.sudo";
const string AGENT_PATH  = "/ru/toxblh/DozorAgent";
// одноразовый флаг «пропусти отпечаток» — читает /etc/security/lid-open.sh
string skip_fp_flag () { return "/run/user/%d/dozor-skip-fp".printf ((int) Posix.getuid ()); }

const string CSS = """
window.dozor-auth { border-radius: 18px; }
.dozor-title { font-weight: 800; }
.dozor-cmd { font-family: monospace; font-size: 0.92em; }
.dozor-chain-line { color: alpha(currentColor, 0.35); font-weight: 700; letter-spacing: 3px; }
.dozor-check { color: @success_color; }
.dozor-lock { color: @accent_color; }
.dozor-method-icon { color: @accent_color; }
.dozor-state-error { color: @error_color; }
/* как в GNOME Shell: у поля пароля нет карандаша; 1px, т.к. 0 роняет ассерты */
.dozor-auth row.entry image.edit-icon { -gtk-icon-size: 1px; opacity: 0; min-width: 0; margin: 0; padding: 0; }
""";

/* --- провенанс от коллектора ------------------------------------------- */

class Provenance : Object {
    public string title = "Требуется подтверждение";
    public string headline = "";
    public string cmdline = "";
    public string app_name = "";
    public string app_icon = "";
    public string focus_app_id = "";
    public int caller_pid = 0;
    public int[] ancestors = {};
    public string[] row_keys = {};
    public string[] row_vals = {};

    public static Provenance collect (int subject_pid, string action_id, string message) {
        var p = new Provenance ();
        p.headline = Markup.escape_text (message.length > 0 ? message : "Приложение запрашивает права");
        // ре-exec самого себя: ОДИН артефакт для подписи/IMA, ДВА процесса в
        // рантайме — парсинг недоверенного /proc идёт без доступа к паролю
        try {
            var sp = new Subprocess (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE,
                                     "/proc/self/exe", "--collect", subject_pid.to_string (), action_id);
            string out_buf;
            sp.communicate_utf8 (null, null, out out_buf, null);
            foreach (var line in out_buf.split ("\n")) {
                var kv = line.split ("=", 2);
                if (kv.length != 2) continue;
                switch (kv[0]) {
                    case "title":        p.title = kv[1]; break;
                    case "headline":     p.headline = kv[1]; break;      // уже markup-escaped коллектором
                    case "cmdline":      p.cmdline = kv[1]; break;
                    case "app_name":     p.app_name = kv[1]; break;
                    case "app_icon":     p.app_icon = kv[1]; break;
                    case "focus_app_id": p.focus_app_id = kv[1]; break;
                    case "caller_pid":   p.caller_pid = int.parse (kv[1]); break;
                    case "ancestors":
                        foreach (var s in kv[1].split (",")) if (s.length > 0) p.ancestors += int.parse (s);
                        break;
                    case "row":
                        var r = kv[1].split ("\t", 2);
                        if (r.length == 2) { p.row_keys += r[0]; p.row_vals += r[1]; }
                        break;
                }
            }
        } catch (Error e) {
            warning ("provenance collector failed: %s", e.message);
            p.row_keys += "Действие polkit"; p.row_vals += action_id;
        }
        return p;
    }
}

/* --- окно аутентификации ----------------------------------------------- */

/* Содержимое окна с поддержкой «нет-нет» при неверном пароле.
 * На Wayland клиент НЕ может двигать своё окно (позиция — дело композитора),
 * поэтому трясём всё содержимое трансформом при отрисовке: визуально это
 * тряска всего окна, но без рефлоу и без обращений к композитору. */
class ShakeBox : Gtk.Box {
    double offset = 0;
    Adw.TimedAnimation? anim = null;   // держим ссылку, иначе соберётся GC

    public ShakeBox () {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 14);
    }

    public override void snapshot (Gtk.Snapshot snap) {
        if (offset == 0) { base.snapshot (snap); return; }
        snap.save ();
        Graphene.Point pt = { (float) offset, 0.0f };
        snap.translate (pt);
        base.snapshot (snap);
        snap.restore ();
    }

    public void shake () {
        var target = new Adw.CallbackAnimationTarget ((v) => {
            offset = Math.sin (v * Math.PI * 5) * 14 * (1.0 - v);
            queue_draw ();
        });
        anim = new Adw.TimedAnimation (this, 0, 1, 450, target);
        anim.done.connect (() => { offset = 0; queue_draw (); });
        anim.play ();
    }
}

class AuthDialog : Adw.Window {
    public signal void done (bool authorized);

    Provenance prov;
    Polkit.Identity identity;
    string cookie;
    PolkitAgent.Session? session = null;
    bool finished = false;
    bool pw_requested = false;
    bool saw_request = false;   // PAM хоть раз что-то спросил в этой сессии
    int attempts = 0;           // неудачных попыток подряд
    string? stash = null;   // пароль, введённый во время ожидания биометрии

    Adw.PasswordEntryRow pw_row;
    Gtk.Revealer pw_revealer;
    Gtk.Button allow;
    Gtk.Box state_box;
    Gtk.Image state_icon;
    MethodAnimation state_anim;
    Gtk.Label state_label;
    ShakeBox root_box;

    public AuthDialog (Provenance prov, Polkit.Identity identity, string cookie) {
        Object (title: "Запрос доступа", resizable: false, default_width: 420);
        this.prov = prov; this.identity = identity; this.cookie = cookie;
        add_css_class ("dozor-auth");
        build ();
        close_request.connect (() => { if (!finished) finish (false); return false; });
        var keys = new Gtk.EventControllerKey ();
        keys.key_pressed.connect ((kv, kc, st) => { if (kv == Gdk.Key.Escape) { dismiss (); return true; } return false; });
        ((Gtk.Widget) this).add_controller (keys);
    }

    void build () {
        var outer = new Gtk.WindowHandle ();
        root_box = new ShakeBox () {
            margin_top = 22, margin_bottom = 22, margin_start = 22, margin_end = 22 };
        var box = root_box;
        outer.child = box; content = outer;

        var title = new Gtk.Label (prov.title) { wrap = true, justify = Gtk.Justification.CENTER };
        title.add_css_class ("title-2"); title.add_css_class ("dozor-title");
        box.append (title);
        box.append (icon_chain ());

        var head = new Gtk.Label (null) { wrap = true, justify = Gtk.Justification.CENTER, use_markup = true };
        head.set_markup (prov.headline);
        box.append (head);

        if (prov.cmdline.length > 0) {
            var cmd = new Gtk.Label (prov.cmdline) { wrap = true, justify = Gtk.Justification.CENTER,
                selectable = true, max_width_chars = 44, wrap_mode = Pango.WrapMode.WORD_CHAR };
            cmd.add_css_class ("dozor-cmd"); cmd.add_css_class ("dim-label");
            box.append (cmd);
        }

        var details = details_card ();
        if (details != null) box.append (details);

        state_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) { halign = Gtk.Align.CENTER, visible = false };
        state_icon = new Gtk.Image () { pixel_size = 32 };
        state_icon.add_css_class ("dozor-method-icon");
        state_anim = new MethodAnimation ();
        state_anim.visible = false;
        state_label = new Gtk.Label (null) { wrap = true, justify = Gtk.Justification.CENTER, max_width_chars = 40 };
        state_label.add_css_class ("dim-label");
        state_box.append (state_icon); state_box.append (state_anim); state_box.append (state_label);
        box.append (state_box);

        var pw_list = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE };
        pw_list.add_css_class ("boxed-list");
        pw_row = new Adw.PasswordEntryRow () { title = "Пароль", sensitive = false };
        pw_row.entry_activated.connect (submit);
        pw_list.append (pw_row);
        pw_revealer = new Gtk.Revealer () { child = pw_list, reveal_child = false,
            transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN, transition_duration = 250 };
        box.append (pw_revealer);

        var btns = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) { homogeneous = true, margin_top = 4 };
        var deny = new Gtk.Button.with_label ("Отклонить");
        deny.add_css_class ("pill");
        deny.clicked.connect (dismiss);
        allow = new Gtk.Button.with_label ("Разрешить") { sensitive = false };
        allow.add_css_class ("pill"); allow.add_css_class ("suggested-action");
        allow.clicked.connect (submit);
        btns.append (deny); btns.append (allow);
        box.append (btns);
        default_widget = allow;
    }

    Gtk.Widget icon_chain () {
        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) { halign = Gtk.Align.CENTER, margin_top = 4, margin_bottom = 4 };
        var app = new Gtk.Image () { pixel_size = 64 };
        if (prov.app_icon.length > 0) {
            try { app.gicon = Icon.new_for_string (prov.app_icon); }
            catch (Error e) { app.icon_name = "application-x-executable"; }
        } else app.icon_name = "utilities-terminal";
        row.append (app);
        var l1 = new Gtk.Label ("····"); l1.add_css_class ("dozor-chain-line"); row.append (l1);
        var chk = new Gtk.Image.from_icon_name ("emblem-ok-symbolic") { pixel_size = 18 };
        chk.add_css_class ("dozor-check"); row.append (chk);
        var l2 = new Gtk.Label ("····"); l2.add_css_class ("dozor-chain-line"); row.append (l2);
        var shield = new Gtk.Image.from_icon_name ("security-high-symbolic") { pixel_size = 52 };
        shield.add_css_class ("dozor-lock"); row.append (shield);
        return row;
    }

    Gtk.Widget? details_card () {
        if (prov.row_keys.length == 0 && prov.focus_app_id.length == 0) return null;
        var lb = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE };
        lb.add_css_class ("boxed-list");
        var exp = new Adw.ExpanderRow () { title = "Подробности", expanded = true };
        exp.add_prefix (new Gtk.Image.from_icon_name ("utilities-terminal-symbolic"));
        for (int i = 0; i < prov.row_keys.length; i++) {
            var r = new Adw.ActionRow () { title = prov.row_keys[i], subtitle = prov.row_vals[i], subtitle_selectable = true };
            r.add_css_class ("property");
            exp.add_row (r);
        }
        if (prov.focus_app_id.length > 0) {
            var b = new Adw.ButtonRow () { title = "Показать окно приложения", start_icon_name = "focus-windows-symbolic" };
            b.activated.connect (focus_app);
            exp.add_row (b);
        }
        lb.append (exp);
        return lb;
    }

    void focus_app () { Focus.focus (prov.ancestors, prov.focus_app_id); }

    /* --- поток аутентификации --- */

    public void start () { new_session (); }

    void new_session () {
        pw_requested = false;
        saw_request = false;
        var s = new PolkitAgent.Session (identity, cookie);
        session = s;
        s.request.connect ((req, echo) => { if (s == session) on_request (req); });
        s.completed.connect ((gained) => { if (s == session) on_completed (gained); });
        s.show_info.connect ((t) => { if (s == session) on_info (t); });
        s.show_error.connect ((t) => { if (s == session) set_state (null, t, true); });
        s.initiate ();
    }

    /* Метод аутентификации определяем по тексту PAM-разговора:
     * pam_fprintd, howdy и pam_u2f/pam_pkcs11 говорят разными фразами. */
    static string? method_icon (string text, out MethodAnimation.Kind kind) {
        kind = MethodAnimation.Kind.NONE;
        var low = text.down ();
        if (low.contains ("finger") || low.contains ("палец") || low.contains ("отпечат")
            || low.contains ("swipe") || low.contains ("fprint"))
            return "auth-fingerprint-symbolic";                 // пульс иконки темы
        if (low.contains ("face") || low.contains ("лицо") || low.contains ("camera")
            || low.contains ("камер") || low.contains ("howdy")) {
            kind = MethodAnimation.Kind.FACE; return null;      // рисуем визир
        }
        if (low.contains ("security key") || low.contains ("yubikey") || low.contains ("token")
            || low.contains ("токен") || low.contains ("card") || low.contains ("карт")
            || low.contains ("insert") || low.contains ("touch your") || low.contains ("u2f")
            || low.contains ("fido")) {
            kind = MethodAnimation.Kind.TOKEN; return null;     // рисуем карту со сканом
        }
        return null;
    }

    void on_request (string text) {
        saw_request = true;
        var prompt = text.strip ();
        if (prompt.has_suffix (":")) prompt = prompt[0:prompt.length - 1].strip ();
        MethodAnimation.Kind kind;
        var icon = method_icon (prompt, out kind);
        if (icon != null || kind != MethodAnimation.Kind.NONE) {
            set_state (icon, prompt, false, kind);   // биометрия/токен: ввода не ждут
            open_password ();                        // но пароль доступен параллельно
            return;
        }
        pw_requested = true;
        if (prompt.down ().contains ("pin")) pw_row.title = "PIN-код";
        if (stash != null) {                       // пароль набрали, пока ждали палец — отдаём сразу
            var p = stash; stash = null;
            set_state (null, "Проверка…", false);
            session.response (p);
            return;
        }
        var low = prompt.down ();
        set_state (null, (low == "password" || low == "пароль" || low == "pin") ? null : prompt, false);
        open_password ();
    }

    void on_info (string text) {
        MethodAnimation.Kind kind;
        var icon = method_icon (text, out kind);
        set_state (icon, text.strip (), false, kind);
        if (icon != null || kind != MethodAnimation.Kind.NONE) open_password ();  // «и то и другое сразу»
    }

    void open_password () {
        pw_revealer.reveal_child = true;
        pw_row.sensitive = true; allow.sensitive = true;
        pw_row.grab_focus ();
    }

    void submit () {
        if (session == null || !pw_row.sensitive) return;
        var text = pw_row.text;
        if (!pw_requested) {
            // PAM ещё ждёт палец: флаг «без отпечатка» + перезапуск разговора
            if (text.length == 0) return;
            stash = text;
            try { FileUtils.set_contents (skip_fp_flag (), ""); } catch (Error e) { warning ("skip-fp: %s", e.message); }
            pw_row.sensitive = false; allow.sensitive = false;
            set_state (null, "Проверка…", false);
            var old = session; session = null; old.cancel ();
            new_session ();
            return;
        }
        pw_row.sensitive = false; allow.sensitive = false;
        set_state (null, "Проверка…", false);
        session.response (text);
        pw_row.text = "";    // ponytail: GLib-строка не затирается; secure buffer живёт в GtkPasswordEntry
    }

    void on_completed (bool gained) {
        session = null;
        if (gained) { finish (true); return; }
        if (finished) return;

        // Сессия завершилась, ни о чём не спросив, — это системная поломка
        // (например, setuid-бит у polkit-agent-helper-1 недоступен из-за
        // NoNewPrivileges), а не неверный пароль. Повтор тут только сожжёт CPU.
        if (!saw_request) {
            set_state (null, "Аутентификация недоступна. Смотрите журнал: " +
                             "journalctl --user -u dozor", true);
            pw_revealer.reveal_child = false;
            allow.sensitive = false;
            return;
        }
        if (++attempts >= 3) {
            set_state (null, "Слишком много неудачных попыток.", true);
            pw_revealer.reveal_child = false;
            allow.sensitive = false;
            return;
        }
        set_state (null, "Не удалось подтвердить. Попробуйте ещё раз.", true);
        pw_row.text = "";
        root_box.shake ();          // «нет-нет» всем содержимым окна
        new_session ();
    }

    void set_state (string? icon, string? text, bool error,
                    MethodAnimation.Kind kind = MethodAnimation.Kind.NONE) {
        state_box.visible = text != null;
        state_label.label = text ?? "";
        var animated = kind != MethodAnimation.Kind.NONE;
        state_anim.visible = animated;
        if (animated) state_anim.set_kind (kind);
        state_icon.visible = icon != null && !animated;
        if (icon != null && !animated) state_icon.icon_name = icon;
        if (error) { state_label.add_css_class ("dozor-state-error"); state_label.remove_css_class ("dim-label"); }
        else       { state_label.remove_css_class ("dozor-state-error"); state_label.add_css_class ("dim-label"); }
    }

    public void dismiss () { finish (false); }

    void finish (bool authorized) {
        if (finished) return;
        finished = true;
        if (session != null) { session.cancel (); session = null; }
        done (authorized);
        close ();
    }
}

/* --- listener ------------------------------------------------------------ */

class DozorListener : PolkitAgent.Listener {
    public override async bool initiate_authentication (string action_id, string message, string icon_name,
            Polkit.Details details, string cookie, GLib.List<Polkit.Identity> identities,
            Cancellable? cancellable = null) throws Error {
        GLib.message ("auth request: %s", action_id);   // GLib.: параметр `message` затеняет функцию
        Polkit.Identity? ident = null;
        foreach (var i in identities) {
            var u = i as Polkit.UnixUser;
            if (u != null && u.get_uid () == (int) Posix.getuid ()) { ident = i; break; }
        }
        if (ident == null && identities != null) ident = identities.data;   // ponytail: без выбора учётки
        if (ident == null) throw new IOError.FAILED ("no usable identity");

        var subject_pid = int.parse (details.lookup ("polkit.subject-pid") ?? "0");
        var prov = Provenance.collect (subject_pid, action_id, message);
        var dlg = new AuthDialog (prov, ident, cookie);
        bool ok = false;
        dlg.done.connect ((authorized) => { ok = authorized; initiate_authentication.callback (); });
        if (cancellable != null) cancellable.cancelled.connect (() => dlg.dismiss ());
        dlg.present ();
        dlg.start ();
        var shot = Environment.get_variable ("DOZOR_SHOT");
        if (shot != null)
            Timeout.add (800, () => { screenshot (dlg, shot); return false; });
        yield;
        if (!ok) throw new IOError.CANCELLED ("Запрос отклонён пользователем");
        return true;
    }
}

/* --- запуск ---------------------------------------------------------------- */

/* Снимок окна изнутри приложения: Shell не пускает посторонних к
 * org.gnome.Shell.Screenshot (AccessDenied), поэтому рендерим виджет сами. */
bool screenshot (Gtk.Widget w, string path) {
    var paintable = new Gtk.WidgetPaintable (w);
    var snap = new Gtk.Snapshot ();
    paintable.snapshot (snap, w.get_width (), w.get_height ());
    var node = snap.to_node ();
    if (node == null) { warning ("screenshot: пустой render node"); return false; }
    try {
        var tex = w.get_native ().get_renderer ().render_texture (node, null);
        tex.save_to_png (path);
        GLib.message ("screenshot saved: %s", path);
    } catch (Error e) { warning ("screenshot: %s", e.message); return false; }
    return true;
}

int main (string[] args) {
    // режим коллектора — до всякого GTK: отдельный процесс, без пароля и без UI
    for (int i = 1; i < args.length; i++)
        if (args[i] == "--collect")
            return Collector.run (args.length > i + 1 ? int.parse (args[i + 1]) : 0,
                                  args.length > i + 2 ? args[i + 2] : "");

    Gtk.init (); Adw.init ();
    var css = new Gtk.CssProvider (); css.load_from_string (CSS);
    Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

    Polkit.Subject subject;
    int test_pid = 0;
    for (int i = 1; i < args.length - 1; i++) if (args[i] == "--test-pid") test_pid = int.parse (args[i + 1]);
    try {
        if (test_pid > 0) {
            subject = new Polkit.UnixProcess.for_owner (test_pid, 0, (int) Posix.getuid ());  // не конфликтует с агентом Shell
            message ("TEST MODE: agent only for pid %d", test_pid);
        } else subject = new Polkit.UnixSession.for_process_sync ((int) Posix.getpid ());
    } catch (Error e) { printerr ("subject: %s\n", e.message); return 1; }

    var listener = new DozorListener ();
    int attempt = 0;
    // Shell мог ещё не отпустить агент — ретраимся бесконечно, тихо
    Timeout.add_seconds (1, () => {
        try { listener.register (PolkitAgent.RegisterFlags.NONE, subject, AGENT_PATH); message ("registered as polkit agent"); return false; }
        catch (Error e) { if (attempt++ % 30 == 0) message ("register failed (%s), retrying", e.message); return true; }
    });
    new MainLoop ().run ();
    return 0;
}
