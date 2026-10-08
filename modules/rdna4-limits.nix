# modules/rdna4-limits.nix
#
# Resource limits for GPU compute users.
#
# Enable with: rdna4.limits.enable = true in the host config.
#
# WHY:
#   HIP and RCCL pin host memory (hipHostMalloc, hipHostRegister) for DMA
#   and for peer-to-peer transfers between two GPUs. Pinned memory counts
#   against RLIMIT_MEMLOCK. The common default of 8 MiB makes large
#   pinned buffers fail, or forces a slow pageable fallback.
#   Inference engines also open many files (model shards, sockets) and
#   map many regions, so nofile and vm.max_map_count must be high.
#
# WHAT IT SETS:
#   - memlock = unlimited (soft and hard) for each group in
#     rdna4.limits.groups (default: render, video).
#   - nofile = rdna4.limits.nofile (soft and hard) for the same groups.
#   - vm.max_map_count = rdna4.limits.maxMapCount.
#
# SCOPE OF PAM LIMITS:
#   security.pam.loginLimits applies to PAM sessions: console login, ssh,
#   su, sudo. A process started from such a session (for example a tmux
#   server started over ssh) inherits the limits.
#   systemd services do NOT get PAM limits. Set LimitMEMLOCK=infinity and
#   LimitNOFILE in the unit (serviceConfig) for a GPU service.
#
# amdgpu PINNED-MEMORY CAP (not set here):
#   The kernel TTM layer also caps the system memory that the GPU can pin.
#   The cap is the module parameter ttm.pages_limit (in 4 KiB pages). The
#   default is half of system RAM. A higher cap is only necessary if a
#   workload pins more than half of RAM. Example for 48 GiB:
#     boot.kernelParams = [ "ttm.pages_limit=12582912" ];
#   This module does not set it. Measure first, then set it in the host.
#
{ config, lib, ... }:

let
  cfg = config.rdna4.limits;

  limitsFor = group: [
    { domain = "@${group}"; type = "soft"; item = "memlock"; value = "unlimited"; }
    { domain = "@${group}"; type = "hard"; item = "memlock"; value = "unlimited"; }
    { domain = "@${group}"; type = "soft"; item = "nofile";  value = cfg.nofile; }
    { domain = "@${group}"; type = "hard"; item = "nofile";  value = cfg.nofile; }
  ];
in
{
  options.rdna4.limits = {
    enable = lib.mkEnableOption "memlock, nofile and vm.max_map_count limits for GPU compute users";

    groups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "render" "video" ];
      description = "Groups that get unlimited memlock and the nofile limit.";
    };

    nofile = lib.mkOption {
      type = lib.types.ints.positive;
      default = 65536;
      description = "Soft and hard RLIMIT_NOFILE for the groups.";
    };

    maxMapCount = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1048576;
      description = ''
        Value for the vm.max_map_count sysctl. NixOS already sets 1048576
        with mkDefault. This module sets it at a slightly higher priority,
        so the value stays if the NixOS default changes. A direct host
        setting still wins.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    security.pam.loginLimits = lib.concatMap limitsFor cfg.groups;

    boot.kernel.sysctl."vm.max_map_count" = lib.mkOverride 999 cfg.maxMapCount;
  };
}
