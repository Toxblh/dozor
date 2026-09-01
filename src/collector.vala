/* Dozor — сбор провенанса. НЕПРИВИЛЕГИРОВАННЫЙ РЕЖИМ, БЕЗ ДОСТУПА К ПАРОЛЮ.
 *
 * Запускается как отдельный процесс (`dozor-agent --collect <pid> <action>`)
 * ре-exec'ом того же бинаря: один артефакт для подписи и IMA-appraisal, но
 * два процесса в рантайме (модель OpenSSH).
 *
 * Здесь и только здесь парсятся данные, которые контролирует атакующий:
 * comm/cmdline/cgroup чужих same-user процессов и ctx-файл от PAM-хука.
 * Порвали этот процесс — атакующий получил свои же данные; пароля тут нет.
 * Наружу отдаётся строгий key=value, который агент читает GLib-строками.
 */

namespace Collector {

const string SUDO_ACTION = "ru.toxblh.dozor.sudo";
const int CTX_MAX_AGE = 20;   // секунд; более старый ctx считаем чужим/протухшим

string? read_file (string path) {
    try { string c; FileUtils.get_contents (path, out c); return c; }
    catch (FileError e) { return null; }
}

int proc_ppid (int pid) {
    // поля после "pid (comm) ": 1=state, 2=ppid; режем по ПОСЛЕДНЕЙ ')',
    // иначе пробелы в comm сдвигают нумерацию
    var s = read_file ("/proc/%d/stat".printf (pid));
    if (s == null) return 0;
    var idx = s.last_index_of (")");
    if (idx < 0) return 0;
    var f = s.substring (idx + 1).strip ().split (" ");
    return f.length > 1 ? int.parse (f[1]) : 0;
}

string? proc_comm (int pid) {
    var s = read_file ("/proc/%d/comm".printf (pid));
    return s == null ? null : s.strip ();
}

string proc_cgroup (int pid) {
    var s = read_file ("/proc/%d/cgroup".printf (pid));
    if (s == null) return "";
    var lines = s.strip ().split ("\n");
    return lines.length > 0 ? lines[lines.length - 1] : "";
}

// app-gnome-org.gnome.Ptyxis-2288.scope / app-flatpak-org.gimp.GIMP-33.scope
DesktopAppInfo? resolve_app (int pid, out string name, out int app_pid) {
    name = proc_comm (pid) ?? "?";
    app_pid = pid;
    try {
        var re = new Regex ("app-(?:gnome-|flatpak-|wayland-|KDE-)?(.+?)(?:-[0-9]+)?\\.scope$");
        int cur = pid;
        for (int hops = 0; cur > 1 && hops < 12; hops++) {
            var cg = proc_cgroup (cur);
            var unit = cg.substring (cg.last_index_of ("/") + 1);
            string? app_id = null;
            MatchInfo mi;
            if (re.match (unit, 0, out mi)) app_id = mi.fetch (1).replace ("\\x2d", "-");
            // Ptyxis запускает шеллы в своих scope вне app.slice — особый случай
            else if (unit.has_prefix ("ptyxis-spawn-")) app_id = "org.gnome.Ptyxis";
            if (app_id != null) {
                app_pid = cur;
                var info = new DesktopAppInfo (app_id + ".desktop");
                if (info != null) { name = info.get_display_name (); return info; }
                name = app_id;
                return null;
            }
            cur = proc_ppid (cur);
        }
    } catch (RegexError e) { warning ("regex: %s", e.message); }
    return null;
}

string proc_chain (int pid, int limit = 10) {
    var sb = new StringBuilder ();
    int cur = pid;
    for (int n = 0; cur > 1 && n < limit; n++) {
        var comm = proc_comm (cur);
        if (comm == null || comm == "systemd" || comm == "init") break;
        if (sb.len > 0) sb.append (" ← ");
        sb.append ("%s (%d)".printf (comm, cur));
        cur = proc_ppid (cur);
    }
    return sb.str;
}

// обёртки, которые ничего не говорят о том, кто на самом деле действует
const string[] TRIVIAL = { "sudo", "timeout", "sh", "bash", "zsh", "fish", "dash",
                           "env", "nice", "ionice", "doas", "time", "xargs", "script", "su" };

string? actor_in_scope (int pid) {
    var scope = proc_cgroup (pid);
    int cur = pid;
    for (int hops = 0; cur > 1 && hops < 12 && proc_cgroup (cur) == scope; hops++) {
        var comm = proc_comm (cur);
        if (comm != null && !(comm in TRIVIAL)) return comm;
        cur = proc_ppid (cur);
    }
    return null;
}

HashTable<string, string>? read_sudo_ctx () {
    var path = "/run/user/%d/dozor.ctx".printf ((int) Posix.getuid ());
    var raw = read_file (path);
    if (raw == null) return null;
    FileUtils.unlink (path);
    var kv = new HashTable<string, string> (str_hash, str_equal);
    foreach (var line in raw.split ("\n")) {
        var p = line.split ("=", 2);
        if (p.length == 2) kv.insert (p[0], p[1]);
    }
    var ts = int64.parse (kv.lookup ("ts") ?? "0");
    if (new DateTime.now_utc ().to_unix () - ts > CTX_MAX_AGE) return null;
    var b64 = kv.lookup ("sudo_cmdline_b64");
    if (b64 != null) {
        var bytes = Base64.decode (b64);
        var sb = new StringBuilder ();
        foreach (var b in bytes) sb.append_c (b >= 32 || b == 9 ? (char) b : ' ');
        kv.insert ("cmdline", sb.str.strip ());
    }
    return kv;
}

string home_relative (string p) {
    var h = Environment.get_home_dir ();
    return p.has_prefix (h) ? "~" + p.substring (h.length) : p;
}

string flat (string s) { return s.replace ("\n", " ").replace ("\r", " ").replace ("\t", " "); }

/* Печатает key=value; строки деталей — row=<ключ>\t<значение>. */
public int run (int subject_pid, string action_id) {
    var o = new StringBuilder ();
    var keys = new GenericArray<string> ();
    var vals = new GenericArray<string> ();

    var ctx = action_id == SUDO_ACTION ? read_sudo_ctx () : null;
    string app_name = ""; int app_pid = 0;
    DesktopAppInfo? info = null;

    if (ctx != null) {
        int caller = int.parse (ctx.lookup ("caller_pid") ?? "0");
        if (caller == 0) caller = subject_pid;
        info = resolve_app (caller, out app_name, out app_pid);
        var actor = caller > 0 ? actor_in_scope (caller) : null;
        var who = "<b>%s</b>".printf (Markup.escape_text (app_name));
        // заголовок называет реального инициатора, пропуская обёртки и шеллы
        if (actor != null && actor != proc_comm (app_pid)
            && !app_name.down ().contains (actor.down ()))
            who = "<b>%s</b> из %s".printf (Markup.escape_text (actor), who);

        var cmdline = ctx.lookup ("cmdline") ?? "";
        o.append ("title=Требуется доступ администратора\n");
        o.append ("headline=Разрешить %s выполнить команду от имени <b>root</b>?\n".printf (who));
        var shown = cmdline.has_prefix ("sudo ") ? cmdline.substring (5) : cmdline;
        o.append ("cmdline=%s\n".printf (flat (shown)));
        o.append ("caller_pid=%d\n".printf (caller));

        int start = int.parse (ctx.lookup ("sudo_pid") ?? "0");
        if (start == 0) start = caller;
        if (cmdline.length > 0) { keys.add ("Команда"); vals.add (cmdline); }
        var chain = start > 0 ? proc_chain (start) : "";
        if (chain.length > 0) { keys.add ("Процессы"); vals.add (chain); }
        var cwd = ctx.lookup ("cwd");
        if (cwd != null && cwd.length > 0) { keys.add ("Каталог"); vals.add (home_relative (cwd)); }
        var tty = ctx.lookup ("tty");
        if (tty != null && tty.length > 0) { keys.add ("Терминал"); vals.add (tty); }
        keys.add ("Пользователь");
        vals.add ("%s → root".printf (ctx.lookup ("pam_user") ?? Environment.get_user_name ()));
    } else {
        info = subject_pid > 0 ? resolve_app (subject_pid, out app_name, out app_pid)
                               : null;
        if (subject_pid <= 0) app_name = "";
        o.append ("title=Требуется подтверждение\n");
        o.append ("caller_pid=%d\n".printf (subject_pid));
        if (subject_pid > 0) {
            var chain = proc_chain (subject_pid);
            keys.add ("Процессы"); vals.add (chain.length > 0 ? chain : "pid %d".printf (subject_pid));
            if (app_name.length > 0 && !chain.contains (app_name)) {
                keys.add ("Приложение"); vals.add (app_name);
            }
        }
    }
    keys.add ("Действие polkit"); vals.add (action_id);

    if (info != null) {
        o.append ("app_name=%s\n".printf (flat (app_name)));
        var icon = info.get_icon ();
        if (icon != null) o.append ("app_icon=%s\n".printf (icon.to_string ()));
        o.append ("focus_app_id=%s\n".printf (info.get_id ()));
    }
    for (int i = 0; i < keys.length; i++)
        o.append ("row=%s\t%s\n".printf (flat (keys[i]), flat (vals[i])));

    stdout.write (o.str.data);
    return 0;
}

}
