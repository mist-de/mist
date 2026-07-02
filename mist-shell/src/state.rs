use wayland_client::protocol::wl_buffer::WlBuffer;
use wayland_client::protocol::wl_compositor::WlCompositor;
use wayland_client::protocol::wl_keyboard::WlKeyboard;
use wayland_client::protocol::wl_pointer::WlPointer;


use wayland_client::protocol::wl_shm::{Format, WlShm};
use wayland_client::protocol::wl_shm_pool::WlShmPool;
use wayland_client::protocol::wl_surface::WlSurface;
use wayland_client::{Connection, QueueHandle};
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_shell_v1::{Layer, ZwlrLayerShellV1};
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_surface_v1::{Anchor, KeyboardInteractivity, ZwlrLayerSurfaceV1};
use xkbcommon::xkb;

use crate::launcher;

pub type WsList = Vec<(String, Tag)>;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Tag {
    pub active: bool,
    pub urgent: bool,
    pub occupied: bool,
}

pub struct BarCb;
pub struct LauncherCb;

pub struct BarSurface {
    pub surface: WlSurface,
    pub layer: ZwlrLayerSurfaceV1,
    pub pool: Option<WlShmPool>,
    pub mmap: Option<memmap2::MmapMut>,
    pub bufs: Vec<WlBuffer>,
    pub next_buf: u32,
    pub buf_size: i32,
    pub stride: i32,
    pub w: i32,
    pub h: i32,
    pub configured: bool,
    pub frame_pending: bool,
    pub dirty: bool,
}

pub struct LauncherSurface {
    pub surface: Option<WlSurface>,
    pub layer: Option<ZwlrLayerSurfaceV1>,
    pub pool: Option<WlShmPool>,
    pub mmap: Option<memmap2::MmapMut>,
    pub bufs: Vec<WlBuffer>,
    pub next_buf: u32,
    pub buf_size: i32,
    pub stride: i32,
    pub w: i32,
    pub h: i32,
    pub configured: bool,
    pub frame_pending: bool,
    pub dirty: bool,
    pub visible: bool,
    pub apps: Vec<launcher::App>,
    pub matching: Vec<usize>,
    pub is_action_mode: bool,
    pub matching_actions: Vec<usize>,
    pub selection: usize,
    pub query: String,
    pub scroll_offset: usize,
    pub panel: Option<(f32, f32, f32, f32)>,
    pub actions: Vec<launcher::LauncherAction>,
}

pub struct State {
    pub conn: Connection,
    pub qh: QueueHandle<State>,
    pub compositor: WlCompositor,
    pub shm: WlShm,
    pub layer_shell: ZwlrLayerShellV1,
    pub bar: BarSurface,
    pub launcher: LauncherSurface,
    pub pointer: Option<WlPointer>,
    pub keyboard: Option<WlKeyboard>,
    pub current_surface: Option<WlSurface>,
    pub pointer_x: f64,
    pub pointer_y: f64,
    pub clock: String,
    pub date: String,
    pub workspaces: WsList,
    pub font: cosmic_text::FontSystem,
    pub swash: cosmic_text::SwashCache,
    pub xkb_ctx: Option<xkb::Context>,
    pub xkb_state: Option<xkb::State>,
}

const BUF_N: u32 = 2;

impl State {
    pub fn commit_bar(&mut self) {
        let idx = self.bar.next_buf;
        self.bar.next_buf = (self.bar.next_buf + 1) % BUF_N;
        if self.bar.bufs.len() <= idx as usize {
            let offset = idx as i32 * self.bar.buf_size;
            let buf = self.bar.pool.as_ref().unwrap().create_buffer(
                offset, self.bar.w, self.bar.h, self.bar.stride, Format::Abgr8888, &self.qh, (),
            );
            self.bar.bufs.push(buf);
        }
        self.bar.surface.attach(Some(&self.bar.bufs[idx as usize]), 0, 0);
        self.bar.surface.damage(0, 0, self.bar.w, self.bar.h);
        let _cb = self.bar.surface.frame(&self.qh, BarCb);
        self.bar.surface.commit();
        self.bar.dirty = false;
        self.bar.frame_pending = true;
        let _ = self.conn.flush();
    }

    pub fn commit_launcher(&mut self) {
        let idx = self.launcher.next_buf;
        self.launcher.next_buf = (self.launcher.next_buf + 1) % BUF_N;
        if self.launcher.bufs.len() <= idx as usize {
            let offset = idx as i32 * self.launcher.buf_size;
            let buf = self.launcher.pool.as_ref().unwrap().create_buffer(
                offset, self.launcher.w, self.launcher.h, self.launcher.stride, Format::Abgr8888, &self.qh, (),
            );
            self.launcher.bufs.push(buf);
        }
        if let Some(ref surface) = self.launcher.surface {
            surface.attach(Some(&self.launcher.bufs[idx as usize]), 0, 0);
            surface.damage(0, 0, self.launcher.w, self.launcher.h);
            let r = self.compositor.create_region(&self.qh, ());
            r.add(0, 0, self.launcher.w, self.launcher.h);
            surface.set_input_region(Some(&r));
            r.destroy();
            let _cb = surface.frame(&self.qh, LauncherCb);
            surface.commit();
        }
        self.launcher.dirty = false;
        self.launcher.frame_pending = true;
        let _ = self.conn.flush();
    }

    pub fn show_launcher(&mut self) {
        if self.launcher.visible { eprintln!("[LOG] show_launcher: already visible"); return }
        let surface = self.compositor.create_surface(&self.qh, ());
        let layer = self.layer_shell.get_layer_surface(
            &surface, None, Layer::Overlay, "mist-launcher".into(), &self.qh, (),
        );
        layer.set_anchor(Anchor::Top | Anchor::Bottom | Anchor::Left | Anchor::Right);
        layer.set_exclusive_zone(0);
        layer.set_keyboard_interactivity(KeyboardInteractivity::Exclusive);
        surface.commit();
        self.launcher.surface = Some(surface);
        self.launcher.layer = Some(layer);
        self.launcher.visible = true;
        self.launcher.configured = false;
        self.launcher.frame_pending = false;
        self.launcher.dirty = true;
        self.launcher.query.clear();
        self.launcher.scroll_offset = 0;
        self.launcher.is_action_mode = false;

        if self.launcher.apps.is_empty() {
            self.launcher.apps = launcher::scan_apps();
        }
        if self.launcher.actions.is_empty() {
            self.launcher.actions = launcher::ACTIONS.iter().map(|a| launcher::LauncherAction {
                name: a.name, icon: a.icon, description: a.description, command: a.command,
            }).collect();
        }

        self.launcher.matching = (0..self.launcher.apps.len()).collect();
        self.launcher.matching_actions.clear();
        self.launcher.selection = 0;

        let _ = self.conn.flush();
    }

    pub fn update_launcher_filter(&mut self) {
        let q = self.launcher.query.clone();
        if let Some(stripped) = q.strip_prefix('>') {
            self.launcher.is_action_mode = true;
            let action_q = stripped.trim().to_string();
            let mut scored: Vec<(u32, usize)> = self.launcher.actions.iter().enumerate()
                .filter_map(|(i, a)| Some((launcher::fuzzy_match(&action_q, &a.name)?, i)))
                .collect();
            scored.sort_by(|a, b| b.0.cmp(&a.0));
            self.launcher.matching_actions = scored.into_iter().map(|(_, i)| i).collect();
            self.launcher.scroll_offset = 0;
            self.launcher.selection = 0;
        } else {
            self.launcher.is_action_mode = false;
            let mut scored: Vec<(u32, usize)> = self.launcher.apps.iter().enumerate()
                .filter_map(|(i, a)| Some((launcher::fuzzy_match(&q, &a.name)?, i)))
                .collect();
            scored.sort_by(|a, b| b.0.cmp(&a.0));
            self.launcher.matching = scored.into_iter().map(|(_, i)| i).collect();
            self.launcher.scroll_offset = 0;
            if !self.launcher.matching.is_empty() {
                self.launcher.selection = self.launcher.selection.min(self.launcher.matching.len() - 1);
            }
        }
        self.launcher.dirty = true;
        if self.launcher.configured && !self.launcher.frame_pending {
            let panel = launcher::render_launcher(self);
            self.launcher.panel = Some(panel);
            self.commit_launcher();
        }
    }

    pub fn ensure_selection_visible(&mut self) {
        let h = self.launcher.h as f32;
        let panel_h = (h * 0.65).clamp(240.0, 560.0);
        let pad = 12.0;
        let search_h = 42.0;
        let max_visible = ((panel_h - 2.0 * pad - search_h - 20.0) / 38.0).max(1.0) as usize;
        if max_visible == 0 { return }
        let sel = self.launcher.selection;
        let scroll = &mut self.launcher.scroll_offset;
        if sel < *scroll {
            *scroll = sel;
        } else if sel >= *scroll + max_visible {
            *scroll = sel.saturating_sub(max_visible - 1);
        }
    }

    pub fn scroll_launcher(&mut self, delta: i32) {
        if delta == 0 { return }
        let h = self.launcher.h as f32;
        let panel_h = (h * 0.65).clamp(240.0, 560.0);
        let pad = 12.0;
        let search_h = 42.0;
        let max_visible = ((panel_h - 2.0 * pad - search_h - 20.0) / 38.0).max(1.0) as usize;
        let len = if self.launcher.is_action_mode { self.launcher.matching_actions.len() } else { self.launcher.matching.len() };
        let max_scroll = len.saturating_sub(max_visible);
        if delta > 0 {
            self.launcher.scroll_offset = self.launcher.scroll_offset.saturating_add(delta as usize).min(max_scroll);
        } else {
            self.launcher.scroll_offset = self.launcher.scroll_offset.saturating_sub((-delta) as usize);
        }
        self.launcher.dirty = true;
        if self.launcher.configured && !self.launcher.frame_pending {
            let panel = launcher::render_launcher(self);
            self.launcher.panel = Some(panel);
            self.commit_launcher();
        }
    }

    pub fn hide_launcher(&mut self) {
        if !self.launcher.visible { eprintln!("[LOG] hide_launcher: already hidden"); return }
        drop(self.launcher.layer.take());
        drop(self.launcher.surface.take());
        drop(self.launcher.pool.take());
        drop(self.launcher.mmap.take());
        self.launcher.bufs.clear();
        self.launcher.next_buf = 0;
        self.launcher.configured = false;
        self.launcher.frame_pending = false;
        self.launcher.dirty = false;
        self.launcher.visible = false;
        self.launcher.is_action_mode = false;
        self.launcher.matching_actions.clear();
        let _ = self.conn.flush();
    }
}
