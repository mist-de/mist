use std::os::unix::io::{BorrowedFd, RawFd};
use std::time::Instant;

use wayland_client::protocol::wl_compositor::WlCompositor;
use wayland_client::protocol::wl_keyboard::WlKeyboard;
use wayland_client::protocol::wl_pointer::WlPointer;
use wayland_client::protocol::wl_shm::WlShm;
use wayland_client::protocol::wl_surface::WlSurface;
use wayland_client::{Connection, Proxy, QueueHandle};
use wayland_protocols::wp::cursor_shape::v1::client::wp_cursor_shape_device_v1::{Shape, WpCursorShapeDeviceV1};
use wayland_protocols::wp::cursor_shape::v1::client::wp_cursor_shape_manager_v1::WpCursorShapeManagerV1;
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_shell_v1::{Layer, ZwlrLayerShellV1};
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_surface_v1::{Anchor, KeyboardInteractivity, ZwlrLayerSurfaceV1};
use xkbcommon::xkb;

use crate::compositor::CompositorType;
use crate::launcher;

pub type WsList = Vec<(String, Tag)>;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Tag {
    pub active: bool,
    pub urgent: bool,
    pub occupied: bool,
}

/// Identifies which surface created a wl_buffer, so release events route back.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum SurfaceId {
    #[default]
    Bar,
    Launcher,
}

/// A single wl_shm buffer slot: owns the memfd, mmap, pool, wl_buffer.
/// Cairo surface for rendering is created temporarily each frame
/// from the mmap'd data (avoids self-referencing struct issues).
pub struct ShmSlot {
    pub fd: RawFd,
    pub ptr: *mut u8,
    pub size: usize,
    pub pool: wayland_client::protocol::wl_shm_pool::WlShmPool,
    pub wl_buffer: wayland_client::protocol::wl_buffer::WlBuffer,
    pub width: i32,
    pub height: i32,
    pub stride: i32,
    pub released: bool,
}

unsafe impl Send for ShmSlot {}

impl ShmSlot {
    pub unsafe fn data_mut(&mut self) -> &mut [u8] {
        unsafe { std::slice::from_raw_parts_mut(self.ptr, self.size) }
    }

    pub fn create(width: i32, height: i32, shm: &WlShm, qh: &QueueHandle<super::State>, sid: SurfaceId) -> Option<Self> {
        let stride = width * 4;
        let size = (height * stride) as usize;
        let c_name = std::ffi::CString::new("mist-shm").ok()?;

        let fd = unsafe {
            let fd = libc::syscall(libc::SYS_memfd_create, c_name.as_ptr(), libc::MFD_CLOEXEC) as RawFd;
            if fd < 0 { return None }
            if libc::ftruncate(fd, size as i64) < 0 {
                libc::close(fd);
                return None;
            }
            fd
        };

        let ptr = unsafe {
            let p = libc::mmap(
                std::ptr::null_mut(),
                size,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                fd,
                0,
            );
            if p == libc::MAP_FAILED {
                libc::close(fd);
                return None;
            }
            p as *mut u8
        };

        let borrowed = unsafe { BorrowedFd::borrow_raw(fd) };
        let pool = shm.create_pool(borrowed, size as i32, qh, ());
        let wl_buffer = pool.create_buffer(0, width, height, stride, wayland_client::protocol::wl_shm::Format::Argb8888, qh, sid);

        Some(ShmSlot { fd, ptr, size, pool, wl_buffer, width, height, stride, released: true })
    }

    pub fn recreate(&mut self, width: i32, height: i32, shm: &WlShm, qh: &QueueHandle<super::State>, sid: SurfaceId) -> bool {
        let stride = width * 4;
        let size = (height * stride) as usize;

        let c_name = std::ffi::CString::new("mist-shm").ok().unwrap();
        let fd = unsafe {
            let fd = libc::syscall(libc::SYS_memfd_create, c_name.as_ptr(), libc::MFD_CLOEXEC) as RawFd;
            if fd < 0 { return false; }
            if libc::ftruncate(fd, size as i64) < 0 {
                libc::close(fd);
                return false;
            }
            fd
        };

        let ptr = unsafe {
            let p = libc::mmap(
                std::ptr::null_mut(),
                size,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                fd,
                0,
            );
            if p == libc::MAP_FAILED {
                libc::close(fd);
                return false;
            }
            p as *mut u8
        };

        // Destroy old Wayland objects BEFORE replacing fd/ptr
        self.wl_buffer.destroy();
        self.pool.destroy();
        unsafe {
            libc::munmap(self.ptr as *mut libc::c_void, self.size);
            libc::close(self.fd);
        }

        self.fd = fd;
        self.ptr = ptr;
        self.size = size;
        self.width = width;
        self.height = height;
        self.stride = stride;
        let borrowed = unsafe { BorrowedFd::borrow_raw(fd) };
        self.pool = shm.create_pool(borrowed, size as i32, qh, ());
        self.wl_buffer = self.pool.create_buffer(0, width, height, stride, wayland_client::protocol::wl_shm::Format::Argb8888, qh, sid);
        self.released = true;
        true
    }
}

impl Drop for ShmSlot {
    fn drop(&mut self) {
        self.wl_buffer.destroy();
        self.pool.destroy();
        unsafe {
            libc::munmap(self.ptr as *mut libc::c_void, self.size);
            libc::close(self.fd);
        }
    }
}

/// Holds 3 shm slots for triple buffering.
pub struct ShmTriple {
    pub slots: Vec<ShmSlot>,
    pub next: usize,
}

impl ShmTriple {
    pub fn create(count: usize, width: i32, height: i32, shm: &WlShm, qh: &QueueHandle<super::State>, sid: SurfaceId) -> Option<Self> {
        let mut slots = Vec::with_capacity(count);
        for _ in 0..count {
            slots.push(ShmSlot::create(width, height, shm, qh, sid)?);
        }
        Some(ShmTriple { slots, next: 0 })
    }

    pub fn next_slot(&mut self) -> &mut ShmSlot {
        for i in 0..self.slots.len() {
            let idx = (self.next + i) % self.slots.len();
            if self.slots[idx].released {
                self.next = (idx + 1) % self.slots.len();
                return &mut self.slots[idx];
            }
        }
        let idx = self.next;
        self.next = (self.next + 1) % self.slots.len();
        &mut self.slots[idx]
    }

    pub fn recreate_all(&mut self, width: i32, height: i32, shm: &WlShm, qh: &QueueHandle<super::State>, sid: SurfaceId) -> bool {
        for slot in &mut self.slots {
            if !slot.recreate(width, height, shm, qh, sid) {
                return false;
            }
        }
        self.next = 0;
        true
    }
}

#[allow(dead_code)]
pub struct BarCb;
#[allow(dead_code)]
pub struct LauncherCb;

pub struct BarSurface {
    pub surface: WlSurface,
    pub layer: ZwlrLayerSurfaceV1,
    pub w: i32,
    pub h: i32,
    pub configured: bool,
    pub frame_pending: bool,
    pub dirty: bool,
    pub shm: Option<ShmTriple>,
}

pub struct LauncherSurface {
    pub surface: Option<WlSurface>,
    pub layer: Option<ZwlrLayerSurfaceV1>,
    pub w: i32,
    pub h: i32,
    pub configured: bool,
    pub frame_pending: bool,
    pub dirty: bool,
    pub shm: Option<ShmTriple>,
    pub visible: bool,
    pub apps: Vec<launcher::App>,
    pub matching: Vec<usize>,
    pub view: launcher::LauncherView,
    pub matching_actions: Vec<usize>,
    pub selection: usize,
    pub query: String,
    pub scroll_offset: usize,
    pub panel: Option<(f32, f32, f32, f32)>,
    pub actions: Vec<launcher::LauncherAction>,
    pub start_time: Instant,
    pub calc_result: Option<String>,
}

pub struct State {
    pub conn: Connection,
    pub qh: QueueHandle<State>,
    pub compositor: WlCompositor,
    pub layer_shell: ZwlrLayerShellV1,
    pub shm: WlShm,
    pub bar: BarSurface,
    pub launcher: LauncherSurface,
    pub pointer: Option<WlPointer>,
    pub keyboard: Option<WlKeyboard>,
    pub pointer_x: f64,
    pub pointer_y: f64,
    pub pointer_serial: u32,
    pub cursor_shape_manager: Option<WpCursorShapeManagerV1>,
    pub cursor_shape_device: Option<WpCursorShapeDeviceV1>,
    pub current_cursor: Option<Shape>,
    pub compositor_type: CompositorType,
    pub clock: String,
    pub date: String,
    pub workspaces: WsList,
    pub xkb_ctx: Option<xkb::Context>,
    pub xkb_state: Option<xkb::State>,
    pub config: crate::config::MistConfig,
    pub status: crate::status::SystemStatus,
    pub hovered_ws: Option<usize>,
    pub scale: i32,
}

impl State {
    pub fn commit_bar(&mut self) {
        let Some(ref mut shm_triple) = self.bar.shm else { return };
        let slot = shm_triple.next_slot();
        slot.released = false;
        self.bar.surface.attach(Some(&slot.wl_buffer), 0, 0);
        self.bar.surface.damage_buffer(0, 0, self.bar.w, self.bar.h);
        self.bar.surface.frame(&self.qh, BarCb);
        self.bar.surface.commit();
        self.bar.frame_pending = true;
        self.bar.dirty = false;
        let _ = self.conn.flush();
    }

    pub fn commit_launcher(&mut self) {
        let Some(ref mut shm_triple) = self.launcher.shm else { return };
        let ref surface = match self.launcher.surface {
            Some(ref s) => s,
            None => return,
        };
        let slot = shm_triple.next_slot();
        slot.released = false;
        surface.attach(Some(&slot.wl_buffer), 0, 0);
        surface.damage_buffer(0, 0, self.launcher.w, self.launcher.h);
        surface.frame(&self.qh, LauncherCb);
        surface.commit();
        self.launcher.frame_pending = true;
        self.launcher.dirty = false;
        let _ = self.conn.flush();
    }

    pub fn mark_bar_buffer_released(&mut self, id: wayland_client::backend::ObjectId) {
        if let Some(ref mut shm) = self.bar.shm {
            for slot in &mut shm.slots {
                if slot.wl_buffer.id() == id {
                    slot.released = true;
                    return;
                }
            }
        }
    }

    pub fn mark_launcher_buffer_released(&mut self, id: wayland_client::backend::ObjectId) {
        if let Some(ref mut shm) = self.launcher.shm {
            for slot in &mut shm.slots {
                if slot.wl_buffer.id() == id {
                    slot.released = true;
                    return;
                }
            }
        }
    }

    pub fn flush_launcher_render(&mut self) {
        if self.launcher.dirty && self.launcher.configured && !self.launcher.frame_pending {
            if self.launcher.visible {
                let (_panel_data, panel_rect) = crate::launcher::render_launcher(self);
                self.launcher.panel = Some(panel_rect);
                if self.launcher.shm.is_some() {
                    self.commit_launcher();
                }
            } else {
                self.launcher.dirty = false;
            }
        }
    }

    pub fn show_launcher(&mut self) {
        if self.launcher.visible { return }
        let surface = self.compositor.create_surface(&self.qh, ());
        let layer = self.layer_shell.get_layer_surface(
            &surface, None, Layer::Overlay, "mist-launcher".into(), &self.qh, (),
        );
        layer.set_anchor(Anchor::Top | Anchor::Bottom | Anchor::Left | Anchor::Right);
        layer.set_exclusive_zone(-1);
        layer.set_keyboard_interactivity(KeyboardInteractivity::Exclusive);
        surface.commit();
        self.launcher.surface = Some(surface);
        self.launcher.layer = Some(layer);
        self.launcher.visible = true;
        self.launcher.configured = false;
        self.launcher.frame_pending = false;
        self.launcher.dirty = true;
        self.launcher.start_time = Instant::now();
        self.launcher.query.clear();
        self.launcher.scroll_offset = 0;
        self.launcher.view = launcher::LauncherView::AppList;

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
        let q = &self.launcher.query;
        if q.is_empty() {
            self.launcher.calc_result = None;
            self.launcher.view = launcher::LauncherView::AppList;
            self.launcher.matching = (0..self.launcher.apps.len()).collect();
            self.launcher.matching_actions.clear();
            self.launcher.scroll_offset = 0;
            self.launcher.selection = 0;
            self.launcher.dirty = true;
            self.flush_launcher_render();
            return;
        }
        if let Some(stripped) = q.strip_prefix('>') {
            if stripped.trim_start().starts_with("calc ") {
                self.launcher.view = launcher::LauncherView::CalcResult;
                let expr = stripped.trim_start().strip_prefix("calc ").unwrap_or("").trim();
                self.launcher.calc_result = if expr.is_empty() {
                    None
                } else {
                    crate::calc::eval(expr).or_else(|| Some("Error".into()))
                };
                self.launcher.matching_actions = (0..self.launcher.actions.len()).collect();
                self.launcher.scroll_offset = 0;
                self.launcher.selection = 0;
                self.launcher.dirty = true;
                self.flush_launcher_render();
                return;
            }
            let (field, actual_query) = launcher::parse_search_prefix(q);
            if field != launcher::FIELD_DEFAULT {
                self.launcher.calc_result = None;
                self.launcher.view = launcher::LauncherView::AppList;
                let qq = if actual_query.is_empty() { "" } else { actual_query };
                let mut scored: Vec<(u32, usize)> = self.launcher.apps.iter().enumerate()
                    .filter_map(|(i, a)| Some((launcher::fuzzy_match_app(qq, a, field)?, i)))
                    .collect();
                scored.sort_by_key(|b| std::cmp::Reverse(b.0));
                self.launcher.matching = scored.into_iter().map(|(_, i)| i).collect();
                self.launcher.matching_actions.clear();
                self.launcher.scroll_offset = 0;
                if !self.launcher.matching.is_empty() {
                    self.launcher.selection = self.launcher.selection.min(self.launcher.matching.len() - 1);
                } else {
                    self.launcher.selection = 0;
                }
            } else {
                self.launcher.calc_result = None;
                self.launcher.view = launcher::LauncherView::ActionList;
                let action_q = stripped.trim();
                let mut scored: Vec<(u32, usize)> = self.launcher.actions.iter().enumerate()
                    .filter_map(|(i, a)| Some((launcher::fuzzy_match(action_q, a.name)?, i)))
                    .collect();
                scored.sort_by_key(|b| std::cmp::Reverse(b.0));
                self.launcher.matching_actions = scored.into_iter().map(|(_, i)| i).collect();
                self.launcher.scroll_offset = 0;
                self.launcher.selection = 0;
            }
        } else {
            self.launcher.calc_result = None;
            self.launcher.view = launcher::LauncherView::AppList;
            let mut scored: Vec<(u32, usize)> = self.launcher.apps.iter().enumerate()
                .filter_map(|(i, a)| Some((launcher::fuzzy_match_app(q, a, launcher::FIELD_DEFAULT)?, i)))
                .collect();
            scored.sort_by_key(|b| std::cmp::Reverse(b.0));
            self.launcher.matching = scored.into_iter().map(|(_, i)| i).collect();
            self.launcher.scroll_offset = 0;
            if !self.launcher.matching.is_empty() {
                self.launcher.selection = self.launcher.selection.min(self.launcher.matching.len() - 1);
            } else {
                self.launcher.selection = 0;
            }
        }
        self.launcher.dirty = true;
        self.flush_launcher_render();
    }

    pub fn ensure_selection_visible(&mut self) {
        let lay = launcher::compute_panel(self.launcher.w as f32, self.launcher.h as f32, 1.0);
        if lay.max_visible == 0 { return }
        let sel = self.launcher.selection;
        let scroll = &mut self.launcher.scroll_offset;
        if sel < *scroll {
            *scroll = sel;
        } else if sel >= *scroll + lay.max_visible {
            *scroll = sel.saturating_sub(lay.max_visible - 1);
        }
    }

    pub fn scroll_launcher(&mut self, delta: i32) {
        if delta == 0 { return }
        let old_offset = self.launcher.scroll_offset;
        let lay = launcher::compute_panel(self.launcher.w as f32, self.launcher.h as f32, 1.0);
        let len = match self.launcher.view {
            launcher::LauncherView::ActionList | launcher::LauncherView::CalcResult => self.launcher.matching_actions.len(),
            launcher::LauncherView::AppList => self.launcher.matching.len(),
        };
        let max_scroll = len.saturating_sub(lay.max_visible);
        if delta > 0 {
            self.launcher.scroll_offset = self.launcher.scroll_offset.saturating_add(delta as usize).min(max_scroll);
        } else {
            self.launcher.scroll_offset = self.launcher.scroll_offset.saturating_sub((-delta) as usize);
        }
        if self.launcher.scroll_offset == old_offset { return; }
        self.launcher.dirty = true;
    }

    pub fn hide_launcher(&mut self) {
        if !self.launcher.visible { return }
        if let Some(ref layer) = self.launcher.layer {
            layer.set_keyboard_interactivity(KeyboardInteractivity::None);
        }
        let _ = self.conn.flush();
        if let Some(l) = self.launcher.layer.take() { l.destroy(); }
        if let Some(s) = self.launcher.surface.take() { s.destroy(); }
        self.launcher.shm = None;
        self.launcher.configured = false;
        self.launcher.frame_pending = false;
        self.launcher.dirty = false;
        self.launcher.visible = false;
        self.launcher.view = launcher::LauncherView::AppList;
        self.launcher.matching_actions.clear();
        self.launcher.panel = None;
        let _ = self.conn.flush();
    }
}
