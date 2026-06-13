use std::env;
use std::io;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

#[derive(Debug, Clone)]
pub struct AudioSource {
    pub name: String,
    pub description: String,
}

/// Node name of the virtual microphone we publish. Doubles as the unique
/// signature used to find and kill orphaned loopbacks (see
/// `kill_existing_loopbacks`), so the two always stay in sync.
const VIRTUAL_MIC_NODE: &str = "Virtual_Headset_Mic";

/// Node name of the loopback's capture side — the input that pulls from the
/// (denoised) source. `set_capture_linked` links/unlinks this on (un)mute to
/// gate the RNNoise chain, so it must match the `node.name` set in
/// `start_loopback`.
const LOOPBACK_CAPTURE_NODE: &str = "loopback_capture";

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

/// Kill any pre-existing virtual-headset `pw-loopback` instances before we spawn
/// ours, making every (re)start idempotent: exactly one virtual mic, never an
/// accreting pile of duplicates.
///
/// Why this is needed: the daemon only kills the loopback IT spawned, and only
/// on a graceful exit (the tail of `main`). A previous instance terminated by
/// SIGKILL — or by SIGTERM if signal trapping is ever lost — skips that cleanup
/// and orphans its `pw-loopback` child, which keeps running and re-publishing
/// `Virtual_Headset_Mic`. Sweeping here heals that on the next start regardless
/// of how the old instance died.
///
/// Matches by our unique playback node name in the command line. `pkill` never
/// targets its own process, and we always run this *before* spawning, so it can
/// only ever hit stale instances — not the one we're about to create.
pub fn kill_existing_loopbacks() {
    let pattern = format!("node.name={VIRTUAL_MIC_NODE}");
    let _ = Command::new("pkill").args(["-f", &pattern]).status();
}

/// Start pw-loopback to create virtual headset that forwards from real mic.
///
/// The capture side is marked `node.passive=true` so it never *drives* the
/// graph on its own: the loopback (and everything upstream it pulls from — the
/// NoiseTorch RNNoise filter and the raw mic) only runs when a real client is
/// capturing `Virtual_Headset_Mic`. With no consumer, PipeWire suspends the
/// whole chain to ~0% CPU; it wakes instantly when an app (Zoom/Meet) opens the
/// virtual mic. Without this, the loopback pulls 24/7 and pins the denoiser
/// hot even while idle/muted.
pub fn start_loopback(source_name: &str) -> Result<Child, io::Error> {
    let capture_props = format!(
        "target.object=\"{source_name}\" node.name={LOOPBACK_CAPTURE_NODE} node.passive=true"
    );
    let playback_props = format!(
        "media.class=Audio/Source node.name={VIRTUAL_MIC_NODE} node.description=Virtual_Headset_Microphone"
    );

    Command::new("pw-loopback")
        .args([
            "--capture-props",
            &capture_props,
            "--playback-props",
            &playback_props,
        ])
        .stdin(Stdio::null())
        .spawn()
}

/// Link or unlink the (denoised) source into the loopback capture — how mute
/// gates CPU.
///
/// While muted we cut the link: the RNNoise filter and the raw mic lose their
/// only consumer and suspend to ~0%, while the loopback keeps feeding silence
/// into `Virtual_Headset_Mic`, so the device stays present for the call app and
/// unmuting relinks in ~16ms (the mic resumes from idle/suspend, fast enough to
/// be inaudible). While unmuted we (re)connect it so audio flows through the
/// denoiser.
///
/// Uses pw-link's node-name form so it covers every channel regardless of
/// mono/stereo.
///
/// Returns whether the gate actually ran. pw-link exits non-zero for benign
/// idempotent cases (connect when already linked → "File exists"; disconnect
/// when there's nothing to cut), so a non-zero exit still counts as applied —
/// only a spawn failure (pw-link missing from PATH, or PipeWire unreachable)
/// returns `false`, letting the caller keep its tracked state unchanged and
/// retry on the next reconcile instead of silently assuming success.
#[must_use]
pub fn set_capture_linked(source_name: &str, linked: bool) -> bool {
    let mut cmd = Command::new("pw-link");
    if !linked {
        cmd.arg("-d");
    }
    cmd.arg(source_name)
        .arg(LOOPBACK_CAPTURE_NODE)
        .stderr(Stdio::null())
        .status()
        .is_ok()
}

/// Whether the loopback capture currently has an inbound link (the source is
/// wired into it). Used at startup to wait for wireplumber's async auto-link
/// before asserting the muted-by-default cut — otherwise the cut could race
/// ahead of the auto-link and leave the chain wired while muted.
#[must_use]
pub fn capture_link_exists() -> bool {
    let Ok(output) = Command::new("pw-link").arg("-l").output() else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let lines: Vec<&str> = stdout.lines().collect();
    let header = format!("{LOOPBACK_CAPTURE_NODE}:");
    // The capture node's input port shows as a non-indented header line
    // "loopback_capture:input_<ch>"; an inbound link appears on the next line as
    // "  |<- <source>:<port>".
    lines.iter().enumerate().any(|(i, line)| {
        let t = line.trim_start();
        t.starts_with(&header)
            && !t.starts_with('|')
            && lines
                .get(i + 1)
                .is_some_and(|n| n.trim_start().starts_with("|<-"))
    })
}
