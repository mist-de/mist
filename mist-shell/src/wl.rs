use std::fs::File;
use std::io::Read;
use std::os::fd::FromRawFd;
use std::os::unix::io::IntoRawFd;


use wayland_client::globals::GlobalListContents;
use wayland_client::protocol::wl_buffer::WlBuffer;
use wayland_client::protocol::wl_callback::WlCallback;
use wayland_client::protocol::wl_compositor::WlCompositor;
use wayland_client::protocol::wl_keyboard::{KeyState, WlKeyboard};
use wayland_client::protocol::wl_pointer::{Axis, ButtonState, WlPointer};
use wayland_client::protocol::wl_region::WlRegion;
use wayland_client::protocol::wl_seat::WlSeat;
use wayland_client::protocol::wl_shm::WlShm;
use wayland_client::protocol::wl_shm_pool::WlShmPool;
use wayland_client::protocol::wl_surface::WlSurface;
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle, WEnum};
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_shell_v1::ZwlrLayerShellV1;
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_surface_v1::{self, ZwlrLayerSurfaceV1};
use xkbcommon::xkb::{self, keysyms};

use crate::bar::{render_bar, workspace_at_x};
use crate::launcher;
use crate::state::{BarCb, LauncherCb, State};

impl Dispatch<ZwlrLayerSurfaceV1, ()> for State {
    fn event(state: &mut Self, proxy: &ZwlrLayerSurfaceV1, event: <ZwlrLayerSurfaceV1 as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        match event {
            zwlr_layer_surface_v1::Event::Configure { serial, width, height } => {

                    if proxy.id() == state.bar.layer.id() {
                    proxy.ack_configure(serial);
                    let w = if width > 0 { width as i32 } else { 1920 };
                    let h = if height > 0 { (height as i32).min(crate::bar::BAR_H as i32) } else { crate::bar::BAR_H as i32 };
                    let stride = w * 4;
                    let buf_size = stride * h;
                    if state.bar.pool.is_none() || state.bar.stride != stride || state.bar.buf_size < buf_size {
                        let (mmap, pool, _, _) = crate::shm::setup_shm(&state.shm, &state.qh, w, h);
                        state.bar.pool = Some(pool);
                        state.bar.mmap = Some(mmap);
                        state.bar.stride = stride;
                        state.bar.buf_size = buf_size;
                        state.bar.bufs.clear();
                        state.bar.next_buf = 0;
                    }
                    state.bar.w = w;
                    state.bar.h = h;
                    state.bar.configured = true;
                    render_bar(state);
                    state.commit_bar();
                } else if let Some(ref l) = state.launcher.layer
                    && proxy.id() == l.id() {
                        proxy.ack_configure(serial);
                        let w = if width > 0 { width as i32 } else { 1920 };
                        let h = if height > 0 { height as i32 } else { 1080 };
                        let stride = w * 4;
                        let buf_size = stride * h;
                        if state.launcher.pool.is_none() || state.launcher.stride != stride || state.launcher.buf_size < buf_size {
                            let (mmap, pool, _, _) = crate::shm::setup_shm(&state.shm, &state.qh, w, h);
                            state.launcher.pool = Some(pool);
                            state.launcher.mmap = Some(mmap);
                            state.launcher.stride = stride;
                            state.launcher.buf_size = buf_size;
                            state.launcher.bufs.clear();
                            state.launcher.next_buf = 0;
                        }
                        state.launcher.w = w;
                        state.launcher.h = h;
                        state.launcher.configured = true;
                        let panel = launcher::render_launcher(state);
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
            if state.launcher.dirty && state.launcher.configured && state.launcher.visible {
                let panel = launcher::render_launcher(state);
                state.launcher.panel = Some(panel);
                state.commit_launcher();
            }
        }
    }
}

impl Dispatch<WlBuffer, ()> for State {
    fn event(_: &mut Self, _: &WlBuffer, _: <WlBuffer as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wayland_client::protocol::wl_display::WlDisplay, GlobalListContents> for State {
    fn event(_: &mut Self, _: &wayland_client::protocol::wl_display::WlDisplay, _: <wayland_client::protocol::wl_display::WlDisplay as wayland_client::Proxy>::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wayland_client::protocol::wl_registry::WlRegistry, GlobalListContents> for State {
    fn event(_: &mut Self, _: &wayland_client::protocol::wl_registry::WlRegistry, _: <wayland_client::protocol::wl_registry::WlRegistry as wayland_client::Proxy>::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<WlShm, ()> for State {
    fn event(_: &mut Self, _: &WlShm, _: <WlShm as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<WlShmPool, ()> for State {
    fn event(_: &mut Self, _: &WlShmPool, _: <WlShmPool as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<WlCompositor, ()> for State {
    fn event(_: &mut Self, _: &WlCompositor, _: <WlCompositor as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
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

impl Dispatch<WlSeat, ()> for State {
    fn event(state: &mut Self, proxy: &WlSeat, event: <WlSeat as wayland_client::Proxy>::Event, _: &(), _: &Connection, qh: &QueueHandle<Self>) {
        if let wayland_client::protocol::wl_seat::Event::Capabilities { capabilities } = event
            && let WEnum::Value(caps) = capabilities
        {
            if caps.contains(wayland_client::protocol::wl_seat::Capability::Pointer) {
                state.pointer = Some(proxy.get_pointer(qh, ()));
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
                    if state.launcher.is_action_mode {
                        if let Some(&act_idx) = state.launcher.matching_actions.get(state.launcher.selection) {
                            if let Some(act) = state.launcher.actions.get(act_idx) {
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
                            }
                        } else {
                            state.hide_launcher();
                        }
                    } else {
                        if let Some(&idx) = state.launcher.matching.get(state.launcher.selection)
                            && let Some(app) = state.launcher.apps.get(idx) {
                                crate::launcher::launch_app(&app.exec);
                            }
                        state.hide_launcher();
                    }
                } else if sym == keysyms::KEY_BackSpace.into() {
                    state.launcher.query.pop();
                    state.update_launcher_filter();
                } else if sym == keysyms::KEY_Up.into() {
                    let len = if state.launcher.is_action_mode { state.launcher.matching_actions.len() } else { state.launcher.matching.len() };
                    if len > 0 && state.launcher.selection > 0 {
                        state.launcher.selection -= 1;
                        state.ensure_selection_visible();
                        state.launcher.dirty = true;
                        if state.launcher.configured && !state.launcher.frame_pending {
                            let panel = crate::launcher::render_launcher(state);
                            state.launcher.panel = Some(panel);
                            state.commit_launcher();
                        }
                    }
                } else if sym == keysyms::KEY_Down.into() {
                    let len = if state.launcher.is_action_mode { state.launcher.matching_actions.len() } else { state.launcher.matching.len() };
                    if len > 0 && state.launcher.selection + 1 < len {
                        state.launcher.selection += 1;
                        state.ensure_selection_visible();
                        state.launcher.dirty = true;
                        if state.launcher.configured && !state.launcher.frame_pending {
                            let panel = crate::launcher::render_launcher(state);
                            state.launcher.panel = Some(panel);
                            state.commit_launcher();
                        }
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

impl Dispatch<WlPointer, ()> for State {
    fn event(state: &mut Self, _: &WlPointer, event: <WlPointer as wayland_client::Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        match event {
            wayland_client::protocol::wl_pointer::Event::Enter { surface, surface_x, surface_y, .. } => {
                state.pointer_x = surface_x;
                state.pointer_y = surface_y;
                state.current_surface = Some(surface);
            }
            wayland_client::protocol::wl_pointer::Event::Motion { surface_x, surface_y, .. } => {
                state.pointer_x = surface_x;
                state.pointer_y = surface_y;
            }
            wayland_client::protocol::wl_pointer::Event::Leave { .. } => {
                state.current_surface = None;
            }
            wayland_client::protocol::wl_pointer::Event::Button { button, state: btn_state, .. } => {
                let press = matches!(btn_state, WEnum::Value(ButtonState::Pressed));
                eprintln!("[LOG] Button: btn={:#x} press={} visible={} ptr=({:.0},{:.0})", button, press, state.launcher.visible, state.pointer_x, state.pointer_y);

                if state.launcher.visible {
                    if press {
                        if let Some((px, py, pw, ph)) = state.launcher.panel {
                            let sx = state.pointer_x as f32;
                            let sy = state.pointer_y as f32;
                            if sx >= px && sx <= px + pw && sy >= py && sy <= py + ph {
                                let start_y = py + 12.0;
                                let item_h = 38.0;
                                let rel_y = sy - start_y;
                                if rel_y >= 0.0 {
                                    let idx = (rel_y / item_h) as usize;
                                    if state.launcher.is_action_mode {
                                        if let Some(&act_idx) = state.launcher.matching_actions.get(idx)
                                            && let Some(act) = state.launcher.actions.get(act_idx) {
                                                if act.command.first().copied() == Some("autocomplete") {
                                                    if let Some(cmd) = act.command.get(1) {
                                                        state.launcher.query = format!(">{} ", cmd);
                                                        state.update_launcher_filter();
                                                        state.launcher.dirty = true;
                                                        if state.launcher.configured && !state.launcher.frame_pending {
                                                            let panel = launcher::render_launcher(state);
                                                            state.launcher.panel = Some(panel);
                                                            state.commit_launcher();
                                                        }
                                                        return;
                                                    }
                                                } else if act.command.first().copied() == Some("setMode") {
                                                    state.hide_launcher();
                                                    return;
                                                } else {
                                                    let exec = act.command.join(" ");
                                                    if !exec.is_empty() { launcher::launch_app(&exec); }
                                                }
                                            }
                                    } else if let Some(&app_idx) = state.launcher.matching.get(idx)
                                        && let Some(app) = state.launcher.apps.get(app_idx) {
                                            launcher::launch_app(&app.exec);
                                        }
                                }
                            }
                        }
                        state.hide_launcher();
                    }
                } else if press && button == 0x110 {
                    let ws = workspace_at_x(state, state.pointer_x).map(|s| s.to_string());
                    if let Some(ref ws) = ws {
                        eprintln!("[LOG] bar_click: switching to workspace {}", ws);
                        for (name, tag) in &mut state.workspaces {
                            tag.active = name == ws;
                        }
                        state.bar.dirty = true;
                        if state.bar.configured {
                            render_bar(state);
                            state.commit_bar();
                        }
                        if let Ok(idx) = ws.parse::<u32>() {
                            let _ = std::process::Command::new("mmsg")
                                .args(["dispatch", &format!("view,{}", idx)])
                                .spawn();
                        }
                    }
                }
            }
            wayland_client::protocol::wl_pointer::Event::Axis { axis, value, .. } => {
                if let WEnum::Value(Axis::VerticalScroll) = axis
                    && state.launcher.visible
                        && let Some((px, py, pw, ph)) = state.launcher.panel {
                            let (sx, sy) = (state.pointer_x as f32, state.pointer_y as f32);
                            if sx >= px && sx <= px + pw && sy >= py && sy <= py + ph {
                                state.scroll_launcher(value.signum() as i32 * 3);
                            }
                        }
            }
            _ => {}
        }
    }
}
