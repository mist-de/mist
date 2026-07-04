use std::fs;
use std::path::PathBuf;

pub const GOOGLE_SANS_FLEX: &[u8] = include_bytes!("../assets/fonts/GoogleSansFlex.ttf");
pub const MATERIAL_ICONS: &[u8] = include_bytes!("../assets/fonts/MaterialIcons-Regular.ttf");

/// Write embedded fonts to `$XDG_RUNTIME_DIR/mist-shell/fonts/` and register
/// them with FontConfig so Pango discovers them.
///
/// Returns the directory path on success.
pub fn install_embedded_fonts() -> Option<PathBuf> {
    let runtime = std::env::var("XDG_RUNTIME_DIR").ok()?;
    let dir = PathBuf::from(runtime).join("mist-shell").join("fonts");
    fs::create_dir_all(&dir).ok()?;

    let fonts: [(&str, &[u8]); 2] = [
        ("GoogleSansFlex.ttf", GOOGLE_SANS_FLEX),
        ("MaterialIcons-Regular.ttf", MATERIAL_ICONS),
    ];

    for (name, data) in &fonts {
        let path = dir.join(name);
        // Only write if the file doesn't exist OR content differs
        if fs::read(&path).ok().as_deref() != Some(data) {
            fs::write(&path, data).ok()?;
        }
    }

    let c_dir = std::ffi::CString::new(dir.to_string_lossy().as_bytes()).ok()?;
    unsafe {
        let config = FcConfigGetCurrent();
        if !config.is_null() {
            FcConfigAppFontAddDir(config, c_dir.as_ptr());
        }
    }

    Some(dir)
}

#[link(name = "fontconfig")]
unsafe extern "C" {
    fn FcConfigGetCurrent() -> *mut std::ffi::c_void;
    fn FcConfigAppFontAddDir(config: *mut std::ffi::c_void, dir: *const libc::c_char) -> libc::c_int;
}
