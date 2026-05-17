# modules/rdna4-build-env.nix
#
# llama.cpp build dependencies — Vulkan and ROCm backends.
#
# PURPOSE:
#   Installs the compiler toolchain and libraries required to build llama.cpp
#   from source on this host, outside of a `nix develop` shell.
#
#   For hermetic, reproducible builds use the devShells provided by this flake:
#     nix develop github:tenarches/nix-rdna4#llama-rocm    (HIP/ROCm backend)
#     nix develop github:tenarches/nix-rdna4#llama-vulkan  (Vulkan backend)
#
#   This module exists for cases where you want the tools in your normal login
#   shell without entering a devShell — e.g., iterative development cycles or
#   ad-hoc builds on an already-provisioned workstation.
#
# GROUND TRUTH:
#   Package selections are derived from nixpkgs unstable llama-cpp/package.nix:
#     rocmBuildInputs  = [ rocmPackages.clr rocmPackages.hipblas rocmPackages.rocblas ]
#     vulkanBuildInputs = [ vulkan-headers vulkan-loader ]
#   Plus nativeBuildInputs from the upstream CMake build system and the ROCm
#   compiler requirement (rocmPackages.llvm.clang for hipcc/HIP clang).
#
{ pkgs, config, lib, ... }:

let
  cfg = config.rdna4.buildEnv;
in
{
  options.rdna4.buildEnv = {
    enable = lib.mkEnableOption "llama.cpp build dependencies (Vulkan + ROCm)";

    enableRocm = lib.mkOption {
      type    = lib.types.bool;
      default = true;
      description = "Install ROCm compiler toolchain and HIP/BLAS libraries.";
    };

    enableVulkan = lib.mkOption {
      type    = lib.types.bool;
      default = true;
      description = "Install Vulkan development headers, loader, and shader compiler.";
    };
  };

  config = lib.mkIf cfg.enable {

    environment.systemPackages = with pkgs;
      # ── Common build tools ──────────────────────────────────────────────────
      [
        cmake        # Build system
        ninja        # Fast parallel build backend
        pkg-config   # Library discovery
        git          # Source checkout and llama.cpp build-info embedding
        curl         # Required by llama-server (HTTP client for model downloads)
        openssl      # TLS for llama-server
        ccache       # Optional: speeds up repeated builds significantly
      ]

      # ── ROCm compiler and libraries ────────────────────────────────────────
      #
      # rocmPackages.llvm.clang:
      #   The ROCm-patched LLVM/Clang. This is the HIP compiler — it
      #   understands __hip_* intrinsics and targets AMDGCN. Required for
      #   any -DGGML_HIP=ON build. hipcc is a wrapper around this binary.
      #
      # rocmPackages.clr:
      #   Compute Language Runtime. Provides the HIP runtime libraries and
      #   headers (hip/hip_runtime.h, etc.) that llama.cpp links against.
      #   cmake's FindHIP module looks here via HIP_PATH.
      #
      # rocmPackages.hipblas / rocblas:
      #   BLAS API and kernels. llama.cpp links hipblas for matrix operations.
      #
      # rocmPackages.rocwmma:
      #   Header-only cooperative matrix library. Required for
      #   -DGGML_HIP_ROCWMMA_FATTN=ON (Flash Attention on RDNA3+/RDNA4).
      #   Meaningful throughput gain on gfx1201 — strongly recommended.
      #
      ++ lib.optionals cfg.enableRocm (with pkgs.rocmPackages; [
        llvm.clang  # HIP compiler (clang++ with AMDGCN backend)
        clr         # HIP/OpenCL runtime + headers (dev headers included)
        hipblas     # HIP BLAS API
        rocblas     # BLAS kernels
        rocwmma     # Flash Attention headers (RDNA4 cooperative matrix)
        rocminfo    # Verify ISA detection: `rocminfo | grep gfx`
        rocm-smi    # Runtime metrics during build smoke tests
      ])

      # ── Vulkan development stack ────────────────────────────────────────────
      #
      # vulkan-headers:
      #   Vulkan C headers (vulkan/vulkan.h). Required to compile ggml-vulkan.cpp.
      #
      # vulkan-loader:
      #   Vulkan ICD loader (libvulkan.so). Link-time and runtime dependency.
      #   cmake's FindVulkan locates this via pkg-config.
      #
      # shaderc:
      #   Provides glslc — the GLSL-to-SPIR-V compiler. llama.cpp's Vulkan
      #   backend compiles GLSL shaders to SPIR-V at CMake configure time via
      #   find_program(GLSLC glslc). Without glslc, cmake configure fails.
      #
      # glslang:
      #   Provides glslangValidator — alternative GLSL compiler. llama.cpp
      #   can use either; glslc is preferred. Including both ensures cmake
      #   finds a working shader compiler regardless of search order.
      #
      ++ lib.optionals cfg.enableVulkan [
        pkgs.vulkan-headers
        pkgs.vulkan-loader
        pkgs.shaderc   # provides glslc
        pkgs.glslang   # provides glslangValidator
      ];

    # ── Environment variables ─────────────────────────────────────────────────
    #
    # Set system-wide so they are present in any shell session, not just
    # inside a nix devShell. This makes ad-hoc cmake invocations work correctly.
    #
    environment.sessionVariables = lib.mkIf cfg.enableRocm {
      # HIP compiler path for cmake's HIP detection.
      HIPCXX    = "${pkgs.rocmPackages.llvm.clang}/bin/clang++";
      HIP_PATH  = "${pkgs.rocmPackages.clr}";
      ROCM_PATH = "${pkgs.rocmPackages.clr}";

      # Default GPU target for builds that do not set GPU_TARGETS explicitly.
      GPU_TARGETS    = "gfx1201";
      AMDGPU_TARGETS = "gfx1201";
    };
  };
}
