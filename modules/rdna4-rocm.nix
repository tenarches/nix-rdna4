# modules/rdna4-rocm.nix
#
# ROCm 7.x compute stack.
#
# Covers: /opt/rocm symlink, ROCm diagnostic tools, KFD device permissions,
#         and environment variables for the HSA/HIP runtime.
#
# COEXISTENCE WITH VULKAN:
#   amdgpu exposes two independent interfaces to the same gfx1201 device:
#     DRM/KMS → /dev/dri/renderD128  (consumed by Mesa/RADV — Vulkan path)
#     KFD     → /dev/kfd             (consumed by ROCm CLR — compute path)
#   Both are active simultaneously. There is no driver-level conflict.
#
# PACKAGE ACCESS PATTERN:
#   Use pkgs.pkgsRocm.<package> — not nixpkgs.config.rocmSupport = true.
#   Global rocmSupport enables ROCm in Firefox, Thunderbird, and other
#   unrelated packages, increasing closure size and build failure exposure.
#
# HSA_OVERRIDE_GFX_VERSION is intentionally absent.
#   That variable overrides ISA detection for unsupported hardware
#   (e.g. RDNA2 under ROCm 6.x). gfx1201 is officially supported in
#   ROCm 7.x. Setting the override misidentifies the ISA at the HSA
#   runtime level and causes wrong code generation.
#
{ pkgs, ... }:

{
  # ── /opt/rocm symlink ──────────────────────────────────────────────────────
  #
  # AMD's toolchain and most ML frameworks hard-code /opt/rocm for library
  # discovery. This is the canonical NixOS workaround.
  #
  # Add paths here as your workload requires (e.g. rocSPARSE, MIOpen).
  #
  systemd.tmpfiles.rules =
    let
      rocmEnv = pkgs.symlinkJoin {
        name  = "rocm-combined-gfx1201";
        paths = with pkgs.rocmPackages; [
          clr       # HSA runtime, HIP runtime, OpenCL ICD, device libs
          rocblas   # BLAS kernels — critical path for LLM matrix ops
          hipblas   # HIP BLAS API over rocBLAS
          rocminfo  # rocminfo binary
          rocm-smi  # System Management Interface
        ];
      };
    in [
      "L+ /opt/rocm - - - - ${rocmEnv}"
    ];

  # ── System packages ────────────────────────────────────────────────────────

  environment.systemPackages = with pkgs; [
    rocmPackages.rocminfo  # Enumerate HSA agents; verify gfx1201 is visible
    rocmPackages.rocm-smi  # GPU power, temperature, clock states
  ];

  # ── Environment variables ──────────────────────────────────────────────────

  environment.sessionVariables = {
    # Limit ROCm device visibility. "0" = first GPU.
    # Change to "0,1" when the second R9700 is installed (rdna4-dual.nix).
    ROCR_VISIBLE_DEVICES = "0";

    # Explicit GPU target for tools that JIT-compile HIP kernels at runtime.
    HCC_AMDGPU_TARGET = "gfx1201";
  };

  # ── KFD device permissions ─────────────────────────────────────────────────
  #
  # /dev/kfd is the HSA compute interface, owned by root:render by default.
  # Users need both `video` and `render` groups.
  # Verify ddukes has these in users.users.ddukes.extraGroups.
  #
  services.udev.extraRules = ''
    SUBSYSTEM=="drm",  KERNEL=="renderD*", GROUP="render", MODE="0660"
    KERNEL=="kfd",                         GROUP="render", MODE="0660"
  '';
}
