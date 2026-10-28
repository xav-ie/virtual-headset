use crossbeam_channel::Sender;
use serde::Serialize;
use std::sync::{Arc, Mutex};
use zbus::{SignalContext, blocking::Connection, interface};

/// A request from D-Bus for the daemon's main loop, which owns the device and
/// the audio graph and is the only place state changes.
pub enum Command {
    Mute,
    SetStrength(f64),
    Toggle,
    Unmute,
}

/// Everything a panel or bar shows, published as JSON by `GetState` and the
/// `StateChanged` signal.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    /// "none" (no call app has the headset off-hook), "muted" or "unmuted".
    pub call: &'static str,
    pub denoise: bool,
    /// Whether this build can denoise (DeepFilterNet's LADSPA plugin is found).
    pub denoise_available: bool,
    pub keep_open: bool,
    pub muted: bool,
    /// The forwarded source's description.
    pub source: String,
    pub strength: f64,
}

/// Shared state accessible from D-Bus interface
#[derive(Clone)]
pub struct SharedState {
    inner: Arc<Mutex<State>>,
}

impl SharedState {
    pub fn new(state: State) -> Self {
        Self {
            inner: Arc::new(Mutex::new(state)),
        }
    }

    pub fn set(&self, state: State) {
        *self.inner.lock().unwrap() = state;
    }

    pub fn get(&self) -> State {
        self.inner.lock().unwrap().clone()
    }
}

/// D-Bus interface for virtual headset mute control
pub struct VirtualHeadset {
    state: SharedState,
    commands: Sender<Command>,
}

impl VirtualHeadset {
    fn send(&self, command: Command) -> zbus::fdo::Result<()> {
        self.commands
            .send(command)
            .map_err(|e| zbus::fdo::Error::Failed(format!("Failed to send command: {}", e)))
    }
}

#[interface(name = "com.github.virtual_headset.Mute")]
impl VirtualHeadset {
    /// Get current mute state
    fn is_muted(&self) -> bool {
        self.state.get().muted
    }

    /// The whole state, as JSON (see `State`)
    fn get_state(&self) -> String {
        serde_json::to_string(&self.state.get()).unwrap_or_default()
    }

    /// Toggle mute state
    fn toggle(&self) -> zbus::fdo::Result<()> {
        self.send(Command::Toggle)
    }

    /// Set mute state to muted
    fn mute(&self) -> zbus::fdo::Result<()> {
        self.send(Command::Mute)
    }

    /// Set mute state to unmuted
    fn unmute(&self) -> zbus::fdo::Result<()> {
        self.send(Command::Unmute)
    }

    /// Set the noise suppression strength (attenuation limit, dB), live
    fn set_strength(&self, db: f64) -> zbus::fdo::Result<()> {
        self.send(Command::SetStrength(db))
    }

    /// Signal emitted when mute state changes
    #[zbus(signal)]
    async fn mute_changed(signal_ctxt: &SignalContext<'_>, muted: bool) -> zbus::Result<()>;

    /// Signal emitted when anything in the state changes, with the new state as JSON
    #[zbus(signal)]
    async fn state_changed(signal_ctxt: &SignalContext<'_>, state: String) -> zbus::Result<()>;

    /// The virtual mic's level in dBFS, about 10 times a second while audio flows
    #[zbus(signal)]
    async fn level(signal_ctxt: &SignalContext<'_>, db: f64) -> zbus::Result<()>;
}

/// D-Bus connection wrapper
#[derive(Clone)]
pub struct DBusService {
    connection: Connection,
    state: SharedState,
}

impl DBusService {
    /// Initialize D-Bus service on session bus
    pub fn new(
        state: State,
        commands: Sender<Command>,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let state = SharedState::new(state);
        let connection = Connection::session()?;

        let interface = VirtualHeadset {
            state: state.clone(),
            commands,
        };
        connection
            .object_server()
            .at("/com/github/virtual_headset", interface)?;

        connection.request_name("com.github.virtual_headset")?;

        Ok(Self { connection, state })
    }

    fn signal_context(&self) -> zbus::Result<SignalContext<'static>> {
        let object_server = self.connection.object_server();
        let iface_ref =
            object_server.interface::<_, VirtualHeadset>("/com/github/virtual_headset")?;
        Ok(iface_ref.signal_context().to_owned())
    }

    /// Store the new state and announce it: `MuteChanged` (for status bars that
    /// only care about mute) and `StateChanged`.
    pub fn publish(&self, state: State) -> Result<(), Box<dyn std::error::Error>> {
        let muted = state.muted;
        let json = serde_json::to_string(&state)?;
        self.state.set(state);
        let ctxt = self.signal_context()?;
        zbus::block_on(async {
            VirtualHeadset::mute_changed(&ctxt, muted).await?;
            VirtualHeadset::state_changed(&ctxt, json).await
        })?;
        Ok(())
    }

    pub fn publish_level(&self, db: f64) -> Result<(), Box<dyn std::error::Error>> {
        let ctxt = self.signal_context()?;
        zbus::block_on(VirtualHeadset::level(&ctxt, db))?;
        Ok(())
    }
}
