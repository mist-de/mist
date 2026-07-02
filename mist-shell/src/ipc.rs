use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use calloop::channel;

use crate::state::{Tag, WsList};

fn parse_ws(line: &str) -> Option<WsList> {
    let v: serde_json::Value = serde_json::from_str(line).ok()?;
    let monitors = v.get("monitors").or_else(|| v.get("all_tags")).and_then(|a| a.as_array())?;
    let monitor = monitors.iter().find(|m| m["active"].as_bool().unwrap_or(false)).or_else(|| monitors.first())?;
    let tags = monitor.get("tags")?.as_array()?;

    let active_override: Option<Vec<u64>> = monitor.get("active_tags")
        .and_then(|a| a.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_u64()).collect())
        .filter(|v: &Vec<u64>| !(v.is_empty() || v.len() == 1 && v[0] == 0));

    Some(tags.iter().map(|t| {
        let idx = t["index"].as_u64().unwrap_or(0);
        let active = match &active_override {
            Some(a) => a.contains(&idx),
            None => t["is_active"].as_bool().unwrap_or(false),
        };
        (idx.to_string(), Tag {
            active,
            urgent: t["is_urgent"].as_bool().unwrap_or(false),
            occupied: t["occupied"].as_bool().or_else(|| Some(t["client_count"].as_u64().unwrap_or(0) > 0)).unwrap_or(false),
        })
    }).collect())
}

pub fn spawn_ipc(sender: channel::Sender<WsList>) {
    std::thread::spawn(move || loop {
        let path = std::env::var("MANGO_INSTANCE_SIGNATURE").ok();
        let Some(ref path) = path else { std::thread::sleep(Duration::from_secs(2)); continue };
        let Ok(stream) = UnixStream::connect(path) else { std::thread::sleep(Duration::from_secs(2)); continue };
        let _ = (&stream).write_all(b"watch all-monitors\n");
        for line in BufReader::new(&stream).lines() {
            let Ok(line) = line else { break };
            if let Some(list) = parse_ws(&line) && sender.send(list).is_err() { return }
        }
        std::thread::sleep(Duration::from_millis(200));
    });
}
