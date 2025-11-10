use crossbeam_channel::Sender;
use std::sync::{Arc, Mutex};
use zbus::{SignalContext, blocking::Connection, interface};

/// Shared mute state accessible from D-Bus interface
#[derive(Clone)]
pub struct MuteState {
    inner: Arc<Mutex<bool>>,
}

impl MuteState {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(false)),
        }
    }

    pub fn set(&self, muted: bool) {
        *self.inner.lock().unwrap() = muted;
    }

    pub fn get(&self) -> bool {
        *self.inner.lock().unwrap()
    }
}

/// D-Bus interface for virtual headset mute control
pub struct VirtualHeadset {
    state: MuteState,
    toggle_tx: Sender<()>,
}

#[interface(name = "com.github.virtual_headset.Mute")]
impl VirtualHeadset {
    /// Get current mute state
    fn is_muted(&self) -> bool {
        self.state.get()
    }

    /// Toggle mute state
    fn toggle(&self) -> zbus::fdo::Result<()> {
        self.toggle_tx.send(()).map_err(|e| {
            zbus::fdo::Error::Failed(format!("Failed to send toggle command: {}", e))
        })?;
        Ok(())
    }

    /// Signal emitted when mute state changes
    #[zbus(signal)]
    async fn mute_changed(signal_ctxt: &SignalContext<'_>, muted: bool) -> zbus::Result<()>;
}

impl VirtualHeadset {
    pub fn new(state: MuteState, toggle_tx: Sender<()>) -> Self {
        Self { state, toggle_tx }
    }
}

/// D-Bus connection wrapper
pub struct DBusService {
    connection: Connection,
    state: MuteState,
}

impl DBusService {
    /// Initialize D-Bus service on session bus
    pub fn new(toggle_tx: Sender<()>) -> Result<Self, Box<dyn std::error::Error>> {
        let state = MuteState::new();
        let connection = Connection::session()?;

        let interface = VirtualHeadset::new(state.clone(), toggle_tx);
        connection
            .object_server()
            .at("/com/github/virtual_headset", interface)?;

        connection.request_name("com.github.virtual_headset")?;

        Ok(Self { connection, state })
    }

    /// Get the shared mute state
    pub fn state(&self) -> MuteState {
        self.state.clone()
    }

    /// Send mute changed signal
    pub fn notify_mute_changed(&self, muted: bool) -> Result<(), Box<dyn std::error::Error>> {
        let object_server = self.connection.object_server();
        let iface_ref =
            object_server.interface::<_, VirtualHeadset>("/com/github/virtual_headset")?;

        // Use blocking runtime to send signal
        zbus::block_on(async {
            VirtualHeadset::mute_changed(iface_ref.signal_context(), muted).await
        })?;

        Ok(())
    }
}
