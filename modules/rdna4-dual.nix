# modules/rdna4-dual.nix
#
# Dual R9700 configuration stub — inert until a second card is installed.
#
# Enable with: rdna4.dualGpu.enable = true in the host config.
#
# DUAL-GPU ROCm ARCHITECTURE:
#   Two gfx1201 devices appear as:
#     /dev/dri/card0   /dev/dri/renderD128  — GPU 0
#     /dev/dri/card1   /dev/dri/renderD129  — GPU 1
#     /dev/kfd         — single KFD node enumerating both HSA agents
#
#   HIP device indices: GPU 0 = device 0, GPU 1 = device 1.
#   rocminfo will list two Agent entries with ISA gfx1201.
#
#   llama.cpp RPC mode splits model layers across devices.
#   vLLM uses tensor parallelism (--tensor-parallel-size 2).
#
# PCIe NOTE (X570 AORUS MASTER):
#   The board supports x8/x8 PCIe 4.0 bifurcation with two full-length slots.
#   At PCIe 4.0 x8 the R9700 is not bandwidth-constrained for inference.
#   Verify after install: lspci -vv | grep -A5 "VGA\|3D"
#
{ config, lib, ... }:

let
  cfg = config.rdna4.dualGpu;
in
{
  options.rdna4.dualGpu = {
    enable = lib.mkEnableOption "dual R9700 configuration";
  };

  config = lib.mkIf cfg.enable {
    environment.sessionVariables = {
      ROCR_VISIBLE_DEVICES = lib.mkForce "0,1";
      HCC_AMDGPU_TARGET    = lib.mkForce "gfx1201,gfx1201";
      AMDGPU_TARGETS       = lib.mkForce "gfx1201";
      GPU_TARGETS          = lib.mkForce "gfx1201";
    };

    boot.kernelParams = [
      # Maximize PCIe read request size for inter-GPU DMA throughput.
      "pcie_bus_config=performance"
    ];
  };
}
