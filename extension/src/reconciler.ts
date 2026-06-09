// The mute reconciler: keeps the headset (D-Bus) side and the web UI in sync.
//
// It holds a single `agreed` state — what we believe both sides currently hold.
// A change from either side that already matches `agreed` is treated as an echo
// of our own action and ignored, which is what prevents feedback loops. A change
// that differs becomes the new truth and is pushed to the other side.
//
// Pure (no browser globals) so the loop-prevention logic is unit-tested in
// ../test/reconciler.test.ts; background.ts wires the actions to the real APIs.

export interface ReconcilerActions {
  /** Drive the web UI (content scripts) to this mute state. */
  applyToWeb(muted: boolean): void;
  /** Tell the headset/daemon to take this mute state. */
  setHeadsetMute(muted: boolean): void;
  /** The agreed state changed (e.g. update the toolbar icon). null = unknown. */
  onChange(state: boolean | null): void;
}

export class Reconciler {
  // null = unknown yet. Otherwise true = muted.
  private agreed: boolean | null = null;

  constructor(private readonly actions: ReconcilerActions) {}

  get state(): boolean | null {
    return this.agreed;
  }

  private set(state: boolean | null): void {
    this.agreed = state;
    this.actions.onChange(state);
  }

  /** The headset / D-Bus side reports a state. */
  fromHeadset(muted: boolean): void {
    if (this.agreed === muted) return; // echo of our own setHeadsetMute
    this.set(muted);
    this.actions.applyToWeb(muted);
  }

  /** A content script reports the web UI's state. */
  fromWeb(muted: boolean): void {
    if (this.agreed === null) {
      // First signal from the web before the headset told us anything: adopt
      // it and push it to the headset.
      this.set(muted);
      this.actions.setHeadsetMute(muted);
      return;
    }
    if (this.agreed === muted) return; // echo of our own applyToWeb
    this.set(muted);
    this.actions.setHeadsetMute(muted);
  }

  /** Host disconnected — state is unknown again. */
  reset(): void {
    this.set(null);
  }
}
