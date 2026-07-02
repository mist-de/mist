use std::io::BufRead;
use std::os::unix::net::UnixListener;

use calloop::channel;
use serde_json::Value;

pub fn spawn_shell_ipc(sender: channel::Sender<Value>) {
    std::thread::spawn(move || {
        let runtime_dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
        let path = format!("{}/mist-shell-ipc.sock", runtime_dir);
        let _ = std::fs::remove_file(&path);
        let listener = match UnixListener::bind(&path) {
            Ok(l) => l,
            Err(e) => {
                eprintln!("shell ipc bind: {}", e);
                return;
            }
        };
        for stream in listener.incoming().flatten() {
            let mut reader = std::io::BufReader::new(stream);
            let mut line = String::new();
            loop {
                line.clear();
                match reader.read_line(&mut line) {
                    Ok(0) => break,
                    Ok(_) => {
                        if let Ok(val) = serde_json::from_str::<Value>(line.trim())
                            && sender.send(val).is_err() {
                                return;
                            }
                    }
                    Err(_) => break,
                }
            }
        }
    });
}
