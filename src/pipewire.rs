use std::io;
use std::process::{Child, Command, Stdio};

#[derive(Debug, Clone)]
pub struct AudioSource {
    pub name: String,
    pub description: String,
}

/// List available audio input sources using pactl
pub fn list_sources() -> Result<Vec<AudioSource>, io::Error> {
    let output = Command::new("pactl").args(["list", "sources"]).output()?;

    if !output.status.success() {
        return Err(io::Error::other("Failed to list audio sources"));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut sources = Vec::new();
    let mut current_name = None;
    let mut current_description = None;

    for line in stdout.lines() {
        let line = line.trim();

        if line.starts_with("Name: ") {
            current_name = Some(line.strip_prefix("Name: ").unwrap().to_string());
        } else if line.starts_with("Description: ") {
            current_description = Some(line.strip_prefix("Description: ").unwrap().to_string());
        }

        // When we have both name and description, add the source
        if let (Some(name), Some(desc)) = (&current_name, &current_description) {
            // Skip monitor sources (they're outputs, not inputs)
            if !name.contains(".monitor") {
                sources.push(AudioSource {
                    name: name.clone(),
                    description: desc.clone(),
                });
            }
            current_name = None;
            current_description = None;
        }
    }

    Ok(sources)
}

/// Start pw-loopback to create virtual headset that forwards from real mic
pub fn start_loopback(source_name: &str) -> Result<Child, io::Error> {
    let capture_props = format!("target.object={} node.name=loopback_capture", source_name);

    Command::new("pw-loopback")
        .args([
            "--capture-props", &capture_props,
            "--playback-props", "media.class=Audio/Source node.name=Virtual_Headset_Mic node.description=Virtual_Headset_Microphone",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
}
