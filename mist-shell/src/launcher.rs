use std::path::Path;
use std::process::Command;

use cosmic_text::Color as CosmicColor;
use tiny_skia::{Color, FillRule, PixmapMut, Rect, Stroke, Transform};

use crate::render::{rounded_rect, skcolor, solid};
use crate::state::State;
use crate::text::render_text;

pub struct App {
    pub name: String,
    pub exec: String,
    pub comment: String,
    pub generic_name: String,
}

pub struct LauncherAction {
    pub name: &'static str,
    pub icon: &'static str,
    pub description: &'static str,
    pub command: &'static [&'static str],
}

pub const ACTIONS: &[LauncherAction] = &[
    LauncherAction { name: "Calculator", icon: "calculate", description: "Do simple math equations", command: &["autocomplete", "calc"] },
    LauncherAction { name: "Shutdown", icon: "power_settings_new", description: "Shutdown the system", command: &["poweroff"] },
    LauncherAction { name: "Reboot", icon: "cached", description: "Reboot the system", command: &["reboot"] },
    LauncherAction { name: "Logout", icon: "exit_to_app", description: "Log out of the current session", command: &["logout"] },
    LauncherAction { name: "Lock", icon: "lock", description: "Lock the current session", command: &["loginctl", "lock-session"] },
    LauncherAction { name: "Sleep", icon: "bedtime", description: "Suspend then hibernate", command: &["systemctl", "suspend-then-hibernate"] },
    LauncherAction { name: "Settings", icon: "settings", description: "Configure the shell", command: &["caelestia", "shell", "nexus", "open"] },
    LauncherAction { name: "Dark Mode", icon: "dark_mode", description: "Change the scheme to dark mode", command: &["setMode", "dark"] },
    LauncherAction { name: "Light Mode", icon: "light_mode", description: "Change the scheme to light mode", command: &["setMode", "light"] },
];

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
    apps
}

fn parse_desktop(path: &Path) -> Option<App> {
    let content = std::fs::read_to_string(path).ok()?;
    let mut name = None;
    let mut exec = None;
    let mut comment = String::new();
    let mut generic = String::new();
    let mut hide = false;
    let mut in_desktop = false;
    for line in content.lines() {
        let line = line.trim();
        if line == "[Desktop Entry]" { in_desktop = true; continue }
        if line.starts_with('[') { in_desktop = false; continue }
        if !in_desktop { continue }
        if let Some((key, val)) = line.split_once('=') {
            match key {
                "Name" => name = Some(val.to_string()),
                "Exec" => exec = Some(val.to_string()),
                "Comment" => comment = val.to_string(),
                "GenericName" => generic = val.to_string(),
                "NoDisplay" | "Hidden" => hide = val == "true",
                _ => {}
            }
        }
    }
    if hide { return None }
    let exec = exec?.replace("%f", "").replace("%F", "").replace("%u", "").replace("%U", "").replace("%c", "").replace("%k", "");
    Some(App { name: name?, exec: exec.trim().to_string(), comment, generic_name: generic })
}

pub fn fuzzy_match(query: &str, target: &str) -> Option<u32> {
    let q = query.as_bytes();
    let t = target.as_bytes();
    let mut qi = 0;
    let mut score: u32 = 0;
    let mut prev_match = false;
    for (ti, &tc) in t.iter().enumerate() {
        if qi < q.len() && tc.eq_ignore_ascii_case(&q[qi]) {
            qi += 1;
            if prev_match { score += 20; }
            else if ti == 0 { score += 30; }
            else {
                let prev = t[ti - 1];
                if prev == b' ' || prev == b'-' || prev == b'_' || prev == b'/' { score += 25; }
                else { score += 5; }
            }
            prev_match = true;
        } else {
            prev_match = false;
        }
    }
    if qi < q.len() { None } else { Some(std::cmp::min(score, 999)) }
}

pub fn launch_app(exec: &str) {
    let _ = Command::new("sh").args(["-c", exec]).spawn();
}

pub fn render_launcher(state: &mut State) -> (f32, f32, f32, f32) {
    let w = state.launcher.w.max(1) as u32;
    let h = state.launcher.h.max(1) as u32;
    let offset = (state.launcher.next_buf as i32 * state.launcher.buf_size) as usize;
    let slice = &mut state.launcher.mmap.as_mut().unwrap()[offset..offset + state.launcher.buf_size as usize];
    let mut pix = PixmapMut::from_bytes(slice, w, h).unwrap();

    pix.fill(Color::TRANSPARENT);

    let panel_w = (w as f32 * 0.5).clamp(300.0, 600.0);
    let panel_h = (h as f32 * 0.65).clamp(240.0, 560.0);
    let px = (w as f32 - panel_w) / 2.0;
    let py = (h as f32 - panel_h) / 2.0;
    let pad = 12.0;

    if let Some(p) = rounded_rect(px, py, panel_w, panel_h, 18.0) {
        pix.fill_path(&p, &solid(skcolor((0x1E, 0x1E, 0x2E, 0xC8))), FillRule::Winding, Transform::identity(), None);
    }
    if let Some(p) = rounded_rect(px, py, panel_w, panel_h, 18.0) {
        let mut bp = tiny_skia::Paint::default();
        bp.set_color(skcolor((0xCD, 0xD6, 0xF4, 0x12)));
        bp.anti_alias = true;
        let stroke = Stroke { width: 1.0, ..Default::default() };
        pix.stroke_path(&p, &bp, &stroke, Transform::identity(), None);
    }

    let search_x = px + pad;
    let search_w = panel_w - pad * 2.0;
    let search_h = 42.0;
    let search_y = py + panel_h - pad - search_h;

    if let Some(p) = rounded_rect(search_x, search_y, search_w, search_h, 21.0) {
        pix.fill_path(&p, &solid(skcolor((0x31, 0x32, 0x44, 0xE6))), FillRule::Winding, Transform::identity(), None);
    }

    render_text(&mut pix, &mut state.font, &mut state.swash, ">", search_x + 14.0, search_y + 12.0, 14.0, CosmicColor::rgba(0x6C, 0x70, 0x86, 0xFF));

    let display_text = if state.launcher.query.is_empty() {
        "  Search apps or type \">\" for commands..."
    } else {
        &state.launcher.query
    };
    let text_x = search_x + 14.0 + 10.0;
    render_text(&mut pix, &mut state.font, &mut state.swash, display_text, text_x, search_y + 12.0, 14.0,
        if state.launcher.query.is_empty() { CosmicColor::rgba(0x6C, 0x70, 0x86, 0xFF) } else { CosmicColor::rgba(0xCD, 0xD6, 0xF4, 0xFF) });

    let div_y = search_y - 10.0;
    if let Some(r) = Rect::from_xywh(search_x, div_y, search_w, 1.0) {
        pix.fill_rect(r, &solid(skcolor((0x36, 0x3A, 0x4F, 0xFF))), Transform::identity(), None);
    }

    let start_y = py + pad;
    let item_h = 38.0;
    let max_visible = ((div_y - 10.0 - start_y) / item_h).max(1.0) as usize;

    if state.launcher.is_action_mode {
        let start = state.launcher.scroll_offset.min(state.launcher.matching_actions.len().saturating_sub(1));
        let end = (start + max_visible).min(state.launcher.matching_actions.len());
        for (rel_i, &act_idx) in state.launcher.matching_actions[start..end].iter().enumerate() {
            let iy = start_y + rel_i as f32 * item_h;
            if start + rel_i == state.launcher.selection
                && let Some(p) = rounded_rect(px + 6.0, iy, panel_w - 12.0, item_h - 4.0, 8.0) {
                    pix.fill_path(&p, &solid(skcolor((0xCD, 0xD6, 0xF4, 0x12))), FillRule::Winding, Transform::identity(), None);
                }
            if let Some(act) = state.launcher.actions.get(act_idx) {
                render_text(&mut pix, &mut state.font, &mut state.swash, ">", px + 16.0, iy + 10.0, 14.0, CosmicColor::rgba(0x6C, 0x70, 0x86, 0xFF));
                render_text(&mut pix, &mut state.font, &mut state.swash, act.name, px + 36.0, iy + 10.0, 13.0, CosmicColor::rgba(0xCD, 0xD6, 0xF4, 0xFF));
                render_text(&mut pix, &mut state.font, &mut state.swash, act.description, px + 36.0, iy + 26.0, 11.0, CosmicColor::rgba(0x6C, 0x70, 0x86, 0xFF));
            }
        }
    } else {
        let start = state.launcher.scroll_offset.min(state.launcher.matching.len().saturating_sub(1));
        let end = (start + max_visible).min(state.launcher.matching.len());
        for (rel_i, &app_idx) in state.launcher.matching[start..end].iter().enumerate() {
            let app = &state.launcher.apps[app_idx];
            let iy = start_y + rel_i as f32 * item_h;
            if start + rel_i == state.launcher.selection
                && let Some(p) = rounded_rect(px + 6.0, iy, panel_w - 12.0, item_h - 4.0, 8.0) {
                    pix.fill_path(&p, &solid(skcolor((0xCD, 0xD6, 0xF4, 0x12))), FillRule::Winding, Transform::identity(), None);
                }

            let icon_size = 28.0;
            let icon_x = px + 12.0;
            let icon_y = iy + (item_h - icon_size) / 2.0;
            if let Some(p) = rounded_rect(icon_x, icon_y, icon_size, icon_size, 7.0) {
                pix.fill_path(&p, &solid(skcolor((0x45, 0x47, 0x5A, 0xFF))), FillRule::Winding, Transform::identity(), None);
            }
            let first = app.name.chars().next().map(|c| c.to_string()).unwrap_or_else(|| "?".into());
            render_text(&mut pix, &mut state.font, &mut state.swash, &first, icon_x + 9.0, icon_y + 7.0, 13.0, CosmicColor::rgba(0xA6, 0xAD, 0xC8, 0xFF));

            let label_x = icon_x + icon_size + 10.0;
            render_text(&mut pix, &mut state.font, &mut state.swash, &app.name, label_x, iy + 10.0, 13.0, CosmicColor::rgba(0xCD, 0xD6, 0xF4, 0xFF));
            let comment = if !app.comment.is_empty() { &app.comment } else { &app.generic_name };
            if !comment.is_empty() {
                render_text(&mut pix, &mut state.font, &mut state.swash, comment, label_x, iy + 26.0, 11.0, CosmicColor::rgba(0x6C, 0x70, 0x86, 0xFF));
            }
        }
    }

    (px, py, panel_w, panel_h)
}
