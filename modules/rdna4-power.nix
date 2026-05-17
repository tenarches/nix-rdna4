# modules/rdna4-power.nix
#
# GPU power, thermal, and fan control.
#
# Covers: LACT daemon (power limits, fan curves, OC/UV),
#         amdgpu overdrive unlock (ppfeaturemask),
#         and lm-sensors for board fan pipeline (ITE IT8688E on X570).
#
# LACT ARCHITECTURE:
#   LACT runs as a privileged systemd daemon (lactd) communicating with
#   amdgpu via sysfs and DRM ioctls. The GUI is a client to the daemon
#   and can run unprivileged. Configuration is persisted at runtime to
#   /etc/lact/config.yaml — this is intentionally not declarative.
#   GPU tuning parameters are iterative and hardware-specific; manage
#   the config file separately or commit it as a host asset.
#
# OVERDRIVE PREREQUISITE:
#   hardware.amdgpu.overdrive.enable sets amdgpu.ppfeaturemask=0xffffffff.
#   Without this, the Overclock tab in LACT is disabled. Enabling this only
#   unlocks the kernel interface — no frequencies change until you act in LACT.
#
# POWER-PROFILES-DAEMON:
#   petunia does not use power-profiles-daemon (that is the Z16 config),
#   so the ppd/LACT DPM conflict does not apply here.
#
{ pkgs, ... }:

{
  services.lact.enable = true;

  hardware.amdgpu.overdrive.enable = true;

  # it87 kernel module for ITE IT8688E (X570 AORUS MASTER Super I/O) is
  # already loaded in ryzen.nix. lm-sensors reads the chip; fancontrol
  # applies curve rules. Run `sudo sensors-detect --auto` post-deploy
  # to generate /etc/sensors3.conf, then `sudo pwmconfig` for /etc/fancontrol.
  services.lm_sensors.enable = true;

  # Uncomment once /etc/fancontrol is generated and validated:
  # services.fancontrol.enable = true;

  # Static GPU power cap via udev — alternative to LACT for headless nodes.
  # R9700 TDP is 300W; 280W leaves headroom for stable sustained inference load.
  # Uncomment to use instead of or alongside LACT:
  #
  # services.udev.extraRules = ''
  #   SUBSYSTEM=="hwmon", DRIVER=="amdgpu", ATTR{power1_cap_max}!="", \
  #     ATTR{power1_cap}="280000000"
  # '';

  environment.systemPackages = with pkgs; [
    lm_sensors  # `sensors` CLI for temperatures and fan speeds
  ];
}
