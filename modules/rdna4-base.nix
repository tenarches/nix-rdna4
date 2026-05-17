# modules/rdna4-base.nix
#
# RDNA4 base graphics module.
#
# Covers: amdgpu kernel driver, early KMS, Vulkan via RADV (Mesa),
#         hardware.graphics, kernel parameters, VA-API, diagnostics.
#
# Replace modules/hardware/petunia/nvidia.nix with this module.
# Remove `kernelModules = ["nvidia"]` from hardware-configuration.nix.
#
# VULKAN DRIVER:
#   RADV (Mesa) is the correct ICD for RDNA4. It outperforms AMDVLK across
#   rasterization, ray tracing, and compute-adjacent workloads. AMDVLK is
#   not installed here. Do not add it without an explicit reason.
#
{ pkgs, ... }:

{
  services.xserver.videoDrivers = [ "amdgpu" ];

  # Load amdgpu in initrd for early KMS, a stable splash, and render node
  # availability before user-space services start.
  hardware.amdgpu.initrd.enable = true;

  # ── Kernel parameters ──────────────────────────────────────────────────────
  #
  # amdgpu.gpu_recovery=1
  #   Enable soft GPU reset on driver timeout instead of hard hang. Critical
  #   for compute workloads (LLM inference) that push the memory subsystem.
  #
  # amdgpu.lockup_timeout=10000
  #   10-second lockup threshold. ROCm kernels can legitimately run for
  #   several seconds without yielding; the default 5s causes false resets.
  #
  # iommu=pt
  #   IOMMU passthrough mode. Reduces DMA translation overhead, improves GPU
  #   memory latency. Standard practice for any AMD GPU compute host.
  #
  # Note: pcie_aspm=off is already set in ryzen.nix. NixOS mkMerge deduplicates
  # kernelParams lists across modules — no conflict.
  #
  boot.kernelParams = [
    "amdgpu.gpu_recovery=1"
    "amdgpu.lockup_timeout=10000"
    "iommu=pt"
  ];

  # ── Graphics stack ─────────────────────────────────────────────────────────

  hardware.graphics = {
    enable    = true;
    enable32Bit = true;  # Required for Wine, Steam, 32-bit Vulkan clients

    extraPackages = with pkgs; [
      # OpenCL ICD via ROCm CLR. Makes the GPU visible to clinfo and OpenCL
      # applications. This is the dispatch layer; the full ROCm compute stack
      # lives in rdna4-rocm.nix.
      rocmPackages.clr.icd

      # VA-API for RDNA4's dedicated multimedia engine (AV1, H.265 decode/encode).
      libva
    ];

    extraPackages32 = with pkgs.pkgsi686Linux; [
      libva
    ];
  };

  # ── Environment variables ──────────────────────────────────────────────────

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "radeonsi";
    VDPAU_DRIVER     = "radeonsi";
  };

  # ── Diagnostics ────────────────────────────────────────────────────────────

  environment.systemPackages = with pkgs; [
    nvtopPackages.amd       # Real-time GPU utilization (replaces nvtopPackages.nvidia)
    amdgpu_top              # Detailed AMDGPU metrics: clocks, VRAM, power, engines
    vulkan-tools            # vulkaninfo, vkcube
    vulkan-validation-layers
    clinfo                  # Verify OpenCL ICD is visible
  ];
}
