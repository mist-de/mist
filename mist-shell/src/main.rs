mod bar;
mod calc;
mod config;
mod compositor;
mod fonts;
mod launcher;
mod render;
mod shell_ipc;
mod state;
mod status;
mod tokens;
mod wl;

use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd};
use std::time::Duration;

use calloop::channel::Channel;
use calloop::generic::Generic;
use calloop::timer::{TimeoutAction, Timer};
use calloop::{EventLoop, Interest, Mode};
use wayland_client::globals::registry_queue_init;
use wayland_client::protocol::wl_compositor::WlCompositor;
use wayland_client::protocol::wl_output::WlOutput;
use wayland_client::protocol::wl_seat::WlSeat;
use wayland_client::protocol::wl_shm::WlShm;
use wayland_client::Connection;
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_shell_v1::{Layer, ZwlrLayerShellV1};
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_surface_v1::Anchor;

use crate::bar::render_bar;
use crate::state::{BarSurface, LauncherSurface, State, Tag};

type CmdTx = calloop::channel::Sender<(u64, serde_json::Value)>;
type CmdRx = Channel<(u64, serde_json::Value)>;

fn main() {
    if std::env::args().any(|a| a == "--help" || a == "-h") {
        eprintln!("Mist Shell v{}", env!("CARGO_PKG_VERSION"));
        eprintln!("Usage: mist-shell [--debug] [--help]");
        eprintln!("  --debug   Enable verbose debug logging");
        eprintln!("  --help    Show this help and exit");
        eprintln!();
        eprintln!("Environment:");
        eprintln!("  MIST_DEBUG=1          Enable debug logging (same as --debug)");
        eprintln!("  XDG_CONFIG_HOME/mist/config.toml  Configuration file");
        eprintln!("  WAYLAND_DISPLAY       Wayland compositor socket");
        std::process::exit(0);
    }
    if std::env::args().any(|a| a == "--debug") {
        unsafe { std::env::set_var("MIST_DEBUG", "1"); }
    }

    eprintln!("[mist] starting up...");
    eprintln!("[mist] version {}", env!("CARGO_PKG_VERSION"));
    eprintln!("[mist] debug={}", std::env::var("MIST_DEBUG").unwrap_or_default());

    crate::launcher::init_debug_flag();

    // Install embedded fonts
    if let Some(font_dir) = fonts::install_embedded_fonts() {
        eprintln!("[mist] fonts installed at {:?}", font_dir);
    } else {
        eprintln!("[mist] embedded font install skipped, using system fonts");
    }

    use std::panic;
    let prev = panic::take_hook();
    panic::set_hook(Box::new(move |info| {
        eprintln!("[mist] PANIC: {}", info);
        prev(info);
    }));

    let conn = match Connection::connect_to_env() {
        Ok(c) => c,
        Err(e) => { eprintln!("[mist] FATAL: Wayland connect: {:?}", e); std::process::exit(1); }
    };
    eprintln!("[mist] wayland connected (display={:?})", conn.backend().display_id());
    let (globals, mut eq) = match registry_queue_init::<State>(&conn) {
        Ok(g) => g,
        Err(e) => { eprintln!("REGISTRY INIT: {:?}", e); std::process::exit(1); }
    };
    let qh = eq.handle();

    let compositor: WlCompositor = globals.bind(&qh, 4..=6, ()).expect("wl_compositor");
    let layer_shell: ZwlrLayerShellV1 = globals.bind(&qh, 1..=4, ()).expect("wlr-layer-shell");
    let _seat: WlSeat = globals.bind(&qh, 1..=9, ()).expect("wl_seat");
    let _output: WlOutput = globals.bind(&qh, 1..=4, ()).expect("wl_output");
    let shm: WlShm = globals.bind(&qh, 1..=1, ()).expect("wl_shm");
    let cursor_shape_manager = globals.bind(&qh, 1..=1, ()).ok();

    let bar_w = crate::tokens::BAR_TOTAL_W as i32;
    let surface = compositor.create_surface(&qh, ());
    let layer = layer_shell.get_layer_surface(&surface, None, Layer::Top, "mist-shell".into(), &qh, ());
    layer.set_anchor(Anchor::Left | Anchor::Top | Anchor::Bottom);
    layer.set_exclusive_zone(bar_w);
    layer.set_size(bar_w as u32, 0);
    surface.commit();
    let _ = conn.flush();

    let init_w = bar_w;
    let init_h = 1080i32;

    let ct = compositor::detect();
    eprintln!("[mist] compositor: {:?}", ct);
    let ws_rx = compositor::spawn_workspace_poller(ct);

    let (cmd_tx, cmd_rx): (CmdTx, CmdRx) = calloop::channel::channel();
    let (resp_tx, resp_rx) = std::sync::mpsc::channel::<(u64, serde_json::Value)>();
    shell_ipc::spawn_shell_ipc(cmd_tx.clone(), Some((resp_tx, resp_rx)));

    let config = crate::config::load();
    let mut state = State {
        conn: conn.clone(), qh,
        compositor, layer_shell, shm,
        bar: BarSurface {
            surface, layer,
            w: init_w, h: init_h,
            configured: false, frame_pending: false, dirty: true,
            shm: None,
        },
        launcher: LauncherSurface {
            surface: None, layer: None,
            w: 0, h: 0,
            configured: false, frame_pending: false, dirty: false,
            shm: None,
            visible: false, apps: Vec::new(),
            view: crate::launcher::LauncherView::AppList, matching: Vec::new(), matching_actions: Vec::new(),
            selection: 0, query: String::new(), scroll_offset: 0, panel: None,
            actions: Vec::new(), start_time: std::time::Instant::now(),
            calc_result: None,
        },
        pointer: None, keyboard: None,
        pointer_x: 0.0, pointer_y: 0.0, pointer_serial: 0,
        cursor_shape_manager, cursor_shape_device: None, current_cursor: None,
        compositor_type: ct,
        clock: String::new(), date: String::new(),
        workspaces: (1..=9).map(|i| (i.to_string(), Tag::default())).collect(),
        xkb_ctx: None, xkb_state: None,
        config,
        status: crate::status::SystemStatus::default(),
        hovered_ws: None,
        scale: 1,
    };

    let _ = eq.roundtrip(&mut state);

    if !state.bar.configured {
        state.bar.configured = true;
        render_bar(&mut state);
        state.commit_bar();
    }

    let mut loop_ = EventLoop::<State>::try_new().expect("event loop");
    let handle = loop_.handle();

    let wl_fd = conn.as_fd().as_raw_fd();
    let dup_fd = unsafe { libc::dup(wl_fd) };
    if dup_fd < 0 { eprintln!("dup(wl_fd) failed"); std::process::exit(1); }
    let owned_fd = unsafe { OwnedFd::from_raw_fd(dup_fd) };
    let conn_ = Some(conn);
    let mut eq_ = Some(eq);
    static WL_DISPATCH_COUNT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    handle.insert_source(Generic::new(owned_fd, Interest::READ, Mode::Edge), move |_, _, state: &mut State| -> Result<_, std::io::Error> {
        let eq = eq_.as_mut().unwrap();
        let conn = conn_.as_ref().unwrap();
        let count = WL_DISPATCH_COUNT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        if count % 200 == 0 {
            eprintln!("[mist-wl] dispatch #{}", count);
        }
        // Drain all pending events: keep reading and dispatching until no more events
        loop {
            if let Some(guard) = conn.prepare_read() {
                if let Err(e) = guard.read() { eprintln!("read err: {:?}", e); std::process::exit(1) }
            }
            match eq.dispatch_pending(state) {
                Ok(0) => break,
                Ok(_) => continue,
                Err(e) => { eprintln!("dispatch err: {:?}", e); std::process::exit(1) }
            }
        }
        if let Err(e) = conn.flush() { eprintln!("flush err: {:?}", e); std::process::exit(1) }
        Ok(calloop::PostAction::Continue)
    }).expect("wl source");

    let mut last_status_poll = std::time::Instant::now();
    let status_poll_interval = Duration::from_secs(10);
    let parsed_tz = state.config.timezone.as_deref().and_then(|s| s.parse::<chrono_tz::Tz>().ok());
    let mut last_date = String::new();
    let mut last_clock = String::new();

    static TIMER_COUNT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    handle.insert_source(Timer::from_duration(Duration::from_secs(1)), move |_, _, state: &mut State| {
        let count = TIMER_COUNT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        if count % 30 == 0 {
            eprintln!("[mist-timer] tick #{} dirty={} configured={} fp={}", count, state.bar.dirty, state.bar.configured, state.bar.frame_pending);
        }
        let now = std::time::Instant::now();

        if now.duration_since(last_status_poll) >= status_poll_interval {
            last_status_poll = now;
            let new_status = crate::status::poll_status();
            if new_status != state.status {
                state.status = new_status;
                state.bar.dirty = true;
            }
        }

        let (d, c) = match &parsed_tz {
            Some(tz) => {
                let now = chrono::Utc::now().with_timezone(tz);
                (now.format("%a %b %-d").to_string(), now.format("%H:%M").to_string())
            }
            None => {
                let now = chrono::Local::now();
                (now.format("%a %b %-d").to_string(), now.format("%H:%M").to_string())
            }
        };
        if d != last_date || c != last_clock {
            last_date = d;
            last_clock = c;
            state.date = last_date.clone();
            state.clock = last_clock.clone();
            state.bar.dirty = true;
        }

        if state.bar.dirty && state.bar.configured && !state.bar.frame_pending {
            render_bar(state);
            state.commit_bar();
        }
        if state.launcher.dirty {
            state.flush_launcher_render();
        }
        TimeoutAction::ToDuration(Duration::from_secs(1))
    }).expect("timer");

    handle.insert_source(ws_rx, |event, _, state: &mut State| {
        if let calloop::channel::Event::Msg(list) = event && state.workspaces != list {
            state.workspaces = list;
            state.bar.dirty = true;
            if state.bar.configured && !state.bar.frame_pending {
                render_bar(state);
                state.commit_bar();
            }
        }
    }).expect("ws channel");

    handle.insert_source(cmd_rx, |event, _, state: &mut State| {
        if let calloop::channel::Event::Msg((_conn_id, val)) = event {
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
