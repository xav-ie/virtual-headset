import { Astal, Gtk, Gdk } from "ags/gtk4";
import { createState, onCleanup, For } from "ags";
import { execAsync, subprocess } from "ags/process";
import { panelOpen, setPanelOpen } from "./controller";
import { withActive, parseMuteLine, type Source } from "./logic";

// Sister panel to the Firefox extension: mirrors the virtual-headset mute state
// and adds a source picker. Everything goes through `virtual-headset-ctl` — the
// same shared CLI the bar module and the browser bridge use — so there's one
// source of truth for the logic.

const CTL = "virtual-headset-ctl";

export default function Panel() {
  const [muted, setMuted] = createState(false);
  const [sources, setSources] = createState<Source[]>([]);
  const [busy, setBusy] = createState(false);

  // Live mute state via the same monitor-mute stream the bar uses.
  const proc = subprocess(
    [CTL, "monitor-mute", "muted", "unmuted"],
    (line) => {
      const m = parseMuteLine(line);
      if (m !== null) setMuted(m);
    },
    (err) => console.error("vh-panel: monitor-mute", err),
  );
  onCleanup(() => proc.kill());

  function refresh(): void {
    execAsync([CTL, "list-sources"])
      .then((out) => setSources(withActive(JSON.parse(out))))
      .catch((err) => console.error("vh-panel: list-sources", err));
  }
  refresh();

  // Re-read the source list whenever the panel is shown (it may have changed,
  // and set-source restarts the daemon).
  const unsub = panelOpen.subscribe(() => {
    if (panelOpen.get()) refresh();
  });
  onCleanup(() => unsub());

  function withRefresh(args: string[]): void {
    setBusy(true);
    execAsync(args)
      .catch((err) => console.error(`vh-panel: ${args.join(" ")}`, err))
      .finally(() => {
        setBusy(false);
        refresh();
      });
  }

  const close = () => setPanelOpen(false);

  return (
    <window
      name="virtual-headset-panel"
      namespace="virtual-headset-panel"
      visible={panelOpen}
      keymode={Astal.Keymode.ON_DEMAND}
      exclusivity={Astal.Exclusivity.IGNORE}
    >
      <Gtk.EventControllerKey
        onKeyPressed={(_c, keyval: number) => {
          if (keyval === Gdk.KEY_Escape) {
            close();
            return true;
          }
          return false;
        }}
      />
      {/* `background` style class = the theme's opaque window background, so the
          transparent layer surface gets a proper themed (dark) card. */}
      <box
        class="vh-panel background"
        orientation={Gtk.Orientation.VERTICAL}
        spacing={12}
      >
        <box class="vh-header" spacing={6}>
          <image
            iconName={muted((m) =>
              m
                ? "microphone-disabled-symbolic"
                : "audio-input-microphone-symbolic",
            )}
            pixelSize={18}
          />
          <label
            class="vh-title title-4"
            label="Virtual Headset"
            hexpand
            halign={Gtk.Align.START}
          />
          <button
            class="vh-icon-btn flat"
            tooltipText="Close"
            onClicked={close}
          >
            <image iconName="window-close-symbolic" pixelSize={14} />
          </button>
        </box>

        {/* Mute (live = themed red) and Restart, split 50/50. Text colour is
            left to the theme. */}
        <box class="vh-controls" spacing={8} homogeneous>
          <button
            class={muted((m) =>
              m ? "vh-ctl-btn" : "vh-ctl-btn destructive-action",
            )}
            tooltipText={muted((m) =>
              m ? "Click to unmute" : "Click to mute",
            )}
            onClicked={() =>
              execAsync([CTL, "toggle-mute"]).catch((err) =>
                console.error("vh-panel: toggle-mute", err),
              )
            }
          >
            <label label={muted((m) => (m ? "Mic muted" : "Mic live"))} />
          </button>
          <button
            class="vh-ctl-btn"
            tooltipText="Restart the virtual-headset service"
            sensitive={busy((b) => !b)}
            onClicked={() => withRefresh([CTL, "restart-service"])}
          >
            <box spacing={6} halign={Gtk.Align.CENTER}>
              <image iconName="view-refresh-symbolic" pixelSize={14} />
              <label label="Restart" />
            </box>
          </button>
        </box>

        <label
          class="vh-section dim-label"
          label="Audio source"
          halign={Gtk.Align.START}
        />
        <box orientation={Gtk.Orientation.VERTICAL} spacing={2}>
          <For each={sources}>
            {(s: Source) =>
              (
                <button
                  class={`vh-source flat${s.active ? " active" : ""}`}
                  sensitive={busy((b) => !b)}
                  tooltipText={
                    s.active
                      ? "Currently forwarded"
                      : s.default
                        ? "Follow the system default input"
                        : "Forward this source"
                  }
                  onClicked={() => {
                    if (s.active) return;
                    withRefresh(
                      s.default
                        ? [CTL, "clear-source"]
                        : [CTL, "set-source", s.name],
                    );
                  }}
                >
                  <box spacing={10}>
                    {s.active ? (
                      <image iconName="object-select-symbolic" pixelSize={14} />
                    ) : (
                      <box class="vh-check-spacer" />
                    )}
                    <label
                      class={s.active ? "vh-active-label" : ""}
                      label={s.description}
                      hexpand
                      halign={Gtk.Align.START}
                    />
                    {s.default ? (
                      <label class="vh-chip dim-label" label="system default" />
                    ) : (
                      <box />
                    )}
                  </box>
                </button>
              ) as Gtk.Widget
            }
          </For>
        </box>
      </box>
    </window>
  ) as Astal.Window;
}
