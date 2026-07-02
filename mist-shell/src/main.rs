mod bar;
mod ipc;
mod launcher;
mod render;
mod shell_ipc;
mod shm;
mod state;
mod text;
mod wl;

use std::os::fd::{AsFd, AsRawFd, BorrowedFd};
use std::time::Duration;

use calloop::channel::{self, Channel};
use calloop::generic::Generic;
use calloop::timer::{TimeoutAction, Timer};
use calloop::{EventLoop, Interest, Mode};
use wayland_client::globals::registry_queue_init;
use wayland_client::protocol::wl_compositor::WlCompositor;
use wayland_client::protocol::wl_seat::WlSeat;
use wayland_client::protocol::wl_shm::WlShm;
use wayland_client::Connection;
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_shell_v1::{Layer, ZwlrLayerShellV1};
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_surface_v1::Anchor;

use crate::bar::render_bar;
use crate::ipc::spawn_ipc;
use crate::shm::setup_shm;
use crate::state::{BarSurface, LauncherSurface, State, Tag, WsList};

fn main() {
    // crash catcher
    use std::panic;
    let prev = panic::take_hook();
    panic::set_hook(Box::new(move |info| {
        eprintln!("PANIC: {}", info);
        prev(info);
    }));

    let conn = match Connection::connect_to_env() {
        Ok(c) => c,
        Err(e) => { eprintln!("WAYLAND CONNECT: {:?}", e); std::process::exit(1); }
    };
    let (globals, eq) = match registry_queue_init::<State>(&conn) {
        Ok(g) => g,
        Err(e) => { eprintln!("REGISTRY INIT: {:?}", e); std::process::exit(1); }
    };
    let qh = eq.handle();

    let compositor: WlCompositor = globals.bind(&qh, 4..=6, ()).expect("wl_compositor");
    let shm: WlShm = globals.bind(&qh, 1..=1, ()).expect("wl_shm");
    let layer_shell: ZwlrLayerShellV1 = globals.bind(&qh, 1..=4, ()).expect("wlr-layer-shell");
    let _seat: WlSeat = globals.bind(&qh, 1..=9, ()).expect("wl_seat");

    let surface = compositor.create_surface(&qh, ());
    let layer = layer_shell.get_layer_surface(&surface, None, Layer::Top, "mist-shell".into(), &qh, ());
    layer.set_anchor(Anchor::Top | Anchor::Left | Anchor::Right);
    layer.set_exclusive_zone(36);
    layer.set_size(0, 36);
    surface.commit();
    let _ = conn.flush();

    let init_w = 1920i32;
    let (mmap, pool, stride, buf_size) = setup_shm(&shm, &qh, init_w, 36);
    let _ = conn.flush();

    let (ws_tx, ws_rx): (channel::Sender<WsList>, Channel<WsList>) = channel::channel();
    spawn_ipc(ws_tx);

    let (shell_tx, shell_rx): (channel::Sender<serde_json::Value>, Channel<serde_json::Value>) = channel::channel();
    shell_ipc::spawn_shell_ipc(shell_tx);

    let mut state = State {
        conn: conn.clone(), qh,
        compositor, shm, layer_shell,
        bar: BarSurface {
            surface, layer,
            pool: Some(pool), mmap: Some(mmap), stride, buf_size,
            bufs: Vec::new(), next_buf: 0,
            w: init_w, h: 36,
            configured: false, frame_pending: false, dirty: true,
        },
        launcher: LauncherSurface {
            surface: None, layer: None,
            pool: None, mmap: None, stride: 0, buf_size: 0,
            bufs: Vec::new(), next_buf: 0,
            w: 0, h: 0,
            configured: false, frame_pending: false, dirty: false,
            visible: false, apps: Vec::new(),
            matching: Vec::new(), is_action_mode: false, matching_actions: Vec::new(),
            selection: 0, query: String::new(), scroll_offset: 0, panel: None,
            actions: Vec::new(),
        },
        pointer: None, keyboard: None,
        current_surface: None,
        pointer_x: 0.0, pointer_y: 0.0,
        clock: String::new(), date: String::new(),
        workspaces: (1..=9).map(|i| (i.to_string(), Tag::default())).collect(),
        font: cosmic_text::FontSystem::new(), swash: cosmic_text::SwashCache::new(),
        xkb_ctx: None, xkb_state: None,
    };

    let mut loop_ = EventLoop::<State>::try_new().expect("event loop");
    let handle = loop_.handle();

    let wl_fd = conn.as_fd().as_raw_fd();
    let conn_ = Some(conn);
    let mut eq_ = Some(eq);
    handle.insert_source(Generic::new(unsafe { BorrowedFd::borrow_raw(wl_fd) }, Interest::READ, Mode::Level), move |_, _, state: &mut State| -> Result<_, std::io::Error> {
        let eq = eq_.as_mut().unwrap();
        let conn = conn_.as_ref().unwrap();
        if let Some(guard) = conn.prepare_read() && let Err(e) = guard.read() { eprintln!("read err: {:?}", e); std::process::exit(1) }
        if let Err(e) = eq.dispatch_pending(state) { eprintln!("dispatch err: {:?}", e); std::process::exit(1) }
        if let Err(e) = conn.flush() { eprintln!("flush err: {:?}", e); std::process::exit(1) }
        Ok(calloop::PostAction::Continue)
    }).expect("wl source");

    handle.insert_source(Timer::from_duration(Duration::from_secs(1)), move |_, _, state: &mut State| {
        let now = chrono::Local::now();
        state.clock = now.format("%H:%M").to_string();
        state.date = now.format("%a %b %-d").to_string();
        state.bar.dirty = true;
        if state.bar.configured && !state.bar.frame_pending {
            render_bar(state);
            state.commit_bar();
        }
        TimeoutAction::ToDuration(Duration::from_secs(1))
    }).expect("timer");

    eprintln!("[LOG] shell started, wayland connected");

    handle.insert_source(ws_rx, |event, _, state: &mut State| {
        if let calloop::channel::Event::Msg(list) = event && state.workspaces != list {
            state.workspaces = list;
            state.bar.dirty = true;
            if state.bar.configured {
                render_bar(state);
                state.commit_bar();
            }
        }
    }).expect("ws channel");

    handle.insert_source(shell_rx, |event, _, state: &mut State| {
        if let calloop::channel::Event::Msg(val) = event {
            match val.get("cmd").and_then(|c| c.as_str()) {
                Some("show") if val.get("target").and_then(|t| t.as_str()) == Some("launcher") => state.show_launcher(),
                Some("hide") if val.get("target").and_then(|t| t.as_str()) == Some("launcher") => state.hide_launcher(),
                Some("toggle") if val.get("target").and_then(|t| t.as_str()) == Some("launcher") => {
                    if state.launcher.visible { state.hide_launcher() } else { state.show_launcher() }
                }
                _ => {}
            }
        }
    }).expect("shell ipc rx");

    loop_.run(None, &mut state, |_| {}).expect("run");
}
