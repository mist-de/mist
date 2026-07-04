use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

use crate::render::*;
use crate::state::State;
use crate::tokens::*;

static MIST_DEBUG: AtomicBool = AtomicBool::new(false);

pub fn init_debug_flag() {
    MIST_DEBUG.store(
        std::env::var("MIST_DEBUG").map(|v| v == "1").unwrap_or(false),
        Ordering::Relaxed,
    );
}

pub fn is_debug() -> bool {
    MIST_DEBUG.load(Ordering::Relaxed)
}

macro_rules! log_debug {
    ($($arg:tt)*) => {
        if MIST_DEBUG.load(Ordering::Relaxed) {
            eprintln!("[mist] {}", format_args!($($arg)*));
        }
    }
}

pub struct App {
    pub id: String,
    pub name: String,
    pub exec: String,
    pub icon: String,
    pub comment: String,
    pub generic_name: String,
    pub categories: Vec<String>,
    pub startup_wm_class: String,
    pub working_dir: String,
    pub terminal: bool,
}

pub const FIELD_DEFAULT: u8 = 0;
pub const FIELD_ID: u8 = 1;
pub const FIELD_EXEC: u8 = 2;
pub const FIELD_COMMENT: u8 = 3;
pub const FIELD_WM_CLASS: u8 = 4;
pub const FIELD_CATEGORIES: u8 = 5;

pub struct LauncherAction {
    pub name: &'static str,
    pub icon: &'static str,
    pub description: &'static str,
    pub command: &'static [&'static str],
}

pub const ACTIONS: &[LauncherAction] = &[
    LauncherAction { name: "Calculator", icon: "calculate", description: "Do simple math equations (type >calc ...)", command: &["autocomplete", "calc"] },
    LauncherAction { name: "Search by ID", icon: "fingerprint", description: "Search .desktop file names (type >i ...)", command: &["autocomplete", "i"] },
    LauncherAction { name: "Search by Category", icon: "category", description: "Search app categories (type >c ...)", command: &["autocomplete", "c"] },
    LauncherAction { name: "Search by Description", icon: "description", description: "Search app descriptions (type >d ...)", command: &["autocomplete", "d"] },
    LauncherAction { name: "Search by Exec", icon: "terminal", description: "Search app exec commands (type >e ...)", command: &["autocomplete", "e"] },
    LauncherAction { name: "Search by WM Class", icon: "widgets", description: "Search app window classes (type >w ...)", command: &["autocomplete", "w"] },
    LauncherAction { name: "Shutdown", icon: "power_settings_new", description: "Shutdown the system", command: &["poweroff"] },
    LauncherAction { name: "Reboot", icon: "cached", description: "Reboot the system", command: &["reboot"] },
    LauncherAction { name: "Logout", icon: "exit_to_app", description: "Log out of the current session", command: &["logout"] },
    LauncherAction { name: "Lock", icon: "lock", description: "Lock the current session", command: &["loginctl", "lock-session"] },
    LauncherAction { name: "Sleep", icon: "bedtime", description: "Suspend then hibernate", command: &["systemctl", "suspend-then-hibernate"] },
    LauncherAction { name: "Settings", icon: "settings", description: "Configure the shell", command: &["caelestia", "shell", "nexus", "open"] },
    LauncherAction { name: "Dark Mode", icon: "dark_mode", description: "Change the scheme to dark mode", command: &["setMode", "dark"] },
    LauncherAction { name: "Light Mode", icon: "light_mode", description: "Change the scheme to light mode", command: &["setMode", "light"] },
];

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum LauncherView {
    AppList,
    ActionList,
    CalcResult,
}

pub fn parse_search_prefix(query: &str) -> (u8, &str) {
    if let Some(stripped) = query.strip_prefix('>') {
        if stripped.starts_with("i ") { return (FIELD_ID, &stripped[2..].trim()) }
        if stripped.starts_with("c ") { return (FIELD_CATEGORIES, &stripped[2..].trim()) }
        if stripped.starts_with("d ") { return (FIELD_COMMENT, &stripped[2..].trim()) }
        if stripped.starts_with("e ") { return (FIELD_EXEC, &stripped[2..].trim()) }
        if stripped.starts_with("w ") { return (FIELD_WM_CLASS, &stripped[2..].trim()) }
    }
    (FIELD_DEFAULT, query)
}

fn normalize(c: char) -> char {
    match c {
        'à'|'á'|'â'|'ã'|'ä'|'å'|'ā'|'ă'|'ą'|'ǎ'|'ȁ'|'ȃ'|'ȧ'|'ạ'|'ả'|'ǻ' => 'a',
        'À'|'Á'|'Â'|'Ã'|'Ä'|'Å'|'Ā'|'Ă'|'Ą'|'Ǎ'|'Ȁ'|'Ȃ'|'Ȧ'|'Ạ'|'Ả'|'Ǻ' => 'A',
        'è'|'é'|'ê'|'ë'|'ē'|'ĕ'|'ė'|'ę'|'ě'|'ȅ'|'ȇ'|'ȩ'|'ẹ'|'ẻ'|'ẽ' => 'e',
        'È'|'É'|'Ê'|'Ë'|'Ē'|'Ĕ'|'Ė'|'Ę'|'Ě'|'Ȅ'|'Ȇ'|'Ȩ'|'Ẹ'|'Ẻ'|'Ẽ' => 'E',
        'ì'|'í'|'î'|'ï'|'ĩ'|'ī'|'ĭ'|'į'|'ǐ'|'ȉ'|'ȋ'|'ỉ'|'ị'|'ı' => 'i',
        'Ì'|'Í'|'Î'|'Ï'|'Ĩ'|'Ī'|'Ĭ'|'Į'|'Ǐ'|'Ȉ'|'Ȋ'|'Ỉ'|'Ị'|'İ' => 'I',
        'ò'|'ó'|'ô'|'õ'|'ö'|'ō'|'ŏ'|'ő'|'ơ'|'ǒ'|'ȍ'|'ȏ'|'ȫ'|'ȭ'|'ȯ'|'ȱ'|'ọ'|'ỏ' => 'o',
        'Ò'|'Ó'|'Ô'|'Õ'|'Ö'|'Ō'|'Ŏ'|'Ő'|'Ơ'|'Ǒ'|'Ȍ'|'Ȏ'|'Ȫ'|'Ȭ'|'Ȯ'|'Ȱ'|'Ọ'|'Ỏ' => 'O',
        'ù'|'ú'|'û'|'ü'|'ũ'|'ū'|'ŭ'|'ů'|'ű'|'ų'|'ư'|'ǔ'|'ȕ'|'ȗ'|'ụ'|'ủ' => 'u',
        'Ù'|'Ú'|'Û'|'Ü'|'Ũ'|'Ū'|'Ŭ'|'Ů'|'Ű'|'Ų'|'Ư'|'Ǔ'|'Ȕ'|'Ȗ'|'Ụ'|'Ủ' => 'U',
        'ñ'|'ń'|'ņ'|'ň'|'ŋ'|'ǹ'|'ṅ'|'ṇ'|'ṉ' => 'n',
        'Ñ'|'Ń'|'Ņ'|'Ň'|'Ŋ'|'Ǹ'|'Ṅ'|'Ṇ'|'Ṉ' => 'N',
        'ç'|'ć'|'ĉ'|'ċ'|'č'|'ḉ' => 'c',
        'Ç'|'Ć'|'Ĉ'|'Ċ'|'Č'|'Ḉ' => 'C',
        'ğ'|'ģ'|'ĝ'|'ǧ'|'ǵ' => 'g',
        'Ğ'|'Ģ'|'Ĝ'|'Ǧ'|'Ǵ' => 'G',
        'ş'|'ś'|'ŝ'|'š'|'ṡ'|'ṣ' => 's',
        'Ş'|'Ś'|'Ŝ'|'Š'|'Ṡ'|'Ṣ' => 'S',
        'ţ'|'ť'|'ŧ'|'ṭ'|'ṫ'|'ṱ'|'ṯ' => 't',
        'Ţ'|'Ť'|'Ŧ'|'Ṭ'|'Ṫ'|'Ṱ'|'Ṯ' => 'T',
        'ð' => 'd', 'Ð' => 'D',
        'þ' => 't', 'Þ' => 'T',
        'ß' => 's',
        'ł' => 'l', 'Ł' => 'L',
        'ÿ'|'ŷ'|'ý'|'ȳ'|'ỳ'|'ỵ'|'ỷ'|'ỹ' => 'y',
        'Ÿ'|'Ŷ'|'Ý'|'Ȳ'|'Ỳ'|'Ỵ'|'Ỷ'|'Ỹ' => 'Y',
        'ž'|'ź'|'ż' => 'z',
        'Ž'|'Ź'|'Ż' => 'Z',
        'æ' => 'a', 'Æ' => 'A',
        'œ' => 'o', 'Œ' => 'O',
        'đ' => 'd', 'Đ' => 'D',
        'ħ' => 'h', 'Ħ' => 'H',
        'ĳ' => 'i', 'Ĳ' => 'I',
        'ĸ' => 'k',
        _ => c,
    }
}

fn char_class(c: char) -> u8 {
    if c.is_ascii_lowercase() { 1 }
    else if c.is_ascii_uppercase() { 2 }
    else if c.is_ascii_digit() { 4 }
    else if c.is_alphabetic() { 3 }
    else { 0 }
}

fn bonus(prev_class: u8, curr_class: u8) -> i32 {
    if prev_class == 0 && curr_class != 0 { return 8 }
    if (prev_class == 1 && curr_class == 2) || (prev_class != 4 && curr_class == 4) { return 7 }
    if curr_class == 0 { return 8 }
    0
}

pub fn fuzzy_match(query: &str, target: &str) -> Option<u32> {
    let q: Vec<char> = query.chars().collect();
    if q.is_empty() { return Some(0) }

    let mut qi = 0;
    let mut score: i32 = 0;
    let mut gap = 0u32;
    let mut prev_class: u8 = char_class(target.chars().next().unwrap_or('\0'));
    let mut in_first_match = true;

    for (_ti, tc) in target.chars().enumerate() {
        if qi < q.len() {
            let qc = q[qi];
            let nc = normalize(tc).to_ascii_lowercase();
            let nq = normalize(qc).to_ascii_lowercase();
            if nc == nq || tc.eq_ignore_ascii_case(&qc) {
                qi += 1;
                let curr_class = char_class(tc);
                let b = bonus(prev_class, curr_class);

                if in_first_match {
                    score += 16 + b * 2;
                    in_first_match = false;
                } else if gap == 0 {
                    score += 16 + 4;
                } else {
                    score += -3 - ((gap - 1) as i32).max(0);
                    score += 16 + b;
                }
                gap = 0;
                prev_class = curr_class;
                continue;
            }
        }
        if !in_first_match {
            gap = gap.saturating_add(1);
        }
        prev_class = char_class(tc);
    }

    if qi < q.len() {
        None
    } else {
        Some(score.max(0) as u32)
    }
}

pub fn fuzzy_match_on(query: &str, target: &str) -> Option<u32> {
    if target.is_empty() { return None }
    fuzzy_match(query, target)
}

pub fn fuzzy_match_app(query: &str, app: &App, field: u8) -> Option<u32> {
    match field {
        FIELD_DEFAULT => {
            let mut best = fuzzy_match_on(query, &app.name);
            if !app.generic_name.is_empty() {
                best = take_better(best, fuzzy_match_on(query, &app.generic_name));
            }
            best = take_better(best, fuzzy_match_on(query, &app.exec));
            best = take_better(best, fuzzy_match_on(query, &app.comment));
            if !app.id.is_empty() {
                best = take_better(best, fuzzy_match_on(query, &app.id));
            }
            best
        }
        FIELD_ID => fuzzy_match_on(query, &app.id),
        FIELD_EXEC => fuzzy_match_on(query, &app.exec),
        FIELD_COMMENT => fuzzy_match_on(query, &app.comment),
        FIELD_WM_CLASS => fuzzy_match_on(query, &app.startup_wm_class),
        FIELD_CATEGORIES => {
            for cat in &app.categories {
                if let Some(s) = fuzzy_match_on(query, cat) {
                    return Some(s);
                }
            }
            None
        }
        _ => fuzzy_match_on(query, &app.name),
    }
}

fn take_better(a: Option<u32>, b: Option<u32>) -> Option<u32> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (Some(a), None) => Some(a),
        (None, Some(b)) => Some(b),
        (None, None) => None,
    }
}

pub fn scan_apps() -> Vec<App> {
    let mut apps = Vec::new();
    let home = std::env::var("HOME").unwrap_or_default();
    let local = format!("{}/.local/share/applications", home);
    let dirs = [
        Path::new("/usr/share/applications"),
        Path::new("/usr/local/share/applications"),
        Path::new(&local),
    ];
    for dir in dirs {
        if !dir.exists() { continue }
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) == Some("desktop")
                    && let Some(app) = parse_desktop(&path) {
                    apps.push(app);
                }
            }
        }
    }
    apps.sort_by_key(|a| a.name.to_lowercase());
    eprintln!("[mist] scanned {} desktop entries", apps.len());
    apps
}

fn strip_field_codes(exec: &str) -> String {
    let mut result = String::with_capacity(exec.len());
    let bytes = exec.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 1 < bytes.len() {
            match bytes[i + 1] {
                b'f' | b'F' | b'u' | b'U' | b'd' | b'D' | b'n' | b'N' | b'i' | b'c' | b'k' => {
                    i += 1;
                    if i + 1 < bytes.len() && bytes[i + 1] == b' ' { i += 1; }
                    i += 1;
                    continue;
                }
                b'%' => { result.push('%'); i += 2; continue; }
                _ => {}
            }
        }
        result.push(bytes[i] as char);
        i += 1;
    }
    result.trim().to_string()
}

fn tokenize(cmd: &str) -> Vec<String> {
    let mut args = Vec::new();
    let mut current = String::new();
    let mut in_single = false;
    let mut in_double = false;
    for c in cmd.chars() {
        match c {
            '\'' if !in_double => { in_single = !in_single; }
            '"' if !in_single => { in_double = !in_double; }
            ' ' if !in_single && !in_double => {
                if !current.is_empty() {
                    args.push(std::mem::take(&mut current));
                }
            }
            _ => current.push(c),
        }
    }
    if !current.is_empty() { args.push(current); }
    args
}

fn parse_desktop(path: &Path) -> Option<App> {
    let content = std::fs::read_to_string(path).ok()?;
    let id = path.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
    let mut name: Option<String> = None;
    let mut exec: Option<String> = None;
    let mut icon = String::new();
    let mut comment = String::new();
    let mut generic = String::new();
    let mut categories = Vec::new();
    let mut startup_wm_class = String::new();
    let mut working_dir = String::new();
    let mut hide = false;
    let mut terminal = false;
    let mut in_desktop = false;
    for line in content.lines() {
        let line = line.trim();
        if line == "[Desktop Entry]" { in_desktop = true; continue }
        if line.starts_with('[') { in_desktop = false; continue }
        if !in_desktop { continue }
        let Some((key, val)) = line.split_once('=') else { continue };
        match key {
            _ if key.starts_with("Name[") || key == "Name" => { name = name.or(Some(val.to_string())); }
            _ if key.starts_with("GenericName[") || key == "GenericName" => { if generic.is_empty() { generic = val.to_string(); } }
            _ if key.starts_with("Comment[") || key == "Comment" => { if comment.is_empty() { comment = val.to_string(); } }
            "Exec" => { exec = Some(val.to_string()); }
            "Icon" => { icon = val.to_string(); }
            "Categories" => { categories = val.split(';').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect(); }
            "StartupWMClass" => { startup_wm_class = val.to_string(); }
            "Path" => { working_dir = val.to_string(); }
            "Terminal" => { terminal = val == "true"; }
            "NoDisplay" | "Hidden" => { hide = val == "true"; }
            _ => {}
        }
    }
    if hide { return None }
    let exec = exec?;
    let exec = strip_field_codes(&exec);
    Some(App {
        id, name: name?, exec, icon, comment,
        generic_name: generic, categories, startup_wm_class, working_dir, terminal,
    })
}

fn launch_exec(exec: &str, activation_token: Option<&str>, working_dir: Option<&str>) {
    let args = tokenize(exec);
    if args.is_empty() { return }
    let mut cmd = Command::new(&args[0]);
    cmd.args(&args[1..])
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .env("XDG_SESSION_TYPE", "wayland");
    if let Some(dir) = working_dir { if !dir.is_empty() { cmd.current_dir(dir); } }
    if let Some(token) = activation_token { cmd.env("XDG_ACTIVATION_TOKEN", token); }
    match cmd.spawn() {
        Ok(child) => eprintln!("[mist] launched: pid={} cmd=\"{}\"", child.id(), exec),
        Err(e) => eprintln!("[mist] launch failed: {} cmd=\"{}\"", e, exec),
    }
}

pub fn launch_app(exec: &str) { launch_exec(exec, None, None); }

pub fn launch_desktop_app(app: &App, activation_token: Option<&str>) {
    if app.terminal {
        let term = std::env::var("TERMINAL").unwrap_or_else(|_| "foot".to_string());
        launch_exec(&format!("{} -e {}", term, app.exec), None, None);
    } else {
        launch_exec(&app.exec, activation_token, Some(&app.working_dir));
    }
}

pub struct PanelLayout {
    pub px: f32, pub py: f32,
    pub pw: f32, pub ph: f32,
    pub pad: f32,
    pub search_h: f32,
    pub item_h: f32,
    pub start_y: f32,
    pub search_y: f32,
    pub div_y: f32,
    pub max_visible: usize,
}

pub fn compute_panel(w: f32, h: f32, _anim_scale: f32) -> PanelLayout {
    let pw = (w * 0.5).clamp(300.0, 600.0);
    let ph = (h * 0.65).clamp(240.0, 560.0);
    let px = (w - pw) / 2.0;
    let py = (h - ph) / 2.0;
    let pad = 12.0;
    let search_h = 42.0;
    let search_y = py + ph - pad - search_h;
    let div_y = search_y - 10.0;
    let start_y = py + pad;
    let item_h = 38.0;
    let max_visible = ((div_y - 10.0 - start_y) / item_h).max(1.0) as usize;
    PanelLayout { px, py, pw, ph, pad, search_h, item_h, start_y, search_y, div_y, max_visible }
}

/// Cairo+Pango rendering for the launcher overlay.
/// Returns (empty vec for compatibility, panel rect for pointer hit-test).
pub fn render_launcher(state: &mut State) -> (Vec<u8>, (f32, f32, f32, f32)) {
    let Some(ref mut shm_triple) = state.launcher.shm else { return (Vec::new(), (0.0, 0.0, 0.0, 0.0)) };
    let w = state.launcher.w.max(1) as f64;
    let h = state.launcher.h.max(1) as f64;

    let lay = compute_panel(w as f32, h as f32, 1.0);

    let slot = shm_triple.next_slot();
    let width = slot.width;
    let height = slot.height;
    let stride = slot.stride;
    let data = unsafe { slot.data_mut() };
    data.fill(0);
    let surface = unsafe {
        cairo::ImageSurface::create_for_data_unsafe(
            data.as_mut_ptr(),
            cairo::Format::ARgb32,
            width,
            height,
            stride,
        ).unwrap()
    };
    let _ = data;
    let cr = cairo::Context::new(&surface).unwrap();

    cr.set_operator(cairo::Operator::Clear);
    let _ = cr.paint();
    cr.set_operator(cairo::Operator::Over);

    // Dimmed background overlay
    fill_rounded_rect(&cr, lay.px as f64, lay.py as f64, lay.pw as f64, lay.ph as f64, RADIUS_LG as f64, (0x26, 0x1D, 0x20, 0xC8));
    stroke_rounded_rect(&cr, lay.px as f64, lay.py as f64, lay.pw as f64, lay.ph as f64, RADIUS_LG as f64, 1.5, (0x51, 0x43, 0x47, 0x12));

    // Search bar background
    let search_x = lay.px + lay.pad;
    let search_w = lay.pw - lay.pad * 2.0;
    fill_rounded_rect(&cr, search_x as f64, lay.search_y as f64, search_w as f64, lay.search_h as f64, RADIUS_FULL as f64, (0x31, 0x28, 0x2A, 0xE6));

    // Search prompt and text
    render_launcher_text(&cr, ">", (search_x + 14.0) as f64, (lay.search_y + 12.0) as f64, FONT_NORMAL as f64, (0xD5, 0xC2, 0xC6, 0xFF));

    let text_x = search_x + 14.0 + 10.0;
    if state.launcher.query.is_empty() {
        render_launcher_text(&cr, "  Search apps or type \">\" for commands...",
            text_x as f64, (lay.search_y + 12.0) as f64, FONT_NORMAL as f64, (0xD5, 0xC2, 0xC6, 0xFF));
    } else {
        let cursor_visible = (state.launcher.start_time.elapsed().as_millis() / 500).is_multiple_of(2);
        let display = if cursor_visible {
            let mut s = state.launcher.query.clone();
            s.push('|');
            s
        } else {
            state.launcher.query.clone()
        };
        render_launcher_text(&cr, &display, text_x as f64, (lay.search_y + 12.0) as f64, FONT_NORMAL as f64, (0xEF, 0xDF, 0xE2, 0xFF));
    }

    // Divider
    fill_rect(&cr, (lay.px + lay.pad) as f64, lay.div_y as f64, (lay.pw - lay.pad * 2.0) as f64, 1.0, (0x36, 0x3A, 0x4F, 0xFF));

    state.launcher.dirty = false;

    match state.launcher.view {
        LauncherView::CalcResult => {
            if let Some(ref calc_res) = state.launcher.calc_result {
                let iy = lay.start_y as f64;
                if state.launcher.selection == 0 {
                    fill_rounded_rect(&cr, (lay.px + 6.0) as f64, iy, (lay.pw - 12.0) as f64, (lay.item_h - 4.0) as f64, RADIUS_SM as f64, (0x7A, 0xA2, 0xF7, 0x33));
                }
                render_launcher_text(&cr, "\u{f8c9}", (lay.px + 16.0) as f64, iy + 10.0, FONT_NORMAL as f64, (0x7A, 0xA2, 0xF7, 0xFF));
                render_launcher_text(&cr, " = ", (lay.px + 36.0) as f64, iy + 10.0, FONT_SMALLER as f64, (0xEF, 0xDF, 0xE2, 0xFF));
                render_launcher_text(&cr, &state.launcher.query, (lay.px + 56.0) as f64, iy + 10.0, FONT_SMALLER as f64, (0x6C, 0x70, 0x86, 0xFF));
                render_launcher_text(&cr, calc_res, (lay.px + 56.0) as f64, iy + 26.0, FONT_SMALL as f64, (0xA6, 0xDA, 0x95, 0xFF));

                let start = state.launcher.scroll_offset.min(state.launcher.matching_actions.len().saturating_sub(1));
                let end = (start + lay.max_visible.saturating_sub(1)).min(state.launcher.matching_actions.len());
                for (rel_i, &act_idx) in state.launcher.matching_actions[start..end].iter().enumerate() {
                    let iy2 = lay.start_y as f64 + (rel_i + 1) as f64 * lay.item_h as f64;
                    if start + rel_i + 1 == state.launcher.selection {
                        fill_rounded_rect(&cr, (lay.px + 6.0) as f64, iy2, (lay.pw - 12.0) as f64, (lay.item_h - 4.0) as f64, RADIUS_SM as f64, (0xEF, 0xDF, 0xE2, 0x1A));
                    }
                    if let Some(act) = state.launcher.actions.get(act_idx) {
                        render_launcher_text(&cr, ">", (lay.px + 16.0) as f64, iy2 + 10.0, FONT_NORMAL as f64, (0xD5, 0xC2, 0xC6, 0xFF));
                        render_launcher_text(&cr, act.name, (lay.px + 36.0) as f64, iy2 + 10.0, FONT_SMALLER as f64, (0xEF, 0xDF, 0xE2, 0xFF));
                        render_launcher_text(&cr, act.description, (lay.px + 36.0) as f64, iy2 + 26.0, FONT_SMALL as f64, (0xD5, 0xC2, 0xC6, 0xFF));
                    }
                }
            }
        }
        LauncherView::ActionList => {
            let start = state.launcher.scroll_offset.min(state.launcher.matching_actions.len().saturating_sub(1));
            let end = (start + lay.max_visible).min(state.launcher.matching_actions.len());
            for (rel_i, &act_idx) in state.launcher.matching_actions[start..end].iter().enumerate() {
                let iy = lay.start_y as f64 + rel_i as f64 * lay.item_h as f64;
                if start + rel_i == state.launcher.selection {
                    fill_rounded_rect(&cr, (lay.px + 6.0) as f64, iy, (lay.pw - 12.0) as f64, (lay.item_h - 4.0) as f64, RADIUS_SM as f64, (0xEF, 0xDF, 0xE2, 0x1A));
                }
                if let Some(act) = state.launcher.actions.get(act_idx) {
                    render_launcher_text(&cr, ">", (lay.px + 16.0) as f64, iy + 10.0, FONT_NORMAL as f64, (0xD5, 0xC2, 0xC6, 0xFF));
                    render_launcher_text(&cr, act.name, (lay.px + 36.0) as f64, iy + 10.0, FONT_SMALLER as f64, (0xEF, 0xDF, 0xE2, 0xFF));
                    render_launcher_text(&cr, act.description, (lay.px + 36.0) as f64, iy + 26.0, FONT_SMALL as f64, (0xD5, 0xC2, 0xC6, 0xFF));
                }
            }
        }
        LauncherView::AppList => {
            let start = state.launcher.scroll_offset.min(state.launcher.matching.len().saturating_sub(1));
            let end = (start + lay.max_visible).min(state.launcher.matching.len());
            for (rel_i, &app_idx) in state.launcher.matching[start..end].iter().enumerate() {
                let app = &state.launcher.apps[app_idx];
                let iy = lay.start_y as f64 + rel_i as f64 * lay.item_h as f64;
                if start + rel_i == state.launcher.selection {
                    fill_rounded_rect(&cr, (lay.px + 6.0) as f64, iy, (lay.pw - 12.0) as f64, (lay.item_h - 4.0) as f64, RADIUS_SM as f64, (0xEF, 0xDF, 0xE2, 0x1A));
                }

                // Icon placeholder
                let icon_size = 28.0;
                let icon_x = lay.px + 12.0;
                let icon_y = iy + (lay.item_h - icon_size) as f64 / 2.0;
                fill_rounded_rect(&cr, icon_x as f64, icon_y, icon_size as f64, icon_size as f64, 7.0, (0x45, 0x47, 0x5A, 0xFF));
                let first = app.name.chars().next().unwrap_or('?');
                render_launcher_text(&cr, &first.to_string(), icon_x as f64 + 9.0, icon_y + 7.0, FONT_SMALLER as f64, (0xA6, 0xAD, 0xC8, 0xFF));

                let label_x = icon_x + icon_size + 10.0;
                render_launcher_text(&cr, &app.name, label_x as f64, iy + 10.0, FONT_SMALLER as f64, (0xEF, 0xDF, 0xE2, 0xFF));
                let comment = if !app.comment.is_empty() { &app.comment } else { &app.generic_name };
                if !comment.is_empty() {
                    render_launcher_text(&cr, comment, label_x as f64, iy + 26.0, FONT_SMALL as f64, (0xD5, 0xC2, 0xC6, 0xFF));
                }
            }
        }
    }

    surface.flush();

    (Vec::new(), (lay.px, lay.py, lay.pw, lay.ph))
}

fn render_launcher_text(cr: &cairo::Context, text: &str, x: f64, y: f64, size: f64, col: (u8, u8, u8, u8)) {
    let layout = pangocairo::functions::create_layout(cr);
    layout.set_text(text);
    let desc = pango::FontDescription::from_string(&format!("GoogleSansFlex {}", size as i32));
    layout.set_font_description(Some(&desc));
    set_source_rgba(cr, col);
    cr.move_to(x, y);
    pangocairo::functions::show_layout(cr, &layout);
}
