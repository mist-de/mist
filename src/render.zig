const std = @import("std");
const cc = @import("c.zig").c;
const Color = @import("config.zig").Color;

// Canvas: pixel drawing primitives

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

    pub fn fillCircle(self: *Canvas, cx: i32, cy: i32, radius: f32, color: Color) void {
        if (radius <= 0.0 or color.a == 0) return;
        const ri: i32 = @as(i32, @intFromFloat(@ceil(radius)));
        const x0 = @max(0, cx - ri - 1);
        const y0 = @max(0, cy - ri - 1);
        const x1 = @min(self.width, cx + ri + 2);
        const y1 = @min(self.height, cy + ri + 2);

        const cxf: f32 = @as(f32, @floatFromInt(cx)) + 0.5;
        const cyf: f32 = @as(f32, @floatFromInt(cy)) + 0.5;

        var row: i32 = y0;
        while (row < y1) : (row += 1) {
            const py: f32 = @as(f32, @floatFromInt(row)) + 0.5;
            var col: i32 = x0;
            while (col < x1) : (col += 1) {
                const px: f32 = @as(f32, @floatFromInt(col)) + 0.5;
                const dx = px - cxf;
                const dy = py - cyf;
                const dist = @sqrt(dx * dx + dy * dy) - radius;
                const coverage = sdfCoverage(dist);
                if (coverage == 0) continue;
                const c = if (coverage == 255) color else Color{
                    .r = color.r,
                    .g = color.g,
                    .b = color.b,
                    .a = @intCast(@min(@as(u32, 255), @as(u32, color.a) * @as(u32, @intCast(coverage)) / 255)),
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

        var row: i32 = y0;
        while (row < y1) : (row += 1) {
            const src_row = @as(usize, @intCast((row - y) * pitch));
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

    fn sdfRoundedRect(px: f32, py: f32, x: f32, y: f32, w: f32, h: f32, r: f32) f32 {
        const cx = x + w * 0.5;
        const cy = y + h * 0.5;
        const qx = @abs(px - cx);
        const qy = @abs(py - cy);
        const hw = w * 0.5;
        const hh = h * 0.5;
        const dx = qx - hw + r;
        const dy = qy - hh + r;
        return @min(@max(dx, dy), 0.0) + @sqrt(@max(dx, 0.0) * @max(dx, 0.0) + @max(dy, 0.0) * @max(dy, 0.0)) - r;
    }

    fn sdfRoundedRectCorners(px: f32, py: f32, x: f32, y: f32, w: f32, h: f32, r_tl: f32, r_tr: f32, r_bl: f32, r_br: f32) f32 {
        const cx = x + w * 0.5;
        const cy = y + h * 0.5;
        const qx = @abs(px - cx);
        const qy = @abs(py - cy);
        const hw = w * 0.5;
        const hh = h * 0.5;

        // Select corner radius based on quadrant
        const r: f32 = if (px >= cx)
            if (py >= cy) r_br else r_tr
        else
            if (py >= cy) r_bl else r_tl;

        const dx = qx - hw + r;
        const dy = qy - hh + r;
        return @min(@max(dx, dy), 0.0) + @sqrt(@max(dx, 0.0) * @max(dx, 0.0) + @max(dy, 0.0) * @max(dy, 0.0)) - r;
    }

    fn sdfCoverage(dist: f32) u8 {
        // 1.5px transition width, linear (softer than smoothstep)
        const half_w: f32 = 0.75;
        const t = half_w - dist;
        if (t <= 0) return 0;
        const w: f32 = 1.5;
        if (t >= w) return 255;
        return @intFromFloat(t / w * 255.0);
    }

    pub fn fillRoundedRectAA(self: *Canvas, x: i32, y: i32, w: i32, h: i32, radius: i32, color: Color) void {
        if (radius <= 0) {
            self.fillRect(x, y, w, h, color);
            return;
        }
        if (color.a == 0) return;

        const r = @min(radius, @divTrunc(@min(w, h), 2));
        const x0 = @max(0, x - 1);
        const y0 = @max(0, y - 1);
        const x1 = @min(self.width, x + w + 1);
        const y1 = @min(self.height, y + h + 1);
        if (x0 >= x1 or y0 >= y1) return;

        const xf: f32 = @floatFromInt(x);
        const yf: f32 = @floatFromInt(y);
        const wf: f32 = @floatFromInt(w);
        const hf: f32 = @floatFromInt(h);
        const rf: f32 = @floatFromInt(r);

        var row: i32 = y0;
        while (row < y1) : (row += 1) {
            const py: f32 = @as(f32, @floatFromInt(row)) + 0.5;
            var col: i32 = x0;
            while (col < x1) : (col += 1) {
                const px: f32 = @as(f32, @floatFromInt(col)) + 0.5;
                const dist = sdfRoundedRect(px, py, xf, yf, wf, hf, rf);
                const coverage = sdfCoverage(dist);
                if (coverage == 0) continue;
                const c = if (coverage == 255) color else Color{
                    .r = color.r,
                    .g = color.g,
                    .b = color.b,
                    .a = @intCast(@min(@as(u32, 255), @as(u32, color.a) * @as(u32, @intCast(coverage)) / 255)),
                };
                const offset = @as(usize, @intCast(row * self.stride + col * 4));
                const dst = @as(*align(1) u32, @ptrCast(&self.data[offset]));
                dst.* = blendPixel(dst.*, c);
            }
        }
    }

    pub fn fillRoundedRectMSAA(self: *Canvas, x: i32, y: i32, w: i32, h: i32, radius: i32, color: Color) void {
        // 4x MSAA SDF sampling
        if (radius <= 0) {
            self.fillRect(x, y, w, h, color);
            return;
        }
        if (color.a == 0) return;

        const r = @min(radius, @divTrunc(@min(w, h), 2));
        const x0 = @max(0, x - 2);
        const y0 = @max(0, y - 2);
        const x1 = @min(self.width, x + w + 2);
        const y1 = @min(self.height, y + h + 2);
        if (x0 >= x1 or y0 >= y1) return;

        const xf: f32 = @floatFromInt(x);
        const yf: f32 = @floatFromInt(y);
        const wf: f32 = @floatFromInt(w);
        const hf: f32 = @floatFromInt(h);
        const rf: f32 = @floatFromInt(r);

        const half_w: f32 = 0.75;
        const w_aa: f32 = 1.5;

        var row: i32 = y0;
        while (row < y1) : (row += 1) {
            const py0: f32 = @as(f32, @floatFromInt(row));
            var col: i32 = x0;
            while (col < x1) : (col += 1) {
                const px0: f32 = @as(f32, @floatFromInt(col));
                var total: u32 = 0;
                var si: u32 = 0;
                while (si < 4) : (si += 1) {
                    const sx = px0 + @as(f32, @floatFromInt(si % 2)) * 0.5 + 0.25;
                    const sy = py0 + @as(f32, @floatFromInt(si / 2)) * 0.5 + 0.25;
                    const dist = sdfRoundedRect(sx, sy, xf, yf, wf, hf, rf);
                    const t = half_w - dist;
                    total += if (t <= 0) 0 else if (t >= w_aa) 255 else @intFromFloat(t / w_aa * 255.0);
                }
                const coverage: u8 = @intCast(total / 4);
                if (coverage == 0) continue;
                const c = if (coverage == 255) color else Color{
                    .r = color.r,
                    .g = color.g,
                    .b = color.b,
                    .a = @intCast(@min(@as(u32, 255), @as(u32, color.a) * @as(u32, @intCast(coverage)) / 255)),
                };
                const offset = @as(usize, @intCast(row * self.stride + col * 4));
                const dst = @as(*align(1) u32, @ptrCast(&self.data[offset]));
                dst.* = blendPixel(dst.*, c);
            }
        }
    }

    pub fn fillRoundedRectCorners(self: *Canvas, x: i32, y: i32, w: i32, h: i32, r_tl: i32, r_tr: i32, r_bl: i32, r_br: i32, color: Color) void {
        if (color.a == 0) return;
        if (r_tl <= 0 and r_tr <= 0 and r_bl <= 0 and r_br <= 0) {
            self.fillRect(x, y, w, h, color);
            return;
        }

        const x0 = @max(0, x - 1);
        const y0 = @max(0, y - 1);
        const x1 = @min(self.width, x + w + 1);
        const y1 = @min(self.height, y + h + 1);
        if (x0 >= x1 or y0 >= y1) return;

        const xf: f32 = @floatFromInt(x);
        const yf: f32 = @floatFromInt(y);
        const wf: f32 = @floatFromInt(w);
        const hf: f32 = @floatFromInt(h);
        const r_tl_f: f32 = @floatFromInt(@min(r_tl, @divTrunc(@min(w, h), 2)));
        const r_tr_f: f32 = @floatFromInt(@min(r_tr, @divTrunc(@min(w, h), 2)));
        const r_bl_f: f32 = @floatFromInt(@min(r_bl, @divTrunc(@min(w, h), 2)));
        const r_br_f: f32 = @floatFromInt(@min(r_br, @divTrunc(@min(w, h), 2)));

        var row: i32 = y0;
        while (row < y1) : (row += 1) {
            const py: f32 = @as(f32, @floatFromInt(row)) + 0.5;
            var col: i32 = x0;
            while (col < x1) : (col += 1) {
                const px: f32 = @as(f32, @floatFromInt(col)) + 0.5;
                const dist = sdfRoundedRectCorners(px, py, xf, yf, wf, hf, r_tl_f, r_tr_f, r_bl_f, r_br_f);
                const coverage = sdfCoverage(dist);
                if (coverage == 0) continue;
                const c = if (coverage == 255) color else Color{
                    .r = color.r,
                    .g = color.g,
                    .b = color.b,
                    .a = @intCast(@min(@as(u32, 255), @as(u32, color.a) * @as(u32, @intCast(coverage)) / 255)),
                };
                const offset = @as(usize, @intCast(row * self.stride + col * 4));
                const dst = @as(*align(1) u32, @ptrCast(&self.data[offset]));
                dst.* = blendPixel(dst.*, c);
            }
        }
    }

    pub fn fillSineWave(self: *Canvas, x: i32, y: i32, w: i32, h: i32, amplitude: f32, frequency: f32, phase: f32, color: Color) void {
        // Thick sine wave filled shape (center_y + amplitude*sin(phase + px*frequency), ±h/2)
        if (color.a == 0 or w <= 0 or h <= 0) return;
        const amp_ceil = @as(i32, @intFromFloat(@ceil(amplitude)));
        const x0 = @max(0, x);
        const y0 = @max(0, y - amp_ceil - 1);
        const x1 = @min(self.width, x + w + 1);
        const y1 = @min(self.height, y + h + amp_ceil + 2);
        if (x0 >= x1 or y0 >= y1) return;

        const half_h: f32 = @as(f32, @floatFromInt(h)) * 0.5;
        const center_y: f32 = @as(f32, @floatFromInt(y)) + half_h;
        const xf: f32 = @as(f32, @floatFromInt(x));

        var row: i32 = y0;
        while (row < y1) : (row += 1) {
            const py: f32 = @as(f32, @floatFromInt(row)) + 0.5;
            var col: i32 = x0;
            while (col < x1) : (col += 1) {
                const px: f32 = @as(f32, @floatFromInt(col)) + 0.5;
                const wave_cy = center_y + amplitude * @sin(phase + (px - xf) * frequency);
                const dist = @abs(py - wave_cy) - half_h;
                const coverage = sdfCoverage(dist);
                if (coverage == 0) continue;
                const c = if (coverage == 255) color else Color{
                    .r = color.r,
                    .g = color.g,
                    .b = color.b,
                    .a = @intCast(@min(@as(u32, 255), @as(u32, color.a) * @as(u32, @intCast(coverage)) / 255)),
                };
                const offset = @as(usize, @intCast(row * self.stride + col * 4));
                const dst = @as(*align(1) u32, @ptrCast(&self.data[offset]));
                dst.* = blendPixel(dst.*, c);
            }
        }
    }

    pub fn fillArc(self: *Canvas, cx: i32, cy: i32, inner_r: i32, outer_r: i32, start_angle: f32, sweep_angle: f32, color: Color) void {
        if (outer_r <= inner_r or color.a == 0) return;
        const x0 = @max(0, cx - outer_r - 1);
        const y0 = @max(0, cy - outer_r - 1);
        const x1 = @min(self.width, cx + outer_r + 2);
        const y1 = @min(self.height, cy + outer_r + 2);

        const outer_f: f32 = @floatFromInt(outer_r);
        const inner_f: f32 = @floatFromInt(inner_r);
        const cxf: f32 = @as(f32, @floatFromInt(cx)) + 0.5;
        const cyf: f32 = @as(f32, @floatFromInt(cy)) + 0.5;

        const abs_sweep = @abs(sweep_angle);
        const no_clip = abs_sweep >= std.math.tau - 0.001;
        const full_clip = abs_sweep <= 0.001;
        const end_angle = start_angle + sweep_angle;

        var row: i32 = y0;
        while (row < y1) : (row += 1) {
            const py: f32 = @as(f32, @floatFromInt(row)) + 0.5;
            var col: i32 = x0;
            while (col < x1) : (col += 1) {
                const px: f32 = @as(f32, @floatFromInt(col)) + 0.5;
                const dx = px - cxf;
                const dy = py - cyf;
                const dist = @sqrt(dx * dx + dy * dy);

                const cov_outer = sdfCoverage(dist - outer_f);
                if (cov_outer == 0) continue;
                const cov_inner: u8 = if (inner_r > 0) sdfCoverage(inner_f - dist) else 0;
                var coverage: u32 = if (inner_r > 0)
                    @as(u32, @intCast(cov_outer)) * @as(u32, @intCast(cov_inner)) / 255
                else
                    @as(u32, @intCast(cov_outer));

                if (coverage > 0) {
                    if (full_clip) {
                        coverage = 0;
                    } else if (!no_clip) {
                        const pd_start = -dx * @sin(start_angle) + dy * @cos(start_angle);
                        const pd_end = -dx * @sin(end_angle) + dy * @cos(end_angle);

                        const dist_start: f32 = if (sweep_angle < 0) pd_start else -pd_start;
                        const dist_end: f32 = if (sweep_angle < 0) -pd_end else pd_end;

                        const wedge_sdf = @max(dist_start, dist_end);
                        if (abs_sweep > std.math.pi) {
                            coverage = coverage * @as(u32, @intCast(sdfCoverage(-wedge_sdf))) / 255;
                        } else {
                            coverage = coverage * @as(u32, @intCast(sdfCoverage(wedge_sdf))) / 255;
                        }
                    }
                }

                if (coverage == 0) continue;
                const c = if (coverage == 255) color else Color{
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

    pub fn blitRGB(self: *Canvas, rgb: []const u8, src_w: i32, src_h: i32, dst_x: i32, dst_y: i32, dst_w: i32, dst_h: i32) void {
        if (rgb.len < @as(usize, @intCast(@as(i64, @intCast(src_w)) * @as(i64, @intCast(src_h)) * 3))) return;
        const x0 = @max(0, dst_x);
        const y0 = @max(0, dst_y);
        const x1 = @min(self.width, dst_x + dst_w);
        const y1 = @min(self.height, dst_y + dst_h);
        if (x0 >= x1 or y0 >= y1) return;

        var row: i32 = y0;
        while (row < y1) : (row += 1) {
            const sy: f32 = if (src_h == dst_h)
                @as(f32, @floatFromInt(row - dst_y))
            else
                @as(f32, @floatFromInt(row - dst_y)) / @as(f32, @floatFromInt(dst_h)) * @as(f32, @floatFromInt(src_h));
            const src_row = @as(usize, @intCast(@min(@as(i32, @intFromFloat(sy)), src_h - 1))) * @as(usize, @intCast(src_w)) * 3;
            var col: i32 = x0;
            while (col < x1) : (col += 1) {
                const sx: f32 = if (src_w == dst_w)
                    @as(f32, @floatFromInt(col - dst_x))
                else
                    @as(f32, @floatFromInt(col - dst_x)) / @as(f32, @floatFromInt(dst_w)) * @as(f32, @floatFromInt(src_w));
                const src_col = @as(usize, @intCast(@min(@as(i32, @intFromFloat(sx)), src_w - 1))) * 3;
                const r = rgb[src_row + src_col];
                const g = rgb[src_row + src_col + 1];
                const b = rgb[src_row + src_col + 2];
                const offset = @as(usize, @intCast(row * self.stride + col * 4));
                const pixel: u32 = 0xFF000000 | @as(u32, r) << 16 | @as(u32, g) << 8 | @as(u32, b);
                const dst = @as(*align(1) u32, @ptrCast(&self.data[offset]));
                dst.* = blendPixel(dst.*, Color.fromPixel(pixel));
            }
        }
    }

    pub fn blitRoundedClipped(self: *Canvas, rgb: []const u8, src_w: i32, src_h: i32, dst_x: i32, dst_y: i32, dst_w: i32, dst_h: i32, radius: i32) void {
        if (rgb.len < @as(usize, @intCast(@as(i64, @intCast(src_w)) * @as(i64, @intCast(src_h)) * 3))) return;
        const r = @min(radius, @divTrunc(@min(dst_w, dst_h), 2));
        if (r <= 0) {
            self.blitRGB(rgb, src_w, src_h, dst_x, dst_y, dst_w, dst_h);
            return;
        }
        const x0 = @max(0, dst_x);
        const y0 = @max(0, dst_y);
        const x1 = @min(self.width, dst_x + dst_w);
        const y1 = @min(self.height, dst_y + dst_h);
        if (x0 >= x1 or y0 >= y1) return;
        const xf: f32 = @floatFromInt(dst_x);
        const yf: f32 = @floatFromInt(dst_y);
        const wf: f32 = @floatFromInt(dst_w);
        const hf: f32 = @floatFromInt(dst_h);
        const rf: f32 = @floatFromInt(r);
        var row: i32 = y0;
        while (row < y1) : (row += 1) {
            const sy: f32 = if (src_h == dst_h)
                @as(f32, @floatFromInt(row - dst_y))
            else
                @as(f32, @floatFromInt(row - dst_y)) / @as(f32, @floatFromInt(dst_h)) * @as(f32, @floatFromInt(src_h));
            const src_row = @as(usize, @intCast(@min(@as(i32, @intFromFloat(sy)), src_h - 1))) * @as(usize, @intCast(src_w)) * 3;
            var col: i32 = x0;
            while (col < x1) : (col += 1) {
                const px: f32 = @as(f32, @floatFromInt(col)) + 0.5;
                const py: f32 = @as(f32, @floatFromInt(row)) + 0.5;
                const dist = sdfRoundedRect(px, py, xf, yf, wf, hf, rf);
                const coverage = sdfCoverage(dist);
                if (coverage == 0) continue;
                const sx: f32 = if (src_w == dst_w)
                    @as(f32, @floatFromInt(col - dst_x))
                else
                    @as(f32, @floatFromInt(col - dst_x)) / @as(f32, @floatFromInt(dst_w)) * @as(f32, @floatFromInt(src_w));
                const src_col = @as(usize, @intCast(@min(@as(i32, @intFromFloat(sx)), src_w - 1))) * 3;
                const r_px = rgb[src_row + src_col];
                const g_px = rgb[src_row + src_col + 1];
                const b_px = rgb[src_row + src_col + 2];
                const offset = @as(usize, @intCast(row * self.stride + col * 4));
                const pixel: u32 = @as(u32, coverage) << 24 | @as(u32, r_px) << 16 | @as(u32, g_px) << 8 | @as(u32, b_px);
                const dst = @as(*align(1) u32, @ptrCast(&self.data[offset]));
                dst.* = blendPixel(dst.*, Color.fromPixel(pixel));
            }
        }
    }
};

// Glyph cache entry

pub const Glyph = struct {
    width: u32,
    height: u32,
    pitch: i32,
    left: i32,
    top: i32,
    advance_x: i32,
    buf: []u8,

    pub fn deinit(g: *Glyph, allocator: std.mem.Allocator) void {
        allocator.free(g.buf);
    }
};

// Font: FreeType + HarfBuzz

pub const Font = struct {
    allocator: std.mem.Allocator,
    ft_lib: cc.FT_Library,
    ft_face: cc.FT_Face,
    pixel_size: u32,
    hb_font: *cc.hb_font_t,
    hb_buf: *cc.hb_buffer_t,
    cache: std.AutoHashMapUnmanaged(u32, Glyph),
    fallback: ?*Font = null,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, pixel_size: u32) !Font {
        var ft_lib: cc.FT_Library = undefined;
        if (cc.FT_Init_FreeType(&ft_lib) != 0) return error.FreeTypeInitFailed;

        var ft_face: cc.FT_Face = undefined;
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        if (cc.FT_New_Face(ft_lib, path_z, 0, &ft_face) != 0) {
            _ = cc.FT_Done_FreeType(ft_lib);
            return error.FontNotFound;
        }

        if (cc.FT_Set_Pixel_Sizes(ft_face, 0, pixel_size) != 0) {
            _ = cc.FT_Done_Face(ft_face);
            _ = cc.FT_Done_FreeType(ft_lib);
            return error.FontSizeInvalid;
        }

        const hb_font = cc.hb_ft_font_create_referenced(ft_face).?;
        const hb_buf = cc.hb_buffer_create().?;

        return Font{
            .allocator = allocator,
            .ft_lib = ft_lib,
            .ft_face = ft_face,
            .pixel_size = pixel_size,
            .hb_font = hb_font,
            .hb_buf = hb_buf,
            .cache = .{},
        };
    }

    pub fn deinit(f: *Font) void {
        var iter = f.cache.iterator();
        while (iter.next()) |entry| {
            var g = &entry.value_ptr.*;
            g.deinit(f.allocator);
        }
        f.cache.deinit(f.allocator);
        cc.hb_buffer_destroy(f.hb_buf);
        cc.hb_font_destroy(f.hb_font);
        _ = cc.FT_Done_Face(f.ft_face);
        _ = cc.FT_Done_FreeType(f.ft_lib);
    }

    pub fn getGlyph(f: *Font, glyph_index: u32) !*const Glyph {
        const gop = try f.cache.getOrPut(f.allocator, glyph_index);
        if (gop.found_existing) return gop.value_ptr;

        if (cc.FT_Load_Glyph(f.ft_face, glyph_index, cc.FT_LOAD_RENDER) != 0) {
            return error.GlyphRenderFailed;
        }

        const slot = f.ft_face.*.glyph;
        const bitmap = slot.*.bitmap;
        const pitch = bitmap.pitch;
        const rows = bitmap.rows;
        const buf_len: usize = @intCast(@abs(pitch) * rows);
        const buf = try f.allocator.alloc(u8, buf_len);
        if (buf_len > 0 and bitmap.buffer != null) {
            @memcpy(buf, bitmap.buffer[0..buf_len]);
        }

        gop.value_ptr.* = Glyph{
            .width = @intCast(bitmap.width),
            .height = @intCast(rows),
            .pitch = pitch,
            .left = slot.*.bitmap_left,
            .top = slot.*.bitmap_top,
            .advance_x = @intCast(slot.*.metrics.horiAdvance >> 6),
            .buf = buf,
        };

        return gop.value_ptr;
    }

    pub fn baselineOffset(f: *const Font) i32 {
        const ascender: i32 = @intCast(f.ft_face.*.size.*.metrics.ascender >> 6);
        return ascender;
    }

    pub fn lineHeight(f: *const Font) i32 {
        const ascender: i32 = @intCast(f.ft_face.*.size.*.metrics.ascender >> 6);
        const descender: i32 = @intCast(f.ft_face.*.size.*.metrics.descender >> 6);
        return ascender - descender;
    }
};

// Text shaping + rendering

fn shape(font: *Font, text: []const u8, count: *c_uint) struct { [*c]cc.hb_glyph_info_t, [*c]cc.hb_glyph_position_t } {
    cc.hb_buffer_reset(font.hb_buf);
    if (text.len > 0) {
        cc.hb_buffer_add_utf8(font.hb_buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
    }
    cc.hb_buffer_guess_segment_properties(font.hb_buf);
    cc.hb_shape(font.hb_font, font.hb_buf, null, 0);
    const info = cc.hb_buffer_get_glyph_infos(font.hb_buf, count);
    const pos = cc.hb_buffer_get_glyph_positions(font.hb_buf, count);
    return .{ info, pos };
}

// Returns true if any glyph is .notdef
fn hasNotdef(info: [*c]cc.hb_glyph_info_t, count: c_uint) bool {
    var i: c_uint = 0;
    while (i < count) : (i += 1) {
        if (info[i].codepoint == 0) return true;
    }
    return false;
}

// Shape and render with .notdef fallback
fn renderShaped(canvas: *Canvas, use_font: *Font, use_info: [*c]cc.hb_glyph_info_t, use_pos: [*c]cc.hb_glyph_position_t, count: c_uint, x: i32, y: i32, color: Color) void {
    var pen_x_26_6: i32 = x << 6;
    const baseline_y: i32 = y;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const gi = use_info[i];
        const gp = use_pos[i];
        const x_offset: i32 = @intCast(gp.x_offset);
        const y_offset: i32 = @intCast(gp.y_offset);
        const x_advance: i32 = @intCast(gp.x_advance);
        const glyph = use_font.getGlyph(gi.codepoint) catch {
            pen_x_26_6 += x_advance;
            continue;
        };
        const dst_x = (pen_x_26_6 + x_offset + (glyph.left << 6) + 32) >> 6;
        const dst_y = baseline_y + ((y_offset + 32) >> 6) - glyph.top;
        canvas.blitGray(dst_x, dst_y, @intCast(glyph.width), @intCast(glyph.height), glyph.pitch, glyph.buf, color);
        pen_x_26_6 += x_advance;
    }
}

pub fn renderText(canvas: *Canvas, font: *Font, text: []const u8, x: i32, y: i32, color: Color) void {
    if (color.a == 0 or text.len == 0) return;

    var glyph_count: c_uint = 0;
    const info, const pos = shape(font, text, &glyph_count);
    if (glyph_count == 0) return;

    if (hasNotdef(info, glyph_count)) {
        if (font.fallback) |fb| {
            var fb_count: c_uint = 0;
            _ = shape(fb, text, &fb_count);
            if (fb_count > 0 and !hasNotdef(cc.hb_buffer_get_glyph_infos(fb.hb_buf, &fb_count), fb_count)) {
                const fb_info = cc.hb_buffer_get_glyph_infos(fb.hb_buf, &fb_count);
                const fb_pos = cc.hb_buffer_get_glyph_positions(fb.hb_buf, &fb_count);
                return renderShaped(canvas, fb, fb_info, fb_pos, fb_count, x, y, color);
            }
        }
    }
    renderShaped(canvas, font, info, pos, glyph_count, x, y, color);
}

pub fn textWidth(font: *Font, text: []const u8) i32 {
    if (text.len == 0) return 0;

    var glyph_count: c_uint = 0;
    const info_discard, const pos = shape(font, text, &glyph_count);
    if (glyph_count == 0) return 0;

    // If .notdef, re-measure with fallback
    if (hasNotdef(info_discard, glyph_count)) {
        if (font.fallback) |fb| {
            var fb_count: c_uint = 0;
            _ = shape(fb, text, &fb_count);
            if (fb_count > 0 and !hasNotdef(cc.hb_buffer_get_glyph_infos(fb.hb_buf, &fb_count), fb_count)) {
                const fb_pos = cc.hb_buffer_get_glyph_positions(fb.hb_buf, &fb_count);
                var total: i32 = 0;
                var i: u32 = 0;
                while (i < fb_count) : (i += 1) total += @as(i32, @intCast(fb_pos[i].x_advance));
                return (total + 32) >> 6;
            }
        }
    }

    var total_26_6: i32 = 0;
    var i: u32 = 0;
    while (i < glyph_count) : (i += 1) {
        total_26_6 += @as(i32, @intCast(pos[i].x_advance));
    }
    return (total_26_6 + 32) >> 6;
}

pub const GlyphMetrics = struct {
    width: i32,
    height: i32,
    top: i32,
    left: i32,
};

pub fn measureGlyph(font: *Font, text: []const u8) GlyphMetrics {
    if (text.len == 0) return .{ .width = 0, .height = 0, .top = 0, .left = 0 };

    var glyph_count: c_uint = 0;
    const info, _ = shape(font, text, &glyph_count);
    if (glyph_count == 0) return .{ .width = 0, .height = 0, .top = 0, .left = 0 };

    const gi = info[0];
    const glyph = font.getGlyph(gi.codepoint) catch return .{ .width = 0, .height = 0, .top = 0, .left = 0 };

    return .{
        .width = @intCast(glyph.width),
        .height = @intCast(glyph.height),
        .top = glyph.top,
        .left = glyph.left,
    };
}
