use std::io;
use std::process::{Child, Command, Stdio};

use crate::settings::{self, Settings};

#[derive(Debug, Clone)]
pub struct AudioSource {
    pub name: String,
    pub description: String,
}

/// Node name of the virtual microphone we publish. Doubles as the unique
/// signature used to find and kill orphaned loopbacks (see
/// `kill_existing_loopbacks`), so the two always stay in sync.
const VIRTUAL_MIC_NODE: &str = "Virtual_Headset_Mic";

/// Node name of the virtual mic's capture side — the input that pulls from the
/// source. `set_capture_linked` links/unlinks this on (un)mute to gate
/// everything upstream, so it must match the capture `node.name` set in
/// `start_virtual_mic`, whichever process provides it.
const LOOPBACK_CAPTURE_NODE: &str = "loopback_capture";

/// The filter-chain config, written per start to `$XDG_RUNTIME_DIR`. Its path
/// is the denoiser process's signature, as the node name is pw-loopback's (see
/// `kill_existing_loopbacks`).
const FILTER_CHAIN_CONF: &str = "virtual-headset-filter-chain.conf";

/// The DeepFilterNet node inside the filter-chain, as named in its graph.
const DENOISER: &str = "dfn";

/// Node name of the level meter's passive recorder (see `start_meter`).
const METER_NODE: &str = "virtual_headset_meter";

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
    if let Some(name) = settings::read("source")
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

/// Kill any pre-existing virtual-headset children (the virtual mic, whether
/// `pw-loopback` or the denoising filter-chain, and the level meter) before we
/// spawn ours, making every (re)start idempotent: exactly one virtual mic,
/// never an accreting pile of duplicates.
///
/// Why this is needed: the daemon only kills the children IT spawned, and only
/// on a graceful exit (the tail of `main`). A previous instance terminated by
/// SIGKILL — or by SIGTERM if signal trapping is ever lost — skips that cleanup
/// and orphans them; the virtual mic keeps running and re-publishing
/// `Virtual_Headset_Mic`. Sweeping here heals that on the next start regardless
/// of how the old instance died.
///
/// Matches by a signature unique to each in its command line: the node name,
/// or the filter-chain's config path. `pkill` never
/// targets its own process, and we always run this *before* spawning, so it can
/// only ever hit stale instances — not the one we're about to create.
pub fn kill_existing_loopbacks() {
    for pattern in [
        format!("node.name={VIRTUAL_MIC_NODE}"),
        FILTER_CHAIN_CONF.to_string(),
        METER_NODE.to_string(),
    ] {
        let _ = Command::new("pkill").args(["-f", &pattern]).status();
    }
}

/// Start the virtual mic, `Virtual_Headset_Mic`, forwarding from the real one:
/// a plain `pw-loopback`, or with noise suppression a PipeWire filter-chain
/// running DeepFilterNet's LADSPA plugin (`ladspa`, its `.so`). Both publish the
/// same node names, so the mute gate and everything downstream can't tell them
/// apart, and no extra source shows up in apps' device lists.
///
/// The capture side is marked `node.passive=true` unless `keep_open`: then it
/// never *drives* the graph on its own, so the chain (the denoiser and the raw
/// mic) only runs while a real client captures `Virtual_Headset_Mic`, and
/// PipeWire suspends it to ~0% CPU otherwise; it wakes instantly when an app
/// (Zoom/Meet) opens the virtual mic.
pub fn start_virtual_mic(
    source_name: &str,
    settings: &Settings,
    ladspa: Option<&str>,
) -> Result<Child, io::Error> {
    let passive = !settings.keep_open;
    match ladspa.filter(|_| settings.denoise) {
        Some(plugin) => start_denoiser(source_name, plugin, settings.strength_db, passive),
        None => {
            let capture_props = format!(
                "target.object=\"{source_name}\" node.name={LOOPBACK_CAPTURE_NODE} node.passive={passive}"
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
    }
}

fn start_denoiser(
    source_name: &str,
    plugin: &str,
    strength_db: f64,
    passive: bool,
) -> Result<Child, io::Error> {
    let runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    let conf = std::path::Path::new(&runtime).join(FILTER_CHAIN_CONF);
    std::fs::write(
        &conf,
        format!(
            r#"context.spa-libs = {{
  audio.convert.* = audioconvert/libspa-audioconvert
  support.*       = support/libspa-support
}}
context.modules = [
  {{ name = libpipewire-module-rt flags = [ ifexists nofail ] }}
  {{ name = libpipewire-module-protocol-native }}
  {{ name = libpipewire-module-client-node }}
  {{ name = libpipewire-module-adapter }}
  {{ name = libpipewire-module-filter-chain
    args = {{
      node.description = "Virtual_Headset_Microphone"
      media.name       = "Virtual_Headset_Microphone"
      filter.graph = {{
        nodes = [
          {{
            type    = ladspa
            name    = {DENOISER}
            plugin  = "{plugin}"
            label   = deep_filter_mono
            control = {{ "Attenuation Limit (dB)" = {strength_db} }}
          }}
        ]
      }}
      audio.rate     = 48000
      audio.channels = 1
      audio.position = [ MONO ]
      capture.props = {{
        node.name     = "{LOOPBACK_CAPTURE_NODE}"
        node.passive  = {passive}
        target.object = "{source_name}"
      }}
      playback.props = {{
        node.name        = "{VIRTUAL_MIC_NODE}"
        node.description = "Virtual_Headset_Microphone"
        media.class      = Audio/Source
      }}
    }}
  }}
]
"#
        ),
    )?;
    // The filter-chain only loads plugins from LADSPA_PATH's directories,
    // even when given an absolute path.
    let plugin_dir = std::path::Path::new(plugin)
        .parent()
        .unwrap_or(std::path::Path::new("/"));
    Command::new("pipewire")
        .arg("-c")
        .arg(&conf)
        .env("LADSPA_PATH", plugin_dir)
        .stdin(Stdio::null())
        .spawn()
}

/// The id of the PipeWire node named `name`, from `pw-cli ls Node`.
fn node_id(name: &str) -> Option<u32> {
    let output = Command::new("pw-cli").args(["ls", "Node"]).output().ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let wanted = format!("node.name = \"{name}\"");
    let mut current = None;
    for line in stdout.lines().map(str::trim) {
        if let Some(rest) = line.strip_prefix("id ") {
            current = rest.split(',').next().and_then(|id| id.trim().parse().ok());
        } else if line == wanted {
            return current;
        }
    }
    None
}

/// Set the running denoiser's attenuation limit, live. While the chain is
/// suspended (muted, or nothing recording) PipeWire holds the change and
/// applies it as audio resumes. Returns whether PipeWire took it; false when
/// noise suppression is off (no filter-chain).
#[must_use]
pub fn set_strength(strength_db: f64) -> bool {
    // The control is a float.
    let params =
        format!("{{ params = [ \"{DENOISER}:Attenuation Limit (dB)\" {strength_db:.1} ] }}");
    // Filter-chain controls live on its nodes' Props; set both sides so it
    // doesn't matter which one carries them.
    [LOOPBACK_CAPTURE_NODE, VIRTUAL_MIC_NODE]
        .iter()
        .filter_map(|name| node_id(name))
        .map(|id| {
            Command::new("pw-cli")
                .args(["set-param", &id.to_string(), "Props", &params])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .is_ok_and(|s| s.success())
        })
        .fold(false, |any, ok| any || ok)
}

/// A passive recorder on `Virtual_Headset_Mic` for the level meter: mono f32
/// at `METER_RATE` on stdout. Passive, so it never opens the mic itself; it
/// only hears audio while something else records from the virtual mic.
pub const METER_RATE: usize = 16_000;

pub fn start_meter() -> Result<Child, io::Error> {
    Command::new("pw-record")
        .args([
            "--target",
            VIRTUAL_MIC_NODE,
            "-P",
            &format!("{{ node.passive = true node.name = {METER_NODE} }}"),
            "--format",
            "f32",
            "--rate",
            &METER_RATE.to_string(),
            "--channels",
            "1",
            "--raw",
            "-",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
}

/// Link or unlink the source into the virtual mic's capture — how mute gates
/// CPU.
///
/// While muted we cut the link: the raw mic (and any denoiser in front of it)
/// loses its only consumer and suspends to ~0%, while the virtual mic keeps
/// feeding silence into `Virtual_Headset_Mic`, so the device stays present for
/// the call app and unmuting relinks in ~16ms (the mic resumes from
/// idle/suspend, fast enough to be inaudible). While unmuted we (re)connect it
/// so audio flows.
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
