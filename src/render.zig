const std = @import("std");
const Color = @import("config.zig").Color;

pub const Canvas = struct {
    data: []align(std.heap.page_size_min) u8,
    width: i32,
    height: i32,
    stride: i32,

    fn blendPixel(dst_pixel: u32, src: Color) u32 {
        if (src.a == 0) return dst_pixel;
        if (src.a == 255) return src.toPixel();

        const sa = @as(u32, src.a);
        const sa_inv = 255 - sa;

        const da = @as(u32, (dst_pixel >> 24) & 0xFF);
        const dr = @as(u32, (dst_pixel >> 16) & 0xFF);
        const dg = @as(u32, (dst_pixel >> 8) & 0xFF);
        const db = @as(u32, dst_pixel & 0xFF);

        const out_a = sa + da * sa_inv / 255;
        if (out_a == 0) return 0;
        const out_r = @as(u32, src.r) * sa / 255 + dr * sa_inv / 255;
        const out_g = @as(u32, src.g) * sa / 255 + dg * sa_inv / 255;
        const out_b = @as(u32, src.b) * sa / 255 + db * sa_inv / 255;

        return (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
    }

    fn coverageAA(dist: u32, r_u: u32, band: u32) u32 {
        if (dist <= r_u -| band) return 255;
        if (dist >= r_u + band) return 0;
        const delta = dist - (r_u -| band);
        const t = @as(f32, @floatFromInt(delta)) / @as(f32, @floatFromInt(band * 2));
        const smooth = t * t * (3.0 - 2.0 * t);
        return @intFromFloat((1.0 - smooth) * 255.0);
    }

    pub fn fillRect(self: *Canvas, x: i32, y: i32, w: i32, h: i32, color: Color) void {
        const x0 = @max(0, x);
        const y0 = @max(0, y);
        const x1 = @min(self.width, x + w);
        const y1 = @min(self.height, y + h);
        if (x0 >= x1 or y0 >= y1) return;

        if (color.a == 255) {
            const p = color.toPixel();
            var row: i32 = y0;
            while (row < y1) : (row += 1) {
                const offset = @as(usize, @intCast(row * self.stride + x0 * 4));
                const pixels = @as([*]u32, @ptrCast(@alignCast(&self.data[offset])))[0..@intCast(x1 - x0)];
                @memset(pixels, p);
            }
        } else if (color.a == 0) {
            return;
        } else {
            var row: i32 = y0;
            while (row < y1) : (row += 1) {
                var col: i32 = x0;
                while (col < x1) : (col += 1) {
                    const offset = @as(usize, @intCast(row * self.stride + col * 4));
                    const dst = @as(*align(1) u32, @ptrCast(&self.data[offset]));
                    dst.* = blendPixel(dst.*, color);
                }
            }
        }
    }

    pub fn fillRoundedRect(self: *Canvas, x: i32, y: i32, w: i32, h: i32, radius: i32, color: Color) void {
        if (radius <= 0) {
            self.fillRect(x, y, w, h, color);
            return;
        }
        if (color.a == 0) return;

        const x0 = @max(0, x);
        const y0 = @max(0, y);
        const x1 = @min(self.width, x + w);
        const y1 = @min(self.height, y + h);
        if (x0 >= x1 or y0 >= y1) return;

        const r = @min(radius, @divTrunc(@min(w, h), 2));
        const r_u: u32 = @intCast(r);
        const r_sq = r_u * r_u;
        const band: u32 = @max(2, @divTrunc(r_u + 2, 3));

        var row: i32 = y0;
        while (row < y1) : (row += 1) {
            const py = row - y;
            const in_y_top = py < r;
            const in_y_bot = py >= h - r;

            var col: i32 = x0;
            while (col < x1) : (col += 1) {
                const px = col - x;
                const in_x_left = px < r;
                const in_x_right = px >= w - r;

                if ((!in_y_top and !in_y_bot) or (!in_x_left and !in_x_right)) {
                    const offset = @as(usize, @intCast(row * self.stride + col * 4));
                    const dst = @as(*align(1) u32, @ptrCast(&self.data[offset]));
                    dst.* = blendPixel(dst.*, color);
                    continue;
                }

                const cx: i32 = if (in_x_left) r else w - r - 1;
                const cy: i32 = if (in_y_top) r else h - r - 1;
                const dx = @as(i32, px) - cx;
                const dy = @as(i32, py) - cy;
                const dist_sq: u32 = @intCast(dx * dx + dy * dy);

                if (dist_sq >= r_sq + band * band) continue;
                if (dist_sq <= r_sq -| band *| band) {
                    const offset = @as(usize, @intCast(row * self.stride + col * 4));
                    const dst = @as(*align(1) u32, @ptrCast(&self.data[offset]));
                    dst.* = blendPixel(dst.*, color);
                    continue;
                }

                const dist = isqrt(dist_sq);
                const coverage = coverageAA(dist, r_u, band);
                if (coverage == 0) continue;

                const c = Color{
                    .r = color.r,
                    .g = color.g,
                    .b = color.b,
                    .a = @intCast(@min(@as(u32, 255), @as(u32, color.a) * coverage / 255)),
                };
                const offset = @as(usize, @intCast(row * self.stride + col * 4));
                const dst = @as(*align(1) u32, @ptrCast(&self.data[offset]));
                dst.* = blendPixel(dst.*, c);
            }
        }
    }

    pub fn fillCircle(self: *Canvas, cx: i32, cy: i32, radius: i32, color: Color) void {
        if (radius <= 0 or color.a == 0) return;
        const x0 = @max(0, cx - radius - 1);
        const y0 = @max(0, cy - radius - 1);
        const x1 = @min(self.width, cx + radius + 2);
        const y1 = @min(self.height, cy + radius + 2);

        const r_u: u32 = @intCast(radius);
        const r_sq = r_u * r_u;
        const band: u32 = if (r_u < 4) 1 else @max(2, @divTrunc(r_u + 2, 3));

        var row: i32 = y0;
        while (row < y1) : (row += 1) {
            var col: i32 = x0;
            while (col < x1) : (col += 1) {
                const dx = @as(i32, col) - cx;
                const dy = @as(i32, row) - cy;
                const dist_sq: u32 = @intCast(dx * dx + dy * dy);

                if (dist_sq >= r_sq + band * band) continue;
                if (dist_sq <= r_sq -| band *| band) {
                    const offset = @as(usize, @intCast(row * self.stride + col * 4));
                    const dst = @as(*align(1) u32, @ptrCast(&self.data[offset]));
                    dst.* = blendPixel(dst.*, color);
                    continue;
                }

                const dist = isqrt(dist_sq);
                const coverage = coverageAA(dist, r_u, band);
                if (coverage == 0) continue;

                const c = Color{
                    .r = color.r,
                    .g = color.g,
                    .b = color.b,
                    .a = @intCast(@min(@as(u32, 255), @as(u32, color.a) * coverage / 255)),
                };
                const offset = @as(usize, @intCast(row * self.stride + col * 4));
                const dst = @as(*align(1) u32, @ptrCast(&self.data[offset]));
                dst.* = blendPixel(dst.*, c);
            }
        }
    }

    pub fn fillRing(self: *Canvas, cx: i32, cy: i32, inner_r: i32, outer_r: i32, color: Color) void {
        if (outer_r <= inner_r or color.a == 0) return;
        const x0 = @max(0, cx - outer_r - 1);
        const y0 = @max(0, cy - outer_r - 1);
        const x1 = @min(self.width, cx + outer_r + 2);
        const y1 = @min(self.height, cy + outer_r + 2);

        const outer_u: u32 = @intCast(outer_r);
        const inner_u: u32 = @intCast(inner_r);
        const outer_sq = outer_u * outer_u;
        const inner_sq = inner_u * inner_u;
        const band: u32 = if (outer_u < 4) 1 else @max(2, @divTrunc(outer_u + 2, 3));

        var row: i32 = y0;
        while (row < y1) : (row += 1) {
            var col: i32 = x0;
            while (col < x1) : (col += 1) {
                const dx = @as(i32, col) - cx;
                const dy = @as(i32, row) - cy;
                const dist_sq: u32 = @intCast(dx * dx + dy * dy);

                if (dist_sq >= outer_sq + band * band) continue;
                if (dist_sq <= inner_sq -| band *| band) continue;

                const dist = isqrt(dist_sq);
                var cov_outer: u32 = 255;
                if (dist >= outer_u -| band) {
                    cov_outer = coverageAA(dist, outer_u, band);
                }
                var cov_inner: u32 = 0;
                if (dist >= inner_u -| band and inner_r > 0) {
                    cov_inner = coverageAA(dist, inner_u, band);
                }
                const coverage = cov_outer -| cov_inner;
                if (coverage == 0) continue;

                const c = Color{
                    .r = color.r,
                    .g = color.g,
                    .b = color.b,
                    .a = @intCast(@min(@as(u32, 255), @as(u32, color.a) * coverage / 255)),
                };
                const offset = @as(usize, @intCast(row * self.stride + col * 4));
                const dst = @as(*align(1) u32, @ptrCast(&self.data[offset]));
                dst.* = blendPixel(dst.*, c);
            }
        }
    }

    pub fn blitGray(self: *Canvas, x: i32, y: i32, w: u32, h: u32, pitch: i32, buf: []const u8, color: Color) void {
        if (color.a == 0 or w == 0 or h == 0) return;
        const x0 = @max(0, x);
        const y0 = @max(0, y);
        const x1 = @min(self.width, x + @as(i32, @intCast(w)));
        const y1 = @min(self.height, y + @as(i32, @intCast(h)));
        if (x0 >= x1 or y0 >= y1) return;

        const dx = x0 - x;
        var row: i32 = y0;
        while (row < y1) : (row += 1) {
            const src_row = @as(usize, @intCast((row - y) * pitch + dx));
            var col: i32 = x0;
            while (col < x1) : (col += 1) {
                const src_col = @as(usize, @intCast(col - x));
                const cov = buf[src_row + src_col];
                if (cov == 0) continue;
                const alpha: u32 = @as(u32, color.a) * cov / 255;
                if (alpha == 0) continue;
                const offset = @as(usize, @intCast(row * self.stride + col * 4));
                const dst = @as(*align(1) u32, @ptrCast(&self.data[offset]));
                const dst_val = dst.*;

                const sa = alpha;
                const sa_inv = 255 - sa;
                const da = (dst_val >> 24) & 0xFF;
                const dr = (dst_val >> 16) & 0xFF;
                const dg = (dst_val >> 8) & 0xFF;
                const db = dst_val & 0xFF;

                const out_a = sa + da * sa_inv / 255;
                if (out_a == 0) {
                    dst.* = 0;
                    continue;
                }
                const out_r = @as(u32, color.r) * sa / 255 + dr * sa_inv / 255;
                const out_g = @as(u32, color.g) * sa / 255 + dg * sa_inv / 255;
                const out_b = @as(u32, color.b) * sa / 255 + db * sa_inv / 255;

                dst.* = (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
            }
        }
    }

    pub fn fill(self: *Canvas, color: Color) void {
        self.fillRect(0, 0, self.width, self.height, color);
    }

    fn isqrt(n: u32) u32 {
        if (n == 0) return 0;
        var x = n;
        var y = (x + 1) / 2;
        while (y < x) {
            x = y;
            y = (x + n / x) / 2;
        }
        return x;
    }
};
