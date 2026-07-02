use cosmic_text::{Attrs, Buffer, Color as CosmicColor, FontSystem, Metrics, Shaping, SwashCache};
use tiny_skia::{PixmapMut, Rect, Transform};

use crate::render::solid;

pub fn text_width(font: &mut FontSystem, text: &str, size: f32) -> f32 {
    let mut b = Buffer::new(font, Metrics::new(size, (size * 1.4).ceil()));
    b.set_text(text, &Attrs::new(), Shaping::Advanced, None);
    b.set_size(None, None);
    b.shape_until_scroll(font, true);
    b.layout_runs().flat_map(|r| r.glyphs.iter()).map(|g| (g.x + g.w).ceil()).fold(0.0, f32::max)
}

#[allow(clippy::too_many_arguments)]
pub fn render_text(pixmap: &mut PixmapMut, font: &mut FontSystem, swash: &mut SwashCache, text: &str, x: f32, y: f32, size: f32, color: CosmicColor) {
    let m = Metrics::new(size, (size * 1.4).ceil());
    let mut b = Buffer::new(font, m);
    b.set_text(text, &Attrs::new(), Shaping::Advanced, None);
    b.set_size(None, None);
    b.shape_until_scroll(font, true);
    let nw: f32 = b.layout_runs().flat_map(|r| r.glyphs.iter()).map(|g| (g.x + g.w).ceil()).fold(0.0, f32::max);
    b.set_size(Some(nw.max(1.0)), Some((size * 1.4).ceil()));
    b.shape_until_scroll(font, true);
    b.draw(font, swash, color, |gx, gy, gw, gh, gc| {
        let r = Rect::from_xywh(x + gx as f32, y + gy as f32, gw as f32, gh as f32);
        if let Some(rect) = r { pixmap.fill_rect(rect, &solid(tiny_skia::Color::from_rgba8(gc.r(), gc.g(), gc.b(), gc.a())), Transform::identity(), None); }
    });
}
