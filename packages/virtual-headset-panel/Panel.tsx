import { Astal, Gtk, Gdk } from "ags/gtk4";
import { createComputed, createState, onCleanup } from "ags";
import { execAsync, subprocess } from "ags/process";
import { interval, timeout } from "ags/time";
import type { Process } from "ags/process";
import { panelOpen, setPanelOpen } from "./controller";
import {
  withActive,
  parseState,
  callRow,
  statusText,
  strengthLabel,
  meterFraction,
  levelFresh,
  INITIAL_STATE,
  MAX_STRENGTH,
  type Source,
} from "./logic";

// The Linux twin of the macOS panel (packages/virtual-headset-macos): the
// call's mute first, then the mic it forwards, then noise suppression, then
// Advanced. Everything goes through `virtual-headset-ctl` — the same shared CLI
// the bar module and the browser bridge use — so there's one source of truth.

const CTL = "virtual-headset-ctl";

const run = (args: string[]) =>
  execAsync([CTL, ...args]).catch((err) =>
    console.error(`vh-panel: ${args.join(" ")}`, err),
  );

// Screen readers name a control after this, like the macOS panel's row titles.
function name(widget: Gtk.Widget, label: string): void {
  widget.update_property([Gtk.AccessibleProperty.LABEL], [label]);
}

export default function Panel() {
  const [state, setState] = createState(INITIAL_STATE);
  const [sources, setSources] = createState<Source[]>([]);
  const [level, setLevel] = createState(-Infinity);
  const [levelAt, setLevelAt] = createState(0);
  const [now, setNow] = createState(Date.now());
  const [advanced, setAdvanced] = createState(false);
  const [test, setTest] = createState<
    "" | "recording" | "original" | "denoised"
  >("");
  const [hasTake, setHasTake] = createState(false);

  // Live state and level, from the daemon's D-Bus signals via ctl.
  const stateProc = subprocess(
    [CTL, "monitor-state"],
    (line) => {
      const s = parseState(line);
      if (s) setState(s);
    },
    (err) => console.error("vh-panel: monitor-state", err),
  );
  const levelProc = subprocess(
    [CTL, "monitor-level"],
    (line) => {
      const db = Number(line);
      if (Number.isFinite(db)) {
        setLevel(db);
        setLevelAt(Date.now());
      }
    },
    (err) => console.error("vh-panel: monitor-level", err),
  );
  // Levels stop arriving when the mic closes; this ticks the freshness check.
  const tick = interval(250, () => setNow(Date.now()));
  onCleanup(() => {
    stateProc.kill();
    levelProc.kill();
    tick.cancel();
  });

  function refreshSources(): void {
    execAsync([CTL, "list-sources"])
      .then((out) => setSources(withActive(JSON.parse(out))))
      .catch((err) => console.error("vh-panel: list-sources", err));
  }
  refreshSources();
  // Re-read the list whenever the panel opens (it may have changed, and
  // set-source restarts the daemon).
  const unsub = panelOpen.subscribe(() => {
    if (panelOpen.get()) refreshSources();
  });
  onCleanup(() => unsub());

  const close = () => setPanelOpen(false);

  let syncingSources = false;

  // The test's one running step (a recording or a playback). Pressing its
  // button again stops it (SIGTERM; a stopped recording keeps the take so far).
  let testProc: Process | null = null;
  const [secondsLeft, setSecondsLeft] = createState(0);
  let countdown: ReturnType<typeof interval> | null = null;
  function runTest(kind: "recording" | "original" | "denoised"): void {
    if (testProc) {
      const stopping = test.get() === kind;
      testProc.signal(15);
      if (stopping) return;
      testProc = null;
    }
    const args = kind === "recording" ? ["test-record"] : ["test-play", kind];
    setTest(kind);
    testProc = subprocess(
      [CTL, ...args],
      () => {},
      (err) => console.error(`vh-panel: ${args.join(" ")}`, err),
    );
    if (kind === "recording") {
      setSecondsLeft(8);
      countdown = interval(1000, () =>
        setSecondsLeft(Math.max(1, secondsLeft.get() - 1)),
      );
    }
    const proc = testProc;
    proc.connect("exit", () => {
      if (testProc === proc) testProc = null;
      if (kind === "recording") {
        countdown?.cancel();
        countdown = null;
        setHasTake(true);
      }
      if (test.get() === kind) setTest("");
    });
  }

  const call = state((s) => callRow(s));
  const levelShown = createComputed([levelAt, now], (at, n) =>
    levelFresh(at, n),
  );
  const denoiseShown = state((s) => s.denoise);

  return (
    <window
      name="virtual-headset-panel"
      namespace="virtual-headset-panel"
      visible={panelOpen}
      keymode={Astal.Keymode.EXCLUSIVE}
      exclusivity={Astal.Exclusivity.IGNORE}
      $={(self) => name(self, "Virtual Headset")}
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
        spacing={8}
      >
        {/* The call's mic: the most prominent line. */}
        <box class="vh-call" spacing={10}>
          <image
            class={call((c) => (c.live ? "vh-live" : "vh-quiet"))}
            iconName={call((c) =>
              c.live
                ? "audio-input-microphone-symbolic"
                : "microphone-disabled-symbolic",
            )}
            pixelSize={18}
          />
          <label
            class={call((c) =>
              c.title === "Not in a call"
                ? "vh-call-title dim-label"
                : "vh-call-title",
            )}
            label={call((c) => c.title)}
            hexpand
            halign={Gtk.Align.START}
          />
          <button
            class="vh-mute"
            label={call((c) => c.button)}
            $={(self) => {
              const update = () => name(self, call.get().buttonLabel);
              update();
              const unsubscribe = call.subscribe(update);
              onCleanup(unsubscribe);
            }}
            onClicked={() => run(["toggle-mute"])}
          />
          <button
            class="vh-close flat"
            tooltipText="Close"
            onClicked={close}
            $={(self) => name(self, "Close")}
          >
            <image iconName="window-close-symbolic" pixelSize={14} />
          </button>
        </box>

        <Gtk.Separator />
        <label class="vh-heading" label="MICROPHONE" halign={Gtk.Align.START} />
        <box class="vh-row" spacing={10}>
          <label class="vh-key" label="Input" halign={Gtk.Align.START} />
          <Gtk.DropDown
            hexpand
            $={(self) => {
              name(self, "Input");
              // Replacing the model resets the selection, so updates here are
              // marked to keep onNotifySelected from taking them for a pick.
              const update = () => {
                const list = sources.get();
                syncingSources = true;
                self.set_model(
                  Gtk.StringList.new(list.map((s) => s.description)),
                );
                const active = list.findIndex((s) => s.active);
                if (active >= 0) self.set_selected(active);
                syncingSources = false;
              };
              update();
              const unsubscribe = sources.subscribe(update);
              onCleanup(unsubscribe);
            }}
            onNotifySelected={(self) => {
              if (syncingSources) return;
              // Picking a mic other than the forwarded one switches to it (which
              // restarts the daemon).
              const picked = sources.get()[self.selected];
              if (!picked || picked.active) return;
              run(
                picked.default ? ["clear-source"] : ["set-source", picked.name],
              ).then(refreshSources);
            }}
          />
        </box>
        <box class="vh-row" spacing={10} visible={levelShown}>
          <label class="vh-key" label="Level" halign={Gtk.Align.START} />
          <Gtk.LevelBar
            hexpand
            valign={Gtk.Align.CENTER}
            minValue={0}
            maxValue={1}
            value={level((db) => meterFraction(db))}
            $={(self) => name(self, "Level")}
          />
          <label
            class="vh-value"
            label={level((db) => `${Math.round(db)} dB`)}
          />
        </box>
        <label
          class="vh-status dim-label"
          label={state((s) => statusText(s))}
          halign={Gtk.Align.START}
          wrap
        />

        <Gtk.Separator />
        <box spacing={10}>
          <label
            class="vh-heading"
            label="NOISE SUPPRESSION"
            hexpand
            halign={Gtk.Align.START}
          />
          <Gtk.Switch
            valign={Gtk.Align.CENTER}
            active={denoiseShown}
            sensitive={state((s) => s.denoiseAvailable)}
            tooltipText={state((s) =>
              s.denoiseAvailable
                ? "Turning it on or off restarts the mic for a second"
                : "Noise suppression isn't available in this build",
            )}
            $={(self) => name(self, "Noise suppression")}
            onNotifyActive={({ active }) => {
              if (active === state.get().denoise) return;
              run(["set-denoise", active ? "on" : "off"]);
            }}
          />
        </box>
        <box
          orientation={Gtk.Orientation.VERTICAL}
          spacing={8}
          visible={denoiseShown}
        >
          <box class="vh-row" spacing={10}>
            <label class="vh-key" label="Strength" halign={Gtk.Align.START} />
            <Gtk.Scale
              hexpand
              drawValue={false}
              adjustment={
                new Gtk.Adjustment({
                  lower: 0,
                  upper: MAX_STRENGTH,
                  stepIncrement: 1,
                  pageIncrement: 5,
                })
              }
              $={(self) => {
                name(self, "Strength");
                // Follow the daemon's value without sending it back; send a
                // drag once it settles, not every step of it.
                let syncing = false;
                let pending: ReturnType<typeof timeout> | null = null;
                const update = () => {
                  syncing = true;
                  self.set_value(state.get().strength);
                  syncing = false;
                };
                update();
                const unsubscribe = state.subscribe(update);
                onCleanup(unsubscribe);
                self.connect("value-changed", () => {
                  if (syncing) return;
                  pending?.cancel();
                  pending = timeout(200, () =>
                    run(["set-strength", String(Math.round(self.get_value()))]),
                  );
                });
              }}
            />
            <label
              class="vh-value"
              label={state((s) => strengthLabel(s.strength))}
            />
          </box>
          <box class="vh-row" spacing={10}>
            <label class="vh-key" label="Test" halign={Gtk.Align.START} />
            <box spacing={4} hexpand homogeneous>
              <button
                label={createComputed([test, secondsLeft], (t, left) =>
                  t === "recording" ? `${left} s` : "Record",
                )}
                tooltipText="Record 8 seconds of your mic, as it is; press again to stop"
                $={(self) => {
                  const update = () =>
                    name(
                      self,
                      test.get() === "recording"
                        ? `Stop recording, ${secondsLeft.get()} seconds left`
                        : "Record",
                    );
                  update();
                  const unsubscribeTest = test.subscribe(update);
                  const unsubscribeLeft = secondsLeft.subscribe(update);
                  onCleanup(() => {
                    unsubscribeTest();
                    unsubscribeLeft();
                  });
                }}
                onClicked={() => runTest("recording")}
              />
              <button
                label={test((t) => (t === "original" ? "Stop" : "Original"))}
                tooltipText="Play the recording as it was"
                sensitive={hasTake((h) => h)}
                onClicked={() => runTest("original")}
              />
              <button
                label={test((t) => (t === "denoised" ? "Stop" : "Denoised"))}
                tooltipText="Play the recording through noise suppression"
                sensitive={hasTake((h) => h)}
                onClicked={() => runTest("denoised")}
              />
            </box>
          </box>
        </box>

        <Gtk.Separator />
        {/* Settings almost nobody should change. A plain chevron, swapped
            instantly: no disclosure animation. */}
        <button
          class="vh-disclose flat"
          halign={Gtk.Align.START}
          onClicked={() => setAdvanced(!advanced.get())}
          $={(self) => {
            const update = () =>
              self.update_state(
                [Gtk.AccessibleState.EXPANDED],
                [advanced.get()],
              );
            update();
            const unsubscribe = advanced.subscribe(update);
            onCleanup(unsubscribe);
            name(self, "Advanced");
          }}
        >
          <box spacing={6}>
            <image
              iconName={advanced((a) =>
                a ? "pan-down-symbolic" : "pan-end-symbolic",
              )}
              pixelSize={12}
            />
            <label label="Advanced" />
          </box>
        </button>
        <box
          orientation={Gtk.Orientation.VERTICAL}
          spacing={8}
          visible={advanced}
        >
          <Gtk.CheckButton
            label="Keep the mic open between calls"
            active={state((s) => s.keepOpen)}
            onNotifyActive={({ active }) => {
              if (active === state.get().keepOpen) return;
              run(["set-keep-open", active ? "on" : "off"]);
            }}
          />
          <label
            class="vh-note dim-label"
            label="Calls start a moment sooner, but your mic stays in use even when nothing is listening."
            halign={Gtk.Align.START}
            wrap
            maxWidthChars={44}
          />
          <button
            class="vh-restart"
            halign={Gtk.Align.START}
            tooltipText="Restart the virtual-headset service"
            onClicked={() => run(["restart-service"]).then(refreshSources)}
          >
            <box spacing={6}>
              <image iconName="view-refresh-symbolic" pixelSize={14} />
              <label label="Restart service" />
            </box>
          </button>
        </box>

        <label
          class="vh-note dim-label"
          visible={state((s) => s.call === "none")}
          label="In the call app, choose “Virtual_Headset_Microphone” as the mic."
          halign={Gtk.Align.START}
          wrap
          maxWidthChars={44}
        />
      </box>
    </window>
  ) as Astal.Window;
}
