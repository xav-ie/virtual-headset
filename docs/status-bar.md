# Status bar & desktop panel

- [Waybar](#waybar) (Home Manager module)
- [Desktop panel](#desktop-panel) (AGS)
- [Other status bars](#other-status-bars) (i3, Polybar, …)

All of these read the same `MuteChanged` D-Bus signal for live updates and use
`virtual-headset-ctl` for actions, so they stay in sync with the keyboard and the
browser extension.

## Waybar

The `homeManagerModules.default` module adds a Waybar module that shows the mute
state, updates instantly via D-Bus, toggles on click, and restarts the service on
right-click:

```nix
{
  imports = [ virtual-headset.homeManagerModules.default ];

  programs.virtual-headset-waybar = {
    enable = true;
    mutedIcon = " ";   # Nerd Font icons; use anything you like
    unmutedIcon = " ";
  };

  # add the module to your bar
  programs.waybar.settings.mainBar.modules-right = [
    "custom/virtual-headset"
  ];
}
```

See [homeManagerModules/default.nix](../homeManagerModules/default.nix) for
styling and all options.

## Desktop panel

`virtual-headset-panel` is a standalone [Astal/AGS](https://github.com/aylur/ags)
panel that mirrors the browser extension: a live mute toggle and an audio-source
picker, themed to your desktop.

```bash
nix run .#virtual-headset-panel            # show it
nix run .#virtual-headset-panel -- toggle  # show/hide a running instance
```

Bind `virtual-headset-panel toggle` to a key, or wire it to a status-bar click,
to pop it open. Picking a different source restarts the daemon (the mic blips for
about a second), so it's a between-calls action.

## Other status bars

Any bar that can run a shell command works. Query state over D-Bus and toggle
with `virtual-headset-ctl`.

**i3status / i3blocks**

```ini
[virtual-headset]
command=dbus-send --session --print-reply --dest=com.github.virtual_headset /com/github/virtual_headset com.github.virtual_headset.Mute.IsMuted | grep -q "boolean true" && echo "🔇" || echo "🔊"
interval=1
signal=10
```

**Polybar**

```ini
[module/virtual-headset]
type = custom/script
exec = dbus-send --session --print-reply --dest=com.github.virtual_headset /com/github/virtual_headset com.github.virtual_headset.Mute.IsMuted | grep -q "boolean true" && echo "🔇" || echo "🔊"
interval = 1
click-left = virtual-headset-ctl toggle-mute
```

For event-driven updates instead of polling, consume
`virtual-headset-ctl monitor-mute` (JSON) — that's what the Waybar module does.
