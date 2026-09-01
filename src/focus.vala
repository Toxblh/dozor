/* Dozor — «показать окно приложения» на любом Wayland-композиторе.
 *
 * Порядок попыток (первая сработавшая выигрывает):
 *   1. niri / Hyprland / sway — точный фокус ПО PID через их IPC. Самый верный
 *      путь: находим окно, чей pid есть в цепочке предков вызвавшего процесса.
 *   2. GNOME Shell — через метод нашего расширения (напрямую
 *      org.gnome.Shell.FocusApp посторонним запрещён: AccessDenied).
 *   3. org.freedesktop.Application.Activate — работает на любом композиторе
 *      для DBus-активируемых приложений (большинство GNOME/KDE-приложений).
 *
 * Цепочку предков считает коллектор (там же, где весь парсинг /proc);
 * сюда она приходит готовым списком pid'ов.
 */

namespace Focus {

/* Запустить команду и вернуть stdout, или null. */
string? run_cmd (string[] argv) {
    try {
        var sp = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
        string out_buf;
        sp.communicate_utf8 (null, null, out out_buf, null);
        return sp.get_successful () ? out_buf : null;
    } catch (Error e) { return null; }
}

bool pid_matches (int64 pid, int[] ancestors) {
    foreach (var a in ancestors) if (a == (int) pid) return true;
    return false;
}

/* --- niri --- */
bool try_niri (int[] ancestors) {
    if (Environment.get_variable ("NIRI_SOCKET") == null) return false;
    var json = run_cmd ({ "niri", "msg", "-j", "windows" });
    if (json == null) return false;
    try {
        var parser = new Json.Parser ();
        parser.load_from_data (json);
        var arr = parser.get_root ().get_array ();
        if (arr == null) return false;
        for (uint i = 0; i < arr.get_length (); i++) {
            var o = arr.get_object_element (i);
            if (o == null || !o.has_member ("pid") || !o.has_member ("id")) continue;
            if (pid_matches (o.get_int_member ("pid"), ancestors)) {
                run_cmd ({ "niri", "msg", "action", "focus-window",
                           "--id", o.get_int_member ("id").to_string () });
                return true;
            }
        }
    } catch (Error e) { warning ("niri: %s", e.message); }
    return false;
}

/* --- Hyprland --- */
bool try_hyprland (int[] ancestors) {
    if (Environment.get_variable ("HYPRLAND_INSTANCE_SIGNATURE") == null) return false;
    var json = run_cmd ({ "hyprctl", "-j", "clients" });
    if (json == null) return false;
    try {
        var parser = new Json.Parser ();
        parser.load_from_data (json);
        var arr = parser.get_root ().get_array ();
        if (arr == null) return false;
        for (uint i = 0; i < arr.get_length (); i++) {
            var o = arr.get_object_element (i);
            if (o == null || !o.has_member ("pid") || !o.has_member ("address")) continue;
            if (pid_matches (o.get_int_member ("pid"), ancestors)) {
                run_cmd ({ "hyprctl", "dispatch", "focuswindow",
                           "address:" + o.get_string_member ("address") });
                return true;
            }
        }
    } catch (Error e) { warning ("hyprland: %s", e.message); }
    return false;
}

/* --- sway (дерево рекурсивное) --- */
bool sway_walk (Json.Node node, int[] ancestors) {
    var o = node.get_object ();
    if (o == null) return false;
    if (o.has_member ("pid") && o.has_member ("id")
        && pid_matches (o.get_int_member ("pid"), ancestors)) {
        run_cmd ({ "swaymsg", "[con_id=%s] focus".printf (o.get_int_member ("id").to_string ()) });
        return true;
    }
    foreach (var key in new string[] { "nodes", "floating_nodes" }) {
        if (!o.has_member (key)) continue;
        var arr = o.get_array_member (key);
        if (arr == null) continue;
        for (uint i = 0; i < arr.get_length (); i++)
            if (sway_walk (arr.get_element (i), ancestors)) return true;
    }
    return false;
}

bool try_sway (int[] ancestors) {
    if (Environment.get_variable ("SWAYSOCK") == null) return false;
    var json = run_cmd ({ "swaymsg", "-t", "get_tree" });
    if (json == null) return false;
    try {
        var parser = new Json.Parser ();
        parser.load_from_data (json);
        return sway_walk (parser.get_root (), ancestors);
    } catch (Error e) { warning ("sway: %s", e.message); return false; }
}

/* --- GNOME Shell через наше расширение --- */
bool try_gnome (string desktop_id) {
    if (desktop_id.length == 0) return false;
    try {
        var bus = Bus.get_sync (BusType.SESSION);
        bus.call_sync ("org.gnome.Shell", "/ru/toxblh/Dozor", "ru.toxblh.Dozor", "FocusApp",
                       new Variant ("(s)", desktop_id), null, DBusCallFlags.NONE, 2000);
        return true;
    } catch (Error e) { return false; }
}

/* --- универсальный фолбэк: DBus-активация приложения --- */
bool try_activate (string desktop_id) {
    if (desktop_id.length == 0) return false;
    var app_id = desktop_id.has_suffix (".desktop")
        ? desktop_id.substring (0, desktop_id.length - 8) : desktop_id;
    var path = "/" + app_id.replace (".", "/").replace ("-", "_");
    try {
        var bus = Bus.get_sync (BusType.SESSION);
        bus.call_sync (app_id, path, "org.freedesktop.Application", "Activate",
                       new Variant ("(a{sv})", new VariantDict ().end ()),
                       null, DBusCallFlags.NONE, 2000);
        return true;
    } catch (Error e) { warning ("Application.Activate: %s", e.message); return false; }
}

public void focus (int[] ancestors, string desktop_id) {
    if (try_niri (ancestors)) return;
    if (try_hyprland (ancestors)) return;
    if (try_sway (ancestors)) return;
    if (try_gnome (desktop_id)) return;
    try_activate (desktop_id);
}

}
