use cairo::Context;

pub fn set_source_rgba(cr: &Context, c: (u8, u8, u8, u8)) {
    cr.set_source_rgba(c.0 as f64 / 255.0, c.1 as f64 / 255.0, c.2 as f64 / 255.0, c.3 as f64 / 255.0);
}

pub fn rounded_rect(cr: &Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    let r = r.min(w / 2.0).min(h / 2.0);
    cr.new_path();
    cr.arc(x + r, y + r, r, std::f64::consts::PI, 3.0 * std::f64::consts::FRAC_PI_2);
    cr.arc(x + w - r, y + r, r, 3.0 * std::f64::consts::FRAC_PI_2, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, std::f64::consts::FRAC_PI_2);
    cr.arc(x + r, y + h - r, r, std::f64::consts::FRAC_PI_2, std::f64::consts::PI);
    cr.close_path();
}

pub fn fill_rounded_rect(cr: &Context, x: f64, y: f64, w: f64, h: f64, r: f64, c: (u8, u8, u8, u8)) {
    rounded_rect(cr, x, y, w, h, r);
    set_source_rgba(cr, c);
    let _ = cr.fill();
}

pub fn fill_rect(cr: &Context, x: f64, y: f64, w: f64, h: f64, c: (u8, u8, u8, u8)) {
    cr.rectangle(x, y, w, h);
    set_source_rgba(cr, c);
    let _ = cr.fill();
}

pub fn stroke_rounded_rect(cr: &Context, x: f64, y: f64, w: f64, h: f64, r: f64, width: f64, c: (u8, u8, u8, u8)) {
    rounded_rect(cr, x, y, w, h, r);
    set_source_rgba(cr, c);
    cr.set_line_width(width);
    let _ = cr.stroke();
}

fn move_to(cr: &Context, x: f64, y: f64) { cr.move_to(x, y); }
fn line_to(cr: &Context, x: f64, y: f64) { cr.line_to(x, y); }

fn tri(cr: &Context, a: (f64, f64), b: (f64, f64), c_: (f64, f64)) {
    cr.new_path();
    move_to(cr, a.0, a.1);
    line_to(cr, b.0, b.1);
    line_to(cr, c_.0, c_.1);
    cr.close_path();
}

fn quad(cr: &Context, a: (f64, f64), b: (f64, f64), c_: (f64, f64), d: (f64, f64)) {
    cr.new_path();
    move_to(cr, a.0, a.1);
    line_to(cr, b.0, b.1);
    line_to(cr, c_.0, c_.1);
    line_to(cr, d.0, d.1);
    cr.close_path();
}

/// Speaker icon (on / muted)
pub fn draw_speaker(cr: &Context, x: f64, y: f64, size: f64, muted: bool, c: (u8, u8, u8, u8)) {
    let s = size;
    let body_w = s * 0.38;
    let body_h = s * 0.55;
    let bx = x + s * 0.02;
    let by = y + (s - body_h) / 2.0;
    fill_rounded_rect(cr, bx, by, body_w, body_h, s * 0.08, c);

    let tri_left = bx + body_w;
    let tri_right = tri_left + s * 0.28;
    let tri_top = by + s * 0.08;
    let tri_bot = by + body_h - s * 0.08;
    set_source_rgba(cr, c);
    tri(cr, (tri_left, tri_top), (tri_right, y + s / 2.0), (tri_left, tri_bot));
    let _ = cr.fill();

    if muted {
        let g = s * 0.12;
        let w = s * 0.12;
        set_source_rgba(cr, c);
        quad(cr,
            (x + g - w * 0.3, y + g),
            (x + g + w * 0.7, y + g),
            (x + s - g + w * 0.3, y + s - g),
            (x + s - g - w * 0.7, y + s - g),
        );
        let _ = cr.fill();
        quad(cr,
            (x + s - g - w * 0.7, y + g),
            (x + s - g + w * 0.3, y + g),
            (x + g + w * 0.7, y + s - g),
            (x + g - w * 0.3, y + s - g),
        );
        let _ = cr.fill();
    }
}

/// WiFi icon (three bars)
pub fn draw_wifi(cr: &Context, x: f64, y: f64, size: f64, connected: bool, c: (u8, u8, u8, u8)) {
    if !connected { return; }
    let s = size;
    let bar_w = s * 0.15;
    let gap = s * 0.07;
    let total_w = 3.0 * bar_w + 2.0 * gap;
    let start_x = x + (s - total_w) / 2.0;
    let heights = [s * 0.25, s * 0.50, s * 0.80];

    for i in 0..3 {
        let bx = start_x + i as f64 * (bar_w + gap);
        let bh = heights[i];
        let by = y + s - bh;
        fill_rect(cr, bx, by, bar_w, bh, c);
    }
    fill_rounded_rect(cr, x + s / 2.0 - 1.5, y + s - 4.0, 3.0, 3.0, 1.5, c);
}

/// Battery icon
pub fn draw_battery(cr: &Context, x: f64, y: f64, size: f64, pct: u8, charging: bool, c: (u8, u8, u8, u8)) {
    let s = size;
    let body_w = s * 0.65;
    let body_h = s * 0.48;
    let body_x = x + (s - body_w) / 2.0;
    let body_y = y + (s - body_h) / 2.0;

    let tab_w = s * 0.08;
    let tab_h = s * 0.20;
    let tab_x = body_x + body_w;
    let tab_y = y + (s - tab_h) / 2.0;
    fill_rect(cr, tab_x, tab_y, tab_w, tab_h, c);

    set_source_rgba(cr, c);
    cr.set_line_width(1.5);
    rounded_rect(cr, body_x, body_y, body_w, body_h, s * 0.06);
    let _ = cr.stroke();

    let fm = 2.5;
    let fill_w = (body_w - fm * 2.0) * (pct as f64 / 100.0).min(1.0).max(0.0);
    let fill_h = body_h - fm * 2.0;
    if fill_w > 0.0 {
        fill_rect(cr, body_x + fm, body_y + fm, fill_w, fill_h, c);
    }

    if charging {
        let cx = body_x + body_w / 2.0;
        let cy = body_y + body_h / 2.0;
        let bs = s * 0.08;
        set_source_rgba(cr, c);
        quad(cr,
            (cx - bs, body_y - 1.0),
            (cx + bs, body_y - 1.0),
            (cx, cy),
            (cx + bs * 0.5, cy),
        );
        let _ = cr.fill();
        quad(cr,
            (cx + bs, body_y + body_h + 1.0),
            (cx - bs, body_y + body_h + 1.0),
            (cx, cy),
            (cx - bs * 0.5, cy),
        );
        let _ = cr.fill();
    }
}

/// Power icon
pub fn draw_power(cr: &Context, x: f64, y: f64, size: f64, c: (u8, u8, u8, u8)) {
    let s = size;
    let stem_w = s * 0.18;
    let stem_h = s * 0.45;
    let stem_x = x + (s - stem_w) / 2.0;
    let stem_y = y + s * 0.05;
    fill_rect(cr, stem_x, stem_y, stem_w, stem_h, c);

    let cs = s * 0.65;
    let cx = x + (s - cs) / 2.0;
    let cy = y + (s - cs) / 2.0 + s * 0.10;
    stroke_rounded_rect(cr, cx, cy, cs, cs, cs / 2.0, s * 0.14, c);
}
