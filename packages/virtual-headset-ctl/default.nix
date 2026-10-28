{
  coreutils,
  dbus,
  deepfilternet,
  pipewire,
  pulseaudio,
  systemd,
  writeNuApplication,
}:
writeNuApplication {
  name = "virtual-headset-ctl";
  runtimeInputs = [
    coreutils # timeout, for test-record
    dbus
    pipewire # the noise suppression test's recording and playback
    pulseaudio
    systemd
  ];
  # test-play runs the same DeepFilterNet plugin as the daemon.
  text = ''
    $env.VIRTUAL_HEADSET_LADSPA = "${deepfilternet}/lib/ladspa/libdeep_filter_ladspa.so"
  ''
  + builtins.readFile ./virtual-headset-ctl.nu;
}
