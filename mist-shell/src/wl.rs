use std::fs::File;
use std::io::Read;
use std::os::unix::io::{FromRawFd, IntoRawFd};

use wayland_client::globals::GlobalListContents;
use wayland_client::protocol::wl_buffer::WlBuffer;
use wayland_client::protocol::wl_callback::WlCallback;
use wayland_client::protocol::wl_compositor::WlCompositor;
use wayland_client::protocol::wl_keyboard::{KeyState, WlKeyboard};
use wayland_client::protocol::wl_output::{Event as OutputEvent, WlOutput};
use wayland_client::protocol::wl_pointer::{Axis, ButtonState, WlPointer};
use wayland_client::protocol::wl_region::WlRegion;
use wayland_client::protocol::wl_seat::WlSeat;
use wayland_client::protocol::wl_shm::WlShm;
use wayland_client::protocol::wl_shm_pool::WlShmPool;
use wayland_client::protocol::wl_surface::WlSurface;
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle, WEnum};
use wayland_protocols::wp::cursor_shape::v1::client::wp_cursor_shape_device_v1::{Shape, WpCursorShapeDeviceV1};
use wayland_protocols::wp::cursor_shape::v1::client::wp_cursor_shape_manager_v1::WpCursorShapeManagerV1;
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_shell_v1::ZwlrLayerShellV1;
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_surface_v1::{self, ZwlrLayerSurfaceV1};
use xkbcommon::xkb::{self, keysyms};

use crate::bar::{hit_test_workspace, render_bar};
use crate::launcher;
use crate::state::{BarCb, LauncherCb, ShmTriple, State, SurfaceId};

fn create_bar_shm(state: &mut State) {
    let w = state.bar.w.max(1);
    let h = state.bar.h.max(1);
    state.bar.shm = ShmTriple::create(3, w, h, &state.shm, &state.qh, SurfaceId::Bar);
}

fn create_launcher_shm(state: &mut State) {
    let w = state.launcher.w.max(1);
    let h = state.launcher.h.max(1);
    state.launcher.shm = ShmTriple::create(3, w, h, &state.shm, &state.qh, SurfaceId::Launcher);
}

impl Dispatch<ZwlrLayerSurfaceV1, ()> for State {
    fn event(state: &mut Self, proxy: &ZwlrLayerSurfaceV1, event: <ZwlrLayerSurfaceV1 as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        match event {
            zwlr_layer_surface_v1::Event::Configure { serial, width, height } => {
                if proxy.id() == state.bar.layer.id() {
                    proxy.ack_configure(serial);
                    let scale = state.scale.max(1);
                    let buf_w = width.max(1) as i32 * scale;
                    let buf_h = height.max(1) as i32 * scale;
                    state.bar.surface.set_buffer_scale(scale);

                    if state.bar.w != buf_w || state.bar.h != buf_h {
                        state.bar.w = buf_w;
                        state.bar.h = buf_h;
                        if let Some(ref mut shm) = state.bar.shm {
                            shm.recreate_all(buf_w, buf_h, &state.shm, &state.qh, SurfaceId::Bar);
                        } else {
                            create_bar_shm(state);
                        }
                    } else if state.bar.shm.is_none() {
                        create_bar_shm(state);
                    }

                    state.bar.configured = true;
                    render_bar(state);
                    state.commit_bar();
                } else if let Some(ref l) = state.launcher.layer
                    && proxy.id() == l.id() {
                    proxy.ack_configure(serial);
                    let scale = state.scale.max(1);
                    let w = if width > 0 { width as i32 } else { 1920 };
                    let h = if height > 0 { height as i32 } else { 1080 };
                    let buf_w = w * scale;
                    let buf_h = h * scale;
                    if let Some(ref surface) = state.launcher.surface {
                        surface.set_buffer_scale(scale);
                    }

                    if state.launcher.w != buf_w || state.launcher.h != buf_h {
                        state.launcher.w = buf_w;
                        state.launcher.h = buf_h;
                        if let Some(ref mut shm) = state.launcher.shm {
                            shm.recreate_all(buf_w, buf_h, &state.shm, &state.qh, SurfaceId::Launcher);
                        } else {
                            create_launcher_shm(state);
                        }
                    } else if state.launcher.shm.is_none() {
                        create_launcher_shm(state);
                    }

                    state.launcher.configured = true;
                    let (_data, panel) = launcher::render_launcher(state);
                    state.launcher.panel = Some(panel);
                    state.commit_launcher();
                }
            }
            zwlr_layer_surface_v1::Event::Closed
                if proxy.id() == state.bar.layer.id() => {
                    std::process::exit(0);
                }
            _ => {}
        }
    }
}

impl Dispatch<WlCallback, ()> for State {
    fn event(_: &mut Self, _: &WlCallback, _: <WlCallback as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<WlCallback, BarCb> for State {
    fn event(state: &mut Self, _: &WlCallback, event: <WlCallback as wayland_client::Proxy>::Event, _: &BarCb, _: &Connection, _: &QueueHandle<Self>) {
        if let wayland_client::protocol::wl_callback::Event::Done { .. } = event {
            state.bar.frame_pending = false;
            if state.bar.dirty && state.bar.configured {
                render_bar(state);
                state.commit_bar();
            }
        }
    }
}

impl Dispatch<WlCallback, LauncherCb> for State {
    fn event(state: &mut Self, _: &WlCallback, event: <WlCallback as wayland_client::Proxy>::Event, _: &LauncherCb, _: &Connection, _: &QueueHandle<Self>) {
        if let wayland_client::protocol::wl_callback::Event::Done { .. } = event {
            state.launcher.frame_pending = false;
            state.flush_launcher_render();
        }
    }
}

impl Dispatch<wayland_client::protocol::wl_display::WlDisplay, GlobalListContents> for State {
    fn event(_: &mut Self, _: &wayland_client::protocol::wl_display::WlDisplay, _: <wayland_client::protocol::wl_display::WlDisplay as wayland_client::Proxy>::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wayland_client::protocol::wl_registry::WlRegistry, GlobalListContents> for State {
    fn event(_: &mut Self, _: &wayland_client::protocol::wl_registry::WlRegistry, _: <wayland_client::protocol::wl_registry::WlRegistry as wayland_client::Proxy>::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<WlCompositor, ()> for State {
    fn event(_: &mut Self, _: &WlCompositor, _: <WlCompositor as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<WlOutput, ()> for State {
    fn event(state: &mut Self, _proxy: &WlOutput, event: <WlOutput as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let OutputEvent::Scale { factor } = event {
            state.scale = factor;
            state.bar.dirty = true;
        }
    }
}

impl Dispatch<WlRegion, ()> for State {
    fn event(_: &mut Self, _: &WlRegion, _: <WlRegion as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<WlSurface, ()> for State {
    fn event(_: &mut Self, _: &WlSurface, _: <WlSurface as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<ZwlrLayerShellV1, ()> for State {
    fn event(_: &mut Self, _: &ZwlrLayerShellV1, _: <ZwlrLayerShellV1 as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<WlShm, ()> for State {
    fn event(_: &mut Self, _: &WlShm, _: <WlShm as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<WlShmPool, ()> for State {
    fn event(_: &mut Self, _: &WlShmPool, _: <WlShmPool as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

// wl_buffer release events: route to bar or launcher based on SurfaceId user data
impl Dispatch<WlBuffer, SurfaceId> for State {
    fn event(state: &mut Self, proxy: &WlBuffer, event: <WlBuffer as Proxy>::Event, ud: &SurfaceId, _: &Connection, _: &QueueHandle<Self>) {
        if let wayland_client::protocol::wl_buffer::Event::Release = event {
            match ud {
                SurfaceId::Bar => state.mark_bar_buffer_released(proxy.id()),
                SurfaceId::Launcher => state.mark_launcher_buffer_released(proxy.id()),
            }
        }
    }
}

impl Dispatch<WlSeat, ()> for State {
    fn event(state: &mut Self, proxy: &WlSeat, event: <WlSeat as wayland_client::Proxy>::Event, _: &(), _: &Connection, qh: &QueueHandle<Self>) {
        if let wayland_client::protocol::wl_seat::Event::Capabilities { capabilities } = event
            && let WEnum::Value(caps) = capabilities
        {
            if caps.contains(wayland_client::protocol::wl_seat::Capability::Pointer) {
                let pointer = proxy.get_pointer(qh, ());
                if let Some(ref mgr) = state.cursor_shape_manager {
                    state.cursor_shape_device = Some(mgr.get_pointer(&pointer, qh, ()));
                }
                state.pointer = Some(pointer);
            }
            if caps.contains(wayland_client::protocol::wl_seat::Capability::Keyboard) {
                state.keyboard = Some(proxy.get_keyboard(qh, ()));
            }
        }
    }
}

impl Dispatch<WlKeyboard, ()> for State {
    fn event(state: &mut Self, _: &WlKeyboard, event: <WlKeyboard as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        use wayland_client::protocol::wl_keyboard::Event;
        match event {
            Event::Keymap { format: WEnum::Value(wayland_client::protocol::wl_keyboard::KeymapFormat::XkbV1), fd, size } => {
                let raw = fd.into_raw_fd();
                let dup = unsafe { libc::dup(raw) };
                unsafe { libc::close(raw); }
                if dup < 0 { eprintln!("dup(keymap fd) failed"); return; }
                let mut file = unsafe { File::from_raw_fd(dup) };
                let mut buf = String::with_capacity(size as usize);
                if file.read_to_string(&mut buf).is_ok() && !buf.is_empty() {
                    let ctx = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
                    if let Some(km) = xkb::Keymap::new_from_string(&ctx, buf, xkb::KEYMAP_FORMAT_TEXT_V1, xkb::KEYMAP_COMPILE_NO_FLAGS) {
                        let st = xkb::State::new(&km);
                        state.xkb_ctx = Some(ctx);
                        state.xkb_state = Some(st);
                        return;
                    }
                }
                let ctx = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
                if let Some(km) = xkb::Keymap::new_from_names(&ctx, "", "", "us", "", None, xkb::KEYMAP_COMPILE_NO_FLAGS) {
                    let st = xkb::State::new(&km);
                    state.xkb_ctx = Some(ctx);
                    state.xkb_state = Some(st);
                }
            }
            Event::Key { key, state: ks, .. } => {
                let pressed = matches!(ks, WEnum::Value(KeyState::Pressed));
                let kc: xkb::Keycode = (key + 8).into();
                if let Some(ref mut xkb_st) = state.xkb_state {
                    if pressed {
                        xkb_st.update_key(kc, xkb::KeyDirection::Down);
                    } else {
                        xkb_st.update_key(kc, xkb::KeyDirection::Up);
                        return;
                    }
                } else {
                    return;
                }
                if !state.launcher.visible { return }
                let (sym, utf8) = match state.xkb_state.as_ref() {
                    Some(s) => (s.key_get_one_sym(kc), s.key_get_utf8(kc)),
                    None => return,
                };
                if sym == keysyms::KEY_Escape.into() {
                    state.hide_launcher();
                } else if sym == keysyms::KEY_Return.into() || sym == keysyms::KEY_KP_Enter.into() {
                    if state.launcher.view == crate::launcher::LauncherView::CalcResult && state.launcher.selection == 0 {
                        if let Some(ref res) = state.launcher.calc_result {
                            let _ = std::process::Command::new("wl-copy").arg(res).spawn();
                        }
                        state.hide_launcher();
                    } else if state.launcher.view == crate::launcher::LauncherView::ActionList {
                        if let Some(&act_idx) = state.launcher.matching_actions.get(state.launcher.selection)
                            && let Some(act) = state.launcher.actions.get(act_idx) {
                                if act.command.first().copied() == Some("autocomplete") {
                                    if let Some(cmd) = act.command.get(1) {
                                        state.launcher.query = format!(">{} ", cmd);
                                        state.update_launcher_filter();
                                    }
                                } else if act.command.first().copied() == Some("setMode") {
                                    if let Some(_mode) = act.command.get(1) {
                                        state.hide_launcher();
                                    }
                                } else {
                                    let exec = act.command.join(" ");
                                    if !exec.is_empty() { crate::launcher::launch_app(&exec); }
                                    state.hide_launcher();
                                }
                            } else {
                                state.hide_launcher();
                            }
                    } else {
                        if let Some(&idx) = state.launcher.matching.get(state.launcher.selection)
                            && let Some(app) = state.launcher.apps.get(idx) {
                                crate::launcher::launch_desktop_app(app, None);
                            }
                        state.hide_launcher();
                    }
                } else if sym == keysyms::KEY_BackSpace.into() {
                    state.launcher.query.pop();
                    state.update_launcher_filter();
                } else if sym == keysyms::KEY_Up.into() {
                    let len = match state.launcher.view {
                        crate::launcher::LauncherView::ActionList | crate::launcher::LauncherView::CalcResult => state.launcher.matching_actions.len(),
                        crate::launcher::LauncherView::AppList => state.launcher.matching.len(),
                    };
                    if len > 0 && state.launcher.selection > 0 {
                        state.launcher.selection -= 1;
                        state.ensure_selection_visible();
                        state.launcher.dirty = true;
                        state.flush_launcher_render();
                    }
                } else if sym == keysyms::KEY_Down.into() {
                    let len = match state.launcher.view {
                        crate::launcher::LauncherView::ActionList | crate::launcher::LauncherView::CalcResult => state.launcher.matching_actions.len(),
                        crate::launcher::LauncherView::AppList => state.launcher.matching.len(),
                    };
                    if len > 0 && state.launcher.selection + 1 < len {
                        state.launcher.selection += 1;
                        state.ensure_selection_visible();
                        state.launcher.dirty = true;
                        state.flush_launcher_render();
                    }
                } else if !utf8.is_empty() && utf8.chars().all(|c| !c.is_control()) {
                    state.launcher.query.push_str(&utf8);
                    state.update_launcher_filter();
                }
            }
            Event::Modifiers { mods_depressed, mods_latched, mods_locked, group, .. } => {
                if let Some(ref mut xkb_st) = state.xkb_state {
                    xkb_st.update_mask(mods_depressed, mods_latched, mods_locked, 0, 0, group);
                }
            }
            _ => {}
        }
    }
}

fn in_search_bar(px: f32, py: f32, pw: f32, ph: f32, sx: f32, sy: f32) -> bool {
    let pad = 12.0;
    let search_h = 42.0;
    let search_x = px + pad;
    let search_y = py + ph - pad - search_h;
    sx >= search_x && sx <= search_x + pw - pad * 2.0 && sy >= search_y && sy <= search_y + search_h
}

fn set_search_cursor(state: &mut State, serial: u32) {
    if state.current_cursor == Some(Shape::Text) { return }
    if let Some(ref dev) = state.cursor_shape_device {
        dev.set_shape(serial, Shape::Text);
        state.current_cursor = Some(Shape::Text);
    }
}

fn set_default_cursor(state: &mut State, serial: u32) {
    if state.current_cursor == Some(Shape::Default) { return }
    if let Some(ref dev) = state.cursor_shape_device {
        dev.set_shape(serial, Shape::Default);
        state.current_cursor = Some(Shape::Default);
    }
}

impl Dispatch<WlPointer, ()> for State {
    fn event(state: &mut Self, _: &WlPointer, event: <WlPointer as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        match event {
            wayland_client::protocol::wl_pointer::Event::Enter { surface_x, surface_y, serial, .. } => {
                state.current_cursor = None;
                state.pointer_x = surface_x;
                state.pointer_y = surface_y;
                state.pointer_serial = serial;
                if let Some((px, py, pw, ph)) = state.launcher.panel
                    && in_search_bar(px, py, pw, ph, surface_x as f32, surface_y as f32) {
                        set_search_cursor(state, serial);
                    } else {
                        set_default_cursor(state, serial);
                    }
                update_hover(state);
            }
            wayland_client::protocol::wl_pointer::Event::Motion { surface_x, surface_y, .. } => {
                state.pointer_x = surface_x;
                state.pointer_y = surface_y;
                if let Some((px, py, pw, ph)) = state.launcher.panel
                    && in_search_bar(px, py, pw, ph, surface_x as f32, surface_y as f32) {
                        set_search_cursor(state, state.pointer_serial);
                    } else {
                        set_default_cursor(state, state.pointer_serial);
                    }
                update_hover(state);
            }
            wayland_client::protocol::wl_pointer::Event::Leave { .. } => {
                state.current_cursor = None;
                set_default_cursor(state, state.pointer_serial);
                if state.hovered_ws.is_some() {
                    state.hovered_ws = None;
                    state.bar.dirty = true;
                    if state.bar.configured && !state.bar.frame_pending {
                        render_bar(state);
                        state.commit_bar();
                    }
                }
            }
            wayland_client::protocol::wl_pointer::Event::Button { button, state: btn_state, serial, .. } => {
                let press = matches!(btn_state, WEnum::Value(ButtonState::Pressed));
                if press {
                    state.pointer_serial = serial;
                }
                if state.launcher.visible {
                    if press {
                        if state.launcher.configured {
                            if let Some((px, py, pw, ph)) = state.launcher.panel {
                                let (sx, sy) = (state.pointer_x as f32, state.pointer_y as f32);
                                if sx >= px && sx <= px + pw && sy >= py && sy <= py + ph {
                                    let lay = crate::launcher::compute_panel(state.launcher.w as f32, state.launcher.h as f32, 1.0);
                                    let rel_y = sy - lay.start_y;
                                    if rel_y >= 0.0 && sy < lay.div_y {
                                        let row = (rel_y / lay.item_h) as usize;
                                        if row < lay.max_visible {
                                            let idx = state.launcher.scroll_offset + row;
                                            if state.launcher.view != crate::launcher::LauncherView::AppList {
                                                if let Some(&act_idx) = state.launcher.matching_actions.get(idx)
                                                    && let Some(act) = state.launcher.actions.get(act_idx) {
                                                        if act.command.first().copied() == Some("autocomplete") {
                                                            if let Some(cmd) = act.command.get(1) {
                                                                state.launcher.query = format!(">{} ", cmd);
                                                                state.update_launcher_filter();
                                                                return;
                                                            }
                                                        } else if act.command.first().copied() == Some("setMode") {
                                                            state.hide_launcher();
                                                            return;
                                                        } else {
                                                            let exec = act.command.join(" ");
                                                            if !exec.is_empty() { launcher::launch_app(&exec); }
                                                            state.hide_launcher();
                                                            return;
                                                        }
                                                    }
                                            } else if let Some(&app_idx) = state.launcher.matching.get(idx)
                                                && let Some(app) = state.launcher.apps.get(app_idx) {
                                                    launcher::launch_desktop_app(app, None);
                                                    state.hide_launcher();
                                                    return;
                                                }
                                        }
                                    }
                                    return;
                                }
                            }
                        }
                        state.hide_launcher();
                    }
                } else if press && button == 0x110 {
                    let ws_idx = hit_test_workspace(state, state.pointer_x, state.pointer_y);
                    if let Some(idx) = ws_idx {
                        if let Some(ws_name) = state.workspaces.get(idx).map(|(n, _)| n.clone()) {
                            for (name, tag) in &mut state.workspaces {
                                tag.active = *name == ws_name;
                            }
                            state.bar.dirty = true;
                            if state.bar.configured {
                                render_bar(state);
                                state.commit_bar();
                            }
                            crate::compositor::focus_workspace(state.compositor_type, &ws_name);
                        }
                    }
                }
            }
            wayland_client::protocol::wl_pointer::Event::Axis { axis, value, .. } => {
                if let WEnum::Value(Axis::VerticalScroll) = axis {
                    if state.launcher.visible {
                        if let Some((px, py, pw, ph)) = state.launcher.panel {
                            let (sx, sy) = (state.pointer_x as f32, state.pointer_y as f32);
                            if sx >= px && sx <= px + pw && sy >= py && sy <= py + ph {
                                state.scroll_launcher(value.signum() as i32 * 3);
                                return;
                            }
                        }
                        return;
                    }
                    if hit_test_workspace(state, state.pointer_x, state.pointer_y).is_some() {
                        let dir = if value > 0.0 { 1 } else { -1 };
                        let idx = state.workspaces.iter().position(|(_, t)| t.active).unwrap_or(0);
                        let n = state.workspaces.len();
                        let new_idx = if dir > 0 { (idx + 1) % n } else { (idx + n - 1) % n };
                        let ws_name = state.workspaces.get(new_idx).map(|(n, _)| n.clone());
                        for (_, tag) in &mut state.workspaces { tag.active = false; }
                        if let Some((_, tag)) = state.workspaces.get_mut(new_idx) { tag.active = true; }
                        state.bar.dirty = true;
                        if state.bar.configured && !state.bar.frame_pending {
                            render_bar(state);
                            state.commit_bar();
                        }
                        if let Some(ref name) = ws_name {
                            crate::compositor::focus_workspace(state.compositor_type, name);
                        }
                    }
                }
            }
            _ => {}
        }
    }
}

fn update_hover(state: &mut State) {
    let old = state.hovered_ws;
    state.hovered_ws = hit_test_workspace(state, state.pointer_x, state.pointer_y);
    if old != state.hovered_ws {
        state.bar.dirty = true;
        if state.bar.configured && !state.bar.frame_pending {
            render_bar(state);
            state.commit_bar();
        }
    }
}

impl Dispatch<WpCursorShapeManagerV1, ()> for State {
    fn event(_: &mut Self, _: &WpCursorShapeManagerV1, _: <WpCursorShapeManagerV1 as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<WpCursorShapeDeviceV1, ()> for State {
    fn event(_: &mut Self, _: &WpCursorShapeDeviceV1, _: <WpCursorShapeDeviceV1 as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
