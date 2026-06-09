//! Firefox/Chromium native-messaging host that bridges the virtual-headset
//! D-Bus interface to a browser extension.
//!
//! Browsers (Firefox in particular) do not expose USB HID telephony devices to
//! web pages, so the Zoom/Meet *web* apps never see the virtual headset's mute
//! button. This host closes that gap: it speaks the browser native-messaging
//! protocol on stdio and relays mute state to/from the running daemon over the
//! session D-Bus (`com.github.virtual_headset`).
//!
//! Protocol (both directions are length-prefixed JSON, per the WebExtension
//! native-messaging spec: a 4-byte native-endian u32 length followed by UTF-8
//! JSON):
//!
//! Extension -> host:
//!   {"type":"setMute","muted":true}   set the headset mute state
//!   {"type":"toggle"}                  toggle the headset mute state
//!   {"type":"query"}                   request the current state
//!   {"type":"listSources"}             request the forwardable source list
//!   {"type":"setSource","name":string} forward a specific source
//!   {"type":"clearSource"}             follow the system default source
//!   {"type":"restartService"}          restart the virtual-headset service
//!   {"type":"ping"}                    liveness check
//!
//! Host -> extension:
//!   {"type":"state","muted":bool}      current/!changed mute state
//!   {"type":"sources","sources":[...]} forwardable sources (from ctl)
//!   {"type":"pong"}
//!   {"type":"error","message":string}
//!
//! Source listing/selection shells out to `virtual-headset-ctl` (wrapped onto
//! PATH by the package), the same CLI the bar and AGS panel use.

use std::io::{self, Read, Write};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use zbus::blocking::Connection;

/// Client-side proxy for the daemon's mute interface (see
/// `src/dbus_interface.rs` for the service side).
#[zbus::proxy(
    interface = "com.github.virtual_headset.Mute",
    default_service = "com.github.virtual_headset",
    default_path = "/com/github/virtual_headset"
)]
trait VirtualHeadset {
    fn is_muted(&self) -> zbus::Result<bool>;
    fn mute(&self) -> zbus::Result<()>;
    fn unmute(&self) -> zbus::Result<()>;
    fn toggle(&self) -> zbus::Result<()>;

    #[zbus(signal)]
    fn mute_changed(&self, muted: bool) -> zbus::Result<()>;
}

/// Messages received from the browser extension.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum InMessage {
    SetMute { muted: bool },
    Toggle,
    Query,
    ListSources,
    SetSource { name: String },
    ClearSource,
    RestartService,
    Ping,
}

/// Messages sent to the browser extension.
#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum OutMessage {
    State {
        muted: bool,
    },
    /// The forwardable source list, verbatim from `virtual-headset-ctl
    /// list-sources` (array of {name, description, default, configured}).
    Sources {
        sources: serde_json::Value,
    },
    Pong,
    Error {
        message: String,
    },
}

/// Shared, locked stdout so the stdin reader and the D-Bus signal thread can
/// both write framed messages without interleaving.
type Out = Arc<Mutex<io::Stdout>>;

fn main() {
    let out: Out = Arc::new(Mutex::new(io::stdout()));

    // Connect to the daemon, retrying briefly in case the host starts before
    // the service is up.
    let conn = match connect_with_retry(5) {
        Some(conn) => conn,
        None => {
            send(
                &out,
                &OutMessage::Error {
                    message: "could not connect to session D-Bus".into(),
                },
            );
            // Keep running so the extension's port stays open; method calls
            // below will surface their own errors.
            Connection::session().unwrap_or_else(|_| std::process::exit(1))
        }
    };

    let proxy = match VirtualHeadsetProxyBlocking::new(&conn) {
        Ok(p) => p,
        Err(e) => {
            send(
                &out,
                &OutMessage::Error {
                    message: format!("failed to create D-Bus proxy: {e}"),
                },
            );
            std::process::exit(1);
        }
    };

    // Push the initial state so the extension can reconcile on connect.
    if let Ok(muted) = proxy.is_muted() {
        send(&out, &OutMessage::State { muted });
    }

    // Forward MuteChanged signals from the daemon to the extension. Uses its
    // own connection because the blocking signal iterator borrows it.
    {
        let out = out.clone();
        thread::spawn(move || signal_loop(out));
    }

    // Read commands from the extension until stdin closes (browser shut the
    // port), then exit cleanly.
    let mut stdin = io::stdin();
    loop {
        let msg = match read_message(&mut stdin) {
            Ok(Some(msg)) => msg,
            Ok(None) => break, // EOF: extension/browser closed the port
            Err(_) => break,
        };

        match serde_json::from_slice::<InMessage>(&msg) {
            Ok(InMessage::SetMute { muted }) => {
                let res = if muted { proxy.mute() } else { proxy.unmute() };
                if let Err(e) = res {
                    send(
                        &out,
                        &OutMessage::Error {
                            message: format!("setMute failed: {e}"),
                        },
                    );
                }
            }
            Ok(InMessage::Toggle) => {
                if let Err(e) = proxy.toggle() {
                    send(
                        &out,
                        &OutMessage::Error {
                            message: format!("toggle failed: {e}"),
                        },
                    );
                }
            }
            Ok(InMessage::Query) => {
                if let Ok(muted) = proxy.is_muted() {
                    send(&out, &OutMessage::State { muted });
                }
            }
            Ok(InMessage::ListSources) => send_sources(&out),
            Ok(InMessage::SetSource { name }) => {
                if let Err(e) = run_ctl(&["set-source", &name]) {
                    send(&out, &OutMessage::Error { message: e });
                }
                send_sources(&out);
            }
            Ok(InMessage::ClearSource) => {
                if let Err(e) = run_ctl(&["clear-source"]) {
                    send(&out, &OutMessage::Error { message: e });
                }
                send_sources(&out);
            }
            Ok(InMessage::RestartService) => {
                if let Err(e) = run_ctl(&["restart-service"]) {
                    send(&out, &OutMessage::Error { message: e });
                }
            }
            Ok(InMessage::Ping) => send(&out, &OutMessage::Pong),
            Err(e) => send(
                &out,
                &OutMessage::Error {
                    message: format!("invalid message: {e}"),
                },
            ),
        }
    }
}

/// Subscribe to `MuteChanged` and relay each new state. Reconnects on error so
/// a daemon restart doesn't permanently break the bridge.
fn signal_loop(out: Out) {
    loop {
        let conn = match connect_with_retry(usize::MAX) {
            Some(conn) => conn,
            None => return,
        };
        let proxy = match VirtualHeadsetProxyBlocking::new(&conn) {
            Ok(p) => p,
            Err(_) => {
                thread::sleep(Duration::from_secs(2));
                continue;
            }
        };
        let signals = match proxy.receive_mute_changed() {
            Ok(s) => s,
            Err(_) => {
                thread::sleep(Duration::from_secs(2));
                continue;
            }
        };
        for signal in signals {
            if let Ok(args) = signal.args() {
                send(&out, &OutMessage::State { muted: args.muted });
            }
        }
        // Iterator ended (connection dropped): loop and reconnect.
        thread::sleep(Duration::from_secs(1));
    }
}

/// Run `virtual-headset-ctl <args>` and return its stdout, or an error string.
fn run_ctl(args: &[&str]) -> Result<String, String> {
    let output = Command::new("virtual-headset-ctl")
        .args(args)
        .output()
        .map_err(|e| format!("failed to run virtual-headset-ctl: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "virtual-headset-ctl {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Fetch the source list via ctl and relay it to the extension.
fn send_sources(out: &Out) {
    match run_ctl(&["list-sources"]) {
        Ok(stdout) => match serde_json::from_str::<serde_json::Value>(&stdout) {
            Ok(sources) => send(out, &OutMessage::Sources { sources }),
            Err(e) => send(
                out,
                &OutMessage::Error {
                    message: format!("could not parse list-sources output: {e}"),
                },
            ),
        },
        Err(e) => send(out, &OutMessage::Error { message: e }),
    }
}

/// Try to open a session-bus connection, retrying with a short backoff.
fn connect_with_retry(max_attempts: usize) -> Option<Connection> {
    let mut attempt = 0usize;
    loop {
        match Connection::session() {
            Ok(conn) => return Some(conn),
            Err(_) => {
                attempt += 1;
                if attempt >= max_attempts {
                    return None;
                }
                thread::sleep(Duration::from_secs(1));
            }
        }
    }
}

/// Read one native-messaging frame: a 4-byte native-endian length prefix
/// followed by that many bytes. Returns `Ok(None)` on a clean EOF.
fn read_message(stdin: &mut io::Stdin) -> io::Result<Option<Vec<u8>>> {
    let mut len_buf = [0u8; 4];
    match stdin.read_exact(&mut len_buf) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_ne_bytes(len_buf) as usize;
    let mut buf = vec![0u8; len];
    stdin.read_exact(&mut buf)?;
    Ok(Some(buf))
}

/// Serialize and write one native-messaging frame to stdout.
fn send(out: &Out, msg: &OutMessage) {
    let bytes = match serde_json::to_vec(msg) {
        Ok(b) => b,
        Err(_) => return,
    };
    let mut stdout = out.lock().unwrap();
    let len = bytes.len() as u32;
    if stdout.write_all(&len.to_ne_bytes()).is_ok() && stdout.write_all(&bytes).is_ok() {
        let _ = stdout.flush();
    }
}
