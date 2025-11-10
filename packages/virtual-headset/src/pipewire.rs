use std::io;
use std::process::{Child, Command, Stdio};

#[derive(Debug, Clone)]
pub struct AudioSource {
    pub name: String,
    pub description: String,
}

/// Get the default audio input source using pactl
pub fn get_default_source() -> Result<AudioSource, io::Error> {
    // Get the default source name
    let output = Command::new("pactl")
        .args(["get-default-source"])
        .output()?;

    if !output.status.success() {
        return Err(io::Error::other("Failed to get default audio source"));
    }

    let source_name = String::from_utf8_lossy(&output.stdout).trim().to_string();

    // Get the description for this source
    let output = Command::new("pactl").args(["list", "sources"]).output()?;

    if !output.status.success() {
        return Err(io::Error::other("Failed to list audio sources"));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut found_source = false;
    let mut description = None;

    for line in stdout.lines() {
        let line = line.trim();

        if line.starts_with("Name: ") && line.contains(&source_name) {
            found_source = true;
        } else if found_source && line.starts_with("Description: ") {
            description = Some(line.strip_prefix("Description: ").unwrap().to_string());
            break;
        }
    }

    let description = description.unwrap_or_else(|| source_name.clone());

    Ok(AudioSource {
        name: source_name,
        description,
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
