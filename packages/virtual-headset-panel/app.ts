import app from "ags/gtk4/app";
import Gtk from "gi://Gtk?version=4.0";
import style from "./style.scss";
import Panel from "./Panel";
import { togglePanel, setPanelOpen } from "./controller";

// Single-instance panel. Run directly (or `ags run`) to show it; a second
// invocation forwards its argv here, so `virtual-headset-panel toggle` (bound
// to a key) shows/hides the running instance.
app.start({
  instanceName: "virtual-headset-panel",
  css: style,
  gtkTheme: "Adwaita",
  requestHandler(argv, res) {
    const cmd = argv[0];
    if (cmd === "toggle") togglePanel();
    else if (cmd === "open" || cmd === "present") setPanelOpen(true);
    else if (cmd === "close") setPanelOpen(false);
    res("ok");
  },
  main(...argv: string[]) {
    // Render the dark Adwaita variant so every widget inherits the theme's
    // colors (background, buttons, text) instead of the light default — no
    // hardcoded colors needed in style.scss.
    Gtk.Settings.get_default()?.set_property(
      "gtk-application-prefer-dark-theme",
      true,
    );

    app.add_window(Panel());

    // Cold start: honour the requested action so `virtual-headset-panel toggle`
    // (e.g. the bar's right-click) opens it the first time too. Warm
    // invocations are handled by requestHandler above. `close` leaves it
    // resident-but-hidden for the next toggle.
    setPanelOpen(argv[0] !== "close");
  },
});
