/* Dozor — рисованные зацикленные анимации методов аутентификации (Cairo).
 *
 * face  — визир из четырёх уголков; лицо выезжает снизу, улыбается, уходит.
 * token — смарт-карта с чипом, сканирующая линия со шлейфом, мерцание данных
 *         и короткий «глитч» контура раз в цикл.
 * Цвет берётся из CSS (@accent_color через .dozor-method-icon), поэтому
 * анимация follows тему и акцент пользователя.
 */

double ease_out (double x) { return 1 - Math.pow (1 - x, 3); }
double ease_in  (double x) { return x * x * x; }

void rounded_rect (Cairo.Context cr, double x, double y, double w, double h, double r) {
    cr.new_sub_path ();
    cr.arc (x + w - r, y + r,     r, -Math.PI / 2, 0);
    cr.arc (x + w - r, y + h - r, r, 0, Math.PI / 2);
    cr.arc (x + r,     y + h - r, r, Math.PI / 2, Math.PI);
    cr.arc (x + r,     y + r,     r, Math.PI, 3 * Math.PI / 2);
    cr.close_path ();
}

public class MethodAnimation : Gtk.DrawingArea {
    public enum Kind { NONE, FACE, TOKEN }

    Kind kind = Kind.NONE;
    double r = 0;
    double g = 0;
    double b = 0;

    public MethodAnimation (int size = 52) {
        Object (content_width: size, content_height: size,
                halign: Gtk.Align.CENTER, valign: Gtk.Align.CENTER);
        add_css_class ("dozor-method-icon");
        set_draw_func (draw);
        add_tick_callback ((w, clock) => { queue_draw (); return Source.CONTINUE; });
    }

    public void set_kind (Kind k) { kind = k; queue_draw (); }

    /* Фаза 0..1 от времени кадра: без таймеров, ровно и без дрейфа. */
    double phase () {
        var clock = get_frame_clock ();
        double t = clock == null ? 0 : clock.get_frame_time () / 1e6;
        double period = kind == Kind.FACE ? 3.6 : 2.4;
        return (t % period) / period;
    }

    void draw (Gtk.DrawingArea area, Cairo.Context cr, int w, int h) {
        if (kind == Kind.NONE) return;
        var c = get_color ();
        r = c.red; g = c.green; b = c.blue;
        cr.set_source_rgba (r, g, b, 1.0);
        cr.set_line_width (2.2);
        cr.set_line_cap (Cairo.LineCap.ROUND);
        cr.set_line_join (Cairo.LineJoin.ROUND);
        if (kind == Kind.FACE) draw_face (cr, w, h, phase ());
        else draw_token (cr, w, h, phase ());
    }

    void draw_face (Cairo.Context cr, int w, int h, double p) {
        double s = double.min (w, h);
        double m = s * 0.06, L = s * 0.24;
        // визир: четыре уголка
        double[,] corners = {{ m, m, 1, 1 }, { w - m, m, -1, 1 },
                             { m, h - m, 1, -1 }, { w - m, h - m, -1, -1 }};
        for (int i = 0; i < 4; i++) {
            double x = corners[i, 0], y = corners[i, 1], dx = corners[i, 2], dy = corners[i, 3];
            cr.move_to (x, y + dy * L);
            cr.line_to (x, y);
            cr.line_to (x + dx * L, y);
        }
        cr.stroke ();

        double cy_home = h * 0.52, cy, smile;
        if (p < 0.22)        { cy = h * 1.2 - (h * 1.2 - cy_home) * ease_out (p / 0.22); smile = 0.0; }
        else if (p < 0.40)   { cy = cy_home; smile = ease_out ((p - 0.22) / 0.18); }
        else if (p < 0.70)   { cy = cy_home; smile = 1.0; }
        else if (p < 0.90)   { double k = ease_in ((p - 0.70) / 0.20);
                               cy = cy_home + (h * 0.75) * k; smile = 1.0 - 0.6 * k; }
        else return;         // пауза: кадр пустой, только визир

        double rad = s * 0.27, cx = w / 2.0;
        cr.save ();
        cr.rectangle (m + 2, m + 2, w - 2 * m - 4, h - 2 * m - 4);
        cr.clip ();                                   // лицо обрезается рамкой визира
        cr.arc (cx, cy, rad, 0, 2 * Math.PI);
        cr.stroke ();
        cr.arc (cx - rad * 0.38, cy - rad * 0.2, 1.7, 0, 2 * Math.PI); cr.fill ();
        cr.arc (cx + rad * 0.38, cy - rad * 0.2, 1.7, 0, 2 * Math.PI); cr.fill ();
        double mw = rad * 0.55, my = cy + rad * 0.3;
        if (smile < 0.05) { cr.move_to (cx - mw, my); cr.line_to (cx + mw, my); }
        else {
            double d = rad * 0.5 * smile;
            cr.move_to (cx - mw, my - d * 0.25);
            cr.curve_to (cx - mw * 0.5, my + d, cx + mw * 0.5, my + d, cx + mw, my - d * 0.25);
        }
        cr.stroke ();
        cr.restore ();
    }

    void draw_token (Cairo.Context cr, int w, int h, double p) {
        double s = double.min (w, h);
        double cw = s * 0.9, ch = s * 0.6;
        double x0 = (w - cw) / 2, y0 = (h - ch) / 2, rad = s * 0.09;
        rounded_rect (cr, x0, y0, cw, ch, rad);
        cr.stroke ();

        // чип с контактной сеткой
        double chw = cw * 0.26, chh = ch * 0.36;
        double chx = x0 + cw * 0.12, chy = y0 + ch * 0.2;
        cr.set_line_width (1.6);
        rounded_rect (cr, chx, chy, chw, chh, 2);
        cr.stroke ();
        cr.set_line_width (1.1);
        cr.move_to (chx, chy + chh / 2); cr.line_to (chx + chw, chy + chh / 2);
        cr.move_to (chx + chw / 2, chy); cr.line_to (chx + chw / 2, chy + chh);
        cr.stroke ();

        // мерцающие «данные» справа
        double bx = x0 + cw * 0.52;
        cr.set_line_width (2.4);
        for (int i = 0; i < 3; i++) {
            double by = y0 + ch * (0.3 + 0.2 * i);
            double flick = 0.5 + 0.5 * Math.sin (p * 2 * Math.PI * (1 + i) + i * 1.9);
            double len = cw * 0.34 * (0.35 + 0.65 * flick);
            cr.set_source_rgba (r, g, b, 0.55 + 0.45 * flick);
            cr.move_to (bx, by); cr.line_to (bx + len, by);
            cr.stroke ();
        }

        // скан-линия со шлейфом и «засканированной» подложкой
        double k = (p - 0.08) / 0.84;
        k = k < 0 ? 0 : (k > 1 ? 1 : k);
        double sy = y0 + ch * k;
        double br = double.min (1.0, r + (1 - r) * 0.6);
        double bg = double.min (1.0, g + (1 - g) * 0.6);
        double bb = double.min (1.0, b + (1 - b) * 0.6);
        cr.save ();
        rounded_rect (cr, x0 + 1, y0 + 1, cw - 2, ch - 2, rad);
        cr.clip ();
        cr.set_source_rgba (r, g, b, 0.10);
        cr.rectangle (x0, y0, cw, sy - y0);
        cr.fill ();
        for (int i = 0; i < 9; i++) {
            double a = Math.pow (1 - i / 9.0, 2);
            cr.set_source_rgba (br, bg, bb, a);
            cr.set_line_width (i == 0 ? 2.2 : 1.3);
            double yy = sy - i * 2.3;
            cr.move_to (x0, yy); cr.line_to (x0 + cw, yy);
            cr.stroke ();
        }
        cr.restore ();

        // короткий глитч раз в цикл: контур расходится на два цветных слоя
        if (p > 0.50 && p < 0.56) {
            double gg = Math.sin ((p - 0.50) / 0.06 * Math.PI) * 2.2;
            cr.set_line_width (1.4);
            cr.set_source_rgba (br, bg, bb, 0.45);
            rounded_rect (cr, x0 + gg, y0, cw, ch, rad); cr.stroke ();
            cr.set_source_rgba (r, g, b, 0.45);
            rounded_rect (cr, x0 - gg, y0 + 0.5, cw, ch, rad); cr.stroke ();
        }
    }
}
