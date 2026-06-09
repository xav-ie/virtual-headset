# Shared VM machine for the runtime + extension tests: the daemon as a user
# service for `alice`, with headless PipeWire providing a virtual capture source
# to forward.
{ inputs, system }:
{ pkgs, ... }:
{
  imports = [ inputs.self.nixosModules.default ];

  services.virtual-headset = {
    enable = true;
    user = "alice";
  };

  users.users.alice = {
    isNormalUser = true;
    uid = 1000;
  };

  boot.kernelModules = [ "uhid" ]; # for the virtual HID device

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    pulse.enable = true;

    # No audio hardware in the VM, so create a virtual capture source for the
    # daemon to forward.
    extraConfig.pipewire."99-vh-test-source"."context.objects" = [
      {
        factory = "adapter";
        args = {
          "factory.name" = "support.null-audio-sink";
          "node.name" = "vh-test-source";
          "node.description" = "VH Test Source";
          "media.class" = "Audio/Source/Virtual";
          "audio.position" = "MONO";
        };
      }
    ];

    # The tests use one-shot `pactl` clients that connect and exit immediately;
    # pipewire-pulse then races to set socket options on the already-gone fd and
    # logs benign EBADF warnings (SO_PRIORITY / SO_PEERCRED). It's a VM artifact
    # — real desktops with long-lived clients don't hit it (nondeterministic in
    # the VM too). Drop the pulse server to error level so real problems still
    # surface but this noise doesn't.
    extraConfig.pipewire-pulse."90-quiet-pulse"."context.properties"."log.level" = 1;
  };

  environment.systemPackages = [
    inputs.self.packages.${system}.virtual-headset-ctl
    pkgs.dbus
    pkgs.pulseaudio # pactl client for the test scripts
  ];
}
