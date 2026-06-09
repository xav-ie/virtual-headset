use std::env;
use std::io;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

#[derive(Debug, Clone)]
pub struct AudioSource {
    pub name: String,
    pub description: String,
}

/// Path to the configured-source file written by `virtual-headset-ctl
/// set-source`. When present, it names the source to forward instead of the
/// system default. `$XDG_CONFIG_HOME/virtual-headset/source`, falling back to
/// `~/.config/virtual-headset/source`.
fn config_source_path() -> Option<PathBuf> {
    let base = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("virtual-headset").join("source"))
}

/// Read the configured source name, if a non-empty config file exists.
fn read_configured_source() -> Option<String> {
    let path = config_source_path()?;
    let name = std::fs::read_to_string(path).ok()?.trim().to_string();
    if name.is_empty() { None } else { Some(name) }
}

/// Look up a source's human-readable description; falls back to the name.
fn describe(source_name: &str) -> String {
    if let Ok(output) = Command::new("pactl").args(["list", "sources"]).output()
        && output.status.success()
    {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut found_source = false;
        for line in stdout.lines() {
            let line = line.trim();
            if line.starts_with("Name: ") && line.contains(source_name) {
                found_source = true;
            } else if found_source && line.starts_with("Description: ") {
                return line.strip_prefix("Description: ").unwrap().to_string();
            }
        }
    }
    source_name.to_string()
}

/// Whether a source with the given node name currently exists.
fn source_exists(name: &str) -> bool {
    if let Ok(output) = Command::new("pactl")
        .args(["list", "sources", "short"])
        .output()
        && output.status.success()
    {
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Short format is tab-separated: index\tname\tdriver\t...
        return stdout.lines().any(|l| l.split('\t').nth(1) == Some(name));
    }
    false
}

/// The source to forward: the configured one if set and present, otherwise the
/// system default. Keeps the original behaviour when no config file exists.
pub fn get_source() -> Result<AudioSource, io::Error> {
    if let Some(name) = read_configured_source()
        && source_exists(&name)
    {
        return Ok(AudioSource {
            description: describe(&name),
            name,
        });
    }
    get_default_source()
}

/// Get the default audio input source using pactl
pub fn get_default_source() -> Result<AudioSource, io::Error> {
    let output = Command::new("pactl")
        .args(["get-default-source"])
        .output()?;

    if !output.status.success() {
        return Err(io::Error::other("Failed to get default audio source"));
    }

    let source_name = String::from_utf8_lossy(&output.stdout).trim().to_string();

    Ok(AudioSource {
        description: describe(&source_name),
        name: source_name,
    })
}

/// Start pw-loopback to create virtual headset that forwards from real mic
pub fn start_loopback(source_name: &str) -> Result<Child, io::Error> {
    let capture_props = format!(
        "target.object=\"{}\" node.name=loopback_capture",
        source_name
    );

    Command::new("pw-loopback")
        .args([
            "--capture-props", &capture_props,
            "--playback-props", "media.class=Audio/Source node.name=Virtual_Headset_Mic node.description=Virtual_Headset_Microphone",
        ])
        .stdin(Stdio::null())
        .spawn()
}
