use cosmic_text::Color as CosmicColor;
use tiny_skia::{FillRule, PixmapMut, Rect, Transform};

use crate::render::{rounded_rect, skcolor, solid};
use crate::state::State;
use crate::text::{render_text, text_width};

const BG: (u8, u8, u8, u8) = (0x18, 0x18, 0x25, 0xCC);
const SURFACE: (u8, u8, u8, u8) = (0x36, 0x3A, 0x4F, 0xFF);
const ACCENT: (u8, u8, u8, u8) = (0x7A, 0xA2, 0xF7, 0xFF);
const URGENT: (u8, u8, u8, u8) = (0xE7, 0x82, 0x84, 0xFF);
const MUTED: (u8, u8, u8, u8) = (0x56, 0x5F, 0x89, 0xFF);
const BRIGHT: (u8, u8, u8, u8) = (0xCD, 0xD6, 0xF4, 0xFF);
pub const BAR_H: u32 = 36;

pub fn workspace_at_x(state: &State, x: f64) -> Option<&str> {
    let mut cx = 16.0;
    for (name, tag) in &state.workspaces {
        let dw = if tag.active { 28.0 } else { 20.0 };
        if x >= cx && x <= cx + dw { return Some(name) }
        cx += dw + 6.0;
    }
    None
}

pub fn render_bar(state: &mut State) {
    let w = state.bar.w.max(1) as u32;

    let offset = (state.bar.next_buf as i32 * state.bar.buf_size) as usize;
    let slice = &mut state.bar.mmap.as_mut().unwrap()[offset..offset + state.bar.buf_size as usize];
    let mut pix = PixmapMut::from_bytes(slice, w, BAR_H).unwrap();
    pix.fill(skcolor(BG));

    let mut cx = 16.0f32;
    let dy = (BAR_H as f32 - 20.0) / 2.0;
    let rr = 6.0;
    for (name, tag) in &state.workspaces {
        let (dw, fill, tx, tcol) = if tag.active {
            (28.0, skcolor(ACCENT), cx + 9.0, CosmicColor::rgb(0xFF, 0xFF, 0xFF))
        } else if tag.urgent {
            (20.0, skcolor(URGENT), cx + 5.0, CosmicColor::rgb(0xFF, 0xFF, 0xFF))
        } else if tag.occupied {
            (20.0, skcolor(SURFACE), cx + 5.0, CosmicColor::rgba(BRIGHT.0, BRIGHT.1, BRIGHT.2, BRIGHT.3))
        } else {
            (20.0, skcolor(SURFACE), cx + 5.0, CosmicColor::rgba(MUTED.0, MUTED.1, MUTED.2, MUTED.3))
        };
        if let Some(p) = rounded_rect(cx, dy, dw, 20.0, rr) { pix.fill_path(&p, &solid(fill), FillRule::Winding, Transform::identity(), None); }
        if tag.occupied && !tag.active && let Some(r) = Rect::from_xywh(cx + dw / 2.0 - 2.0, dy + 15.0, 4.0, 4.0) { pix.fill_rect(r, &solid(skcolor(MUTED)), Transform::identity(), None); }
        render_text(&mut pix, &mut state.font, &mut state.swash, name, tx, dy + 2.0, 11.0, tcol);
        cx += dw + 6.0;
    }

    let pill = format!(" {} {} ", state.date, state.clock);
    let tw = text_width(&mut state.font, &pill, 12.0);
    render_text(&mut pix, &mut state.font, &mut state.swash, &pill, (w as f32) - tw - 12.0, (BAR_H as f32 - 24.0) / 2.0 + 3.0, 12.0, CosmicColor::rgba(BRIGHT.0, BRIGHT.1, BRIGHT.2, BRIGHT.3));
}
