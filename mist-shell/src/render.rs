use tiny_skia::{Color as SkiaColor, Paint, Path, PathBuilder, Rect, Shader};

pub fn skcolor(c: (u8, u8, u8, u8)) -> SkiaColor {
    SkiaColor::from_rgba8(c.0, c.1, c.2, c.3)
}

pub fn solid(c: SkiaColor) -> Paint<'static> {
    Paint { shader: Shader::SolidColor(c), ..Default::default() }
}

pub fn rounded_rect(x: f32, y: f32, w: f32, h: f32, r: f32) -> Option<Path> {
    if r <= 0.0 { return Some(PathBuilder::from_rect(Rect::from_xywh(x, y, w, h)?)) }
    let mut pb = PathBuilder::new();
    pb.move_to(x + r, y);
    pb.line_to(x + w - r, y);
    pb.quad_to(x + w, y, x + w, y + r);
    pb.line_to(x + w, y + h - r);
    pb.quad_to(x + w, y + h, x + w - r, y + h);
    pb.line_to(x + r, y + h);
    pb.quad_to(x, y + h, x, y + h - r);
    pb.line_to(x, y + r);
    pb.quad_to(x, y, x + r, y);
    pb.close();
    pb.finish()
}
