//! Persisted settings: one small file each under `$XDG_CONFIG_HOME/virtual-headset`
//! (falling back to `~/.config/virtual-headset`). `virtual-headset-ctl` writes the
//! same files, then restarts the service for the ones read only at start.
//!
//! | file        | contents                                                      |
//! | ----------- | ------------------------------------------------------------- |
//! | `source`    | the source to forward; absent = the system default            |
//! | `denoise`   | `on` = DeepFilterNet noise suppression; absent/other = off     |
//! | `strength`  | its attenuation limit in dB, 0 to `MAX_STRENGTH_DB`            |
//! | `keep-open` | `on` = keep the mic open between calls; absent/other = off     |

use std::env;
use std::io;
use std::path::PathBuf;

/// DeepFilterNet sounds the same past about 40 dB of attenuation as unlimited
/// (benchmarked for the macOS app), so strength tops out there, as "Max".
pub const MAX_STRENGTH_DB: f64 = 40.0;

pub fn config_dir() -> Option<PathBuf> {
    let base = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("virtual-headset"))
}

/// A setting's trimmed contents, if its file exists and isn't empty.
pub fn read(name: &str) -> Option<String> {
    let value = std::fs::read_to_string(config_dir()?.join(name)).ok()?;
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

pub fn write(name: &str, value: &str) -> io::Result<()> {
    let dir = config_dir().ok_or_else(|| io::Error::other("no config directory"))?;
    std::fs::create_dir_all(&dir)?;
    std::fs::write(dir.join(name), value)
}

#[derive(Debug, Clone, Copy)]
pub struct Settings {
    pub denoise: bool,
    pub strength_db: f64,
    pub keep_open: bool,
}

impl Settings {
    pub fn load() -> Self {
        Self {
            denoise: read("denoise").as_deref() == Some("on"),
            strength_db: read("strength")
                .and_then(|s| s.parse::<f64>().ok())
                .map_or(MAX_STRENGTH_DB, clamp_strength),
            keep_open: read("keep-open").as_deref() == Some("on"),
        }
    }
}

pub fn clamp_strength(db: f64) -> f64 {
    if db.is_finite() {
        db.clamp(0.0, MAX_STRENGTH_DB)
    } else {
        MAX_STRENGTH_DB
    }
}
