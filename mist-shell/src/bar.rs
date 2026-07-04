use crate::render::*;
use crate::state::State;
use crate::tokens::*;

// ============================================================
// Pango text helpers
// ============================================================

fn render_text(cr: &cairo::Context, x: f64, y: f64, text: &str, size: f64, col: (u8, u8, u8, u8)) {
    let layout = pangocairo::functions::create_layout(cr);
    layout.set_text(text);
    let desc = pango::FontDescription::from_string(&format!("GoogleSansFlex {}", size as i32));
    layout.set_font_description(Some(&desc));
    set_source_rgba(cr, col);
    cr.move_to(x, y);
    pangocairo::functions::show_layout(cr, &layout);
}

/// Measure text width in pixels without rendering.
fn text_width(cr: &cairo::Context, text: &str, size: f64) -> f64 {
    let layout = pangocairo::functions::create_layout(cr);
    layout.set_text(text);
    let desc = pango::FontDescription::from_string(&format!("GoogleSansFlex {}", size as i32));
    layout.set_font_description(Some(&desc));
    let (w, _) = layout.pixel_size();
    w as f64
}

fn text_h(size: f64) -> f64 {
    (size * 1.4).ceil()
}

// ============================================================
// Module height measurement
// ============================================================

fn os_h() -> f64 { 16.0 }

fn ws_h(workspaces: &[(String, crate::state::Tag)]) -> f64 {
    let n = workspaces.len().min(BAR_SHOWN_WORKSPACES) as f64;
    if n == 0.0 { return 0.0; }
    n * WS_ITEM_H as f64 + (n - 1.0) * WS_SPACING as f64 + WS_PILL_PAD_V as f64 * 2.0
}

fn clk_h() -> f64 {
    text_h(CLOCK_TIME_SIZE as f64) + CLOCK_SPACING as f64 + text_h(CLOCK_DATE_SIZE as f64) + PAD_SM as f64 * 2.0
}

fn st_h() -> f64 {
    STATUS_ICON_SIZE as f64 * 3.0 + STATUS_SPACING as f64 * 2.0 + PAD_MD as f64 * 2.0
}

fn pwr_h() -> f64 { 16.0 }

fn total_content_h(workspaces: &[(String, crate::state::Tag)]) -> f64 {
    let mut h = os_h() + BAR_MODULE_SPACING as f64;
    let wh = ws_h(workspaces);
    if wh > 0.0 { h += wh + BAR_MODULE_SPACING as f64; }
    h += clk_h() + BAR_MODULE_SPACING as f64;
    h += st_h() + BAR_MODULE_SPACING as f64;
    h + pwr_h()
}

// ============================================================
// Module rendering
// ============================================================

fn draw_os(cr: &cairo::Context, x: f64, y: f64, w: f64, scale: f64) {
    let sz = os_h() * scale;
    let ix = x + (w - sz) / 2.0;
    fill_rounded_rect(cr, ix, y, sz, sz, sz / 2.0, C_M3_TERTIARY);
    let d = 4.0 * scale;
    fill_rounded_rect(cr, ix + (sz - d) / 2.0, y + (sz - d) / 2.0, d, d, d / 2.0, C_M3_ON_PRIMARY);
}

fn draw_ws(cr: &cairo::Context, workspaces: &[(String, crate::state::Tag)], x: f64, y: f64, w: f64, scale: f64) {
    let n = workspaces.len().min(BAR_SHOWN_WORKSPACES);
    if n == 0 { return; }
    let item = WS_ITEM_H as f64 * scale;
    let pill = ws_h(workspaces) * scale;
    let content = n as f64 * item + (n as f64 - 1.0) * WS_SPACING as f64 * scale;
    let pad = (pill - content) / 2.0;

    fill_rounded_rect(cr, x, y, w, pill, RADIUS_FULL as f64, C_MODULE_BG);

    let active = workspaces.iter().position(|(_, t)| t.active);
    for i in 0..n {
        let (name, tag) = &workspaces[i];
        let iy = y + pad + i as f64 * (item + WS_SPACING as f64 * scale);

        if Some(i) == active {
            let ix = x + (w - WS_INDICATOR_W as f64 * scale) / 2.0;
            fill_rounded_rect(cr, ix, iy, WS_INDICATOR_W as f64 * scale, item, RADIUS_FULL as f64, C_WS_ACTIVE_BG);
        }

        let col = if Some(i) == active { C_WS_ACTIVE_TEXT }
        else if tag.occupied { C_WS_INACTIVE_TEXT }
        else { C_WS_UNOCCUPIED_TEXT };

        let label_size = WS_LABEL_SIZE as f64 * scale;
        let tw = text_width(cr, name, label_size);
        render_text(cr,
            x + (w - tw) / 2.0,
            iy + (item - label_size * 1.4) / 2.0,
            name, label_size, col);
    }
}

fn draw_clock(cr: &cairo::Context, clock: &str, date: &str, x: f64, y: f64, w: f64, scale: f64) {
    let pill = clk_h() * scale;
    let time_h = text_h(CLOCK_TIME_SIZE as f64) * scale;
    let date_h = text_h(CLOCK_DATE_SIZE as f64) * scale;
    let content = time_h + CLOCK_SPACING as f64 * scale + date_h;
    let pad = (pill - content) / 2.0;

    fill_rounded_rect(cr, x, y, w, pill, RADIUS_FULL as f64, C_MODULE_BG);

    let cx = x + w / 2.0;
    let mut cy = y + pad;

    let time_size = CLOCK_TIME_SIZE as f64 * scale;
    let tw = text_width(cr, clock, time_size);
    render_text(cr, cx - tw / 2.0, cy, clock, time_size, C_CLOCK);
    cy += time_h + CLOCK_SPACING as f64 * scale;

    let date_size = CLOCK_DATE_SIZE as f64 * scale;
    let dw = text_width(cr, date, date_size);
    render_text(cr, cx - dw / 2.0, cy, date, date_size, C_CLOCK);
}

fn draw_status(cr: &cairo::Context, status: &crate::status::SystemStatus, x: f64, y: f64, w: f64, scale: f64) {
    let pill = st_h() * scale;
    let icon_sz = STATUS_ICON_SIZE as f64 * scale;
    let spacing = STATUS_SPACING as f64 * scale;
    let content = icon_sz * 3.0 + spacing * 2.0;
    let pad = (pill - content) / 2.0;

    fill_rounded_rect(cr, x, y, w, pill, RADIUS_FULL as f64, C_MODULE_BG);

    let cx = x + w / 2.0;
    let ix = cx - icon_sz / 2.0;
    let mut cy = y + pad;

    let acol = if status.volume_muted { C_STATUS_OFF } else { C_STATUS_ON };
    draw_speaker(cr, ix, cy, icon_sz, status.volume_muted, acol);
    cy += icon_sz + spacing;

    let ncol = if status.network_connected { C_STATUS_ON } else { C_STATUS_OFF };
    draw_wifi(cr, ix, cy, icon_sz, status.network_connected, ncol);
    cy += icon_sz + spacing;

    if let Some(pct) = status.battery {
        let bcol = if pct <= 15 { C_POWER } else { C_STATUS_ON };
        draw_battery(cr, ix, cy, icon_sz, pct, status.battery_charging, bcol);
        let pct_size = 8.0 * scale;
        let ps = format!("{}%", pct);
        let pw = text_width(cr, &ps, pct_size);
        set_source_rgba(cr, bcol);
        render_text(cr, cx - pw / 2.0, cy + icon_sz, &ps, pct_size, bcol);
    }
}

fn draw_power_btn(cr: &cairo::Context, x: f64, y: f64, w: f64, scale: f64) {
    let sz = pwr_h() * scale;
    let ix = x + (w - sz) / 2.0;
    crate::render::draw_power(cr, ix, y, sz, C_POWER);
}

// ============================================================
// Main render entry point
// ============================================================

pub fn render_bar(state: &mut State) {
    let Some(ref mut shm_triple) = state.bar.shm else { return };

    // Snapshot values before borrowing slot
    let scale = state.scale.max(1) as f64;
    let bar_w = state.bar.w.max(1) as f64;
    let bar_h = state.bar.h.max(1) as f64;
    let clock = state.clock.clone();
    let date = state.date.clone();
    let status = state.status.clone();
    let _hovered_ws = state.hovered_ws;
    let shown_ws: Vec<_> = state.workspaces.iter().take(BAR_SHOWN_WORKSPACES).cloned().collect();
    let ws_refs: Vec<(String, crate::state::Tag)> = shown_ws;

    let slot = shm_triple.next_slot();

    // Snapshot dimensions before borrowing slot's data
    let width = slot.width;
    let height = slot.height;
    let stride = slot.stride;

    // Create temporary Cairo surface backed by shm buffer memory
    let data = unsafe { slot.data_mut() };
    // Zero the buffer to prevent ghosting from previous frame
    data.fill(0);
    let surface = unsafe {
        cairo::ImageSurface::create_for_data_unsafe(
            data.as_mut_ptr(),
            cairo::Format::ARgb32,
            width,
            height,
            stride,
        ).unwrap()
    };
    let _ = data;

    let cr = cairo::Context::new(&surface).unwrap();

    // Clear to transparent
    cr.set_operator(cairo::Operator::Clear);
    let _ = cr.paint();
    cr.set_operator(cairo::Operator::Over);

    let module_w = BAR_INNER_W as f64 * scale;
    let module_x = (bar_w - module_w) / 2.0;

    let content_h = total_content_h(&ws_refs) * scale;
    let mut cy = ((bar_h - content_h) / 2.0).max(0.0);

    draw_os(&cr, module_x, cy, module_w, scale);
    cy += os_h() * scale + BAR_MODULE_SPACING as f64 * scale;

    if !ws_refs.is_empty() {
        draw_ws(&cr, &ws_refs, module_x, cy, module_w, scale);
        cy += ws_h(&ws_refs) * scale + BAR_MODULE_SPACING as f64 * scale;
    }

    draw_clock(&cr, &clock, &date, module_x, cy, module_w, scale);
    cy += clk_h() * scale + BAR_MODULE_SPACING as f64 * scale;

    draw_status(&cr, &status, module_x, cy, module_w, scale);
    cy += st_h() * scale + BAR_MODULE_SPACING as f64 * scale;

    draw_power_btn(&cr, module_x, cy, module_w, scale);

    surface.flush();
}

/// Hit-test workspace pills for pointer events.
pub fn hit_test_workspace(state: &State, x: f64, y: f64) -> Option<usize> {
    let scale = state.scale.max(1) as f64;
    let bar_w = state.bar.w as f64;
    let bar_h = state.bar.h as f64;

    let module_w = BAR_INNER_W as f64 * scale;
    let module_x = (bar_w - module_w) / 2.0;

    let shown_ws: Vec<_> = state.workspaces.iter().take(BAR_SHOWN_WORKSPACES).cloned().collect();
    if shown_ws.is_empty() { return None; }

    let content_h = total_content_h(&shown_ws) * scale;
    let base_y = ((bar_h - content_h) / 2.0).max(0.0);
    let os = os_h() * scale;
    let pill = ws_h(&shown_ws) * scale;
    let ws_y = base_y + os + BAR_MODULE_SPACING as f64 * scale;
    let item = WS_ITEM_H as f64 * scale;

    if x >= module_x && x <= module_x + module_w && y >= ws_y && y <= ws_y + pill {
        let content = shown_ws.len() as f64 * item + (shown_ws.len() as f64 - 1.0) * WS_SPACING as f64 * scale;
        let pad = (pill - content) / 2.0;
        let local = y - ws_y - pad;
        if local >= 0.0 {
            let idx = (local / (item + WS_SPACING as f64 * scale)) as usize;
            if idx < shown_ws.len() {
                let start = idx as f64 * (item + WS_SPACING as f64 * scale);
                if local >= start && local <= start + item {
                    return Some(idx);
                }
            }
        }
    }
    None
}
