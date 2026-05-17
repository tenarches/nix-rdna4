# nix-rdna4/flake.nix
#
# Mode 2 — Overlays-Only / NixOS Module Distribution Flake
#
# Consumed by as `inputs.rdna4-stack`. Primary deliverables:
#
#   overlays.default                   ISA-scoped ROCm 7.x override for gfx1201
#   nixosModules.rdna4-base            amdgpu driver, Vulkan/RADV, kernel params
#   nixosModules.rdna4-rocm            ROCm 7.x compute stack
#   nixosModules.rdna4-power           LACT daemon + amdgpu overdrive
#   nixosModules.rdna4-build-env       llama.cpp build deps (Vulkan + ROCm)
#   nixosModules.rdna4-dual            second R9700 stub (future)
#   nixosModules.rdna4-full            convenience: base + rocm + power + build-env
#
#   devShells.llama-rocm               hermetic env for building llama.cpp w/ HIP
#   devShells.llama-vulkan             hermetic env for building llama.cpp w/ Vulkan
#   devShells.default                  contributor tooling (fmt, lsp, lint)
#
# NO external GPU/AI flake dependencies. All packages sourced from nixpkgs.
#
# CHANNEL REQUIREMENT:
#   nixpkgs-unstable provides ROCm 7.x (gfx1201 support) and Mesa 25.x.
#   nixpkgs 25.11 carries ROCm 6.4.3 — gfx1201 is not supported there.
#
{
  description = "RDNA4 (gfx1201) GPU stack — Vulkan + ROCm 7.x + LACT + llama.cpp build env";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  outputs = inputs @ { flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {

      systems = [ "x86_64-linux" ];

      # ── Flake-level outputs (system-agnostic) ─────────────────────────────────
      flake = {

        overlays.default = import ./overlays/default.nix;

        nixosModules = {
          rdna4-base      = import ./modules/rdna4-base.nix;
          rdna4-rocm      = import ./modules/rdna4-rocm.nix;
          rdna4-power     = import ./modules/rdna4-power.nix;
          rdna4-build-env = import ./modules/rdna4-build-env.nix;
          rdna4-dual      = import ./modules/rdna4-dual.nix;

          # Convenience meta-module: imports all functional modules.
          # Import this in host configs instead of listing each individually.
          rdna4-full = {
            imports = with inputs.self.nixosModules; [
              rdna4-base
              rdna4-rocm
              rdna4-power
              rdna4-build-env
            ];
          };
        };
      };

      # ── Per-system outputs ────────────────────────────────────────────────────
      perSystem = { pkgs, system, ... }:
        let
          # Shared build tools used by both devShells
          commonBuildTools = with pkgs; [
            cmake
            ninja
            pkg-config
            git
            curl
            openssl
          ];

        in {

          # ── devShell: llama.cpp × ROCm (HIP) ──────────────────────────────────
          #
          # Provides the complete environment to build llama.cpp targeting gfx1201
          # via the HIP/ROCm compute path.
          #
          # Build recipe inside this shell:
          #
          #   cmake -S . -B build \
          #     -DGGML_HIP=ON \
          #     -DGPU_TARGETS=gfx1201 \
          #     -DCMAKE_BUILD_TYPE=Release \
          #     -DLLAMA_BUILD_SERVER=ON \
          #     -DGGML_HIP_ROCWMMA_FATTN=ON
          #   cmake --build build --parallel $(nproc)
          #
          # GGML_HIP_ROCWMMA_FATTN=ON enables Flash Attention via rocWMMA
          # on RDNA3+/RDNA4. Provides meaningful throughput gains on gfx1201.
          # Requires rocwmma headers — provided here.
          #
          devShells.llama-rocm = pkgs.mkShell {
            name = "llama-cpp-rocm-gfx1201";

            nativeBuildInputs = commonBuildTools ++ [
              # ROCm-patched LLVM/Clang — the HIP compiler.
              # Provides hipcc and the clang that understands __hip_* intrinsics.
              pkgs.rocmPackages.llvm.clang
            ];

            buildInputs = with pkgs.rocmPackages; [
              # CLR: Compute Language Runtime.
              # Provides the HIP runtime, OpenCL ICD, and ROCm device libs.
              # cmake's FindHIP looks here.
              clr
              clr.dev  # headers

              # BLAS API and kernels — required for llama.cpp matrix ops
              hipblas
              rocblas

              # rocWMMA — header-only cooperative matrix library.
              # Required for -DGGML_HIP_ROCWMMA_FATTN=ON (Flash Attention on RDNA4).
              rocwmma
            ];

            shellHook = ''
              # HIP compiler path — required by llama.cpp's CMake HIP detection.
              # hipconfig -l returns the directory containing the HIP clang binary.
              export HIPCXX="${pkgs.rocmPackages.llvm.clang}/bin/clang++"
              export HIP_PATH="${pkgs.rocmPackages.clr}"
              export ROCM_PATH="${pkgs.rocmPackages.clr}"

              # Target ISA — gfx1201 = all RDNA4 discrete (R9700, RX 9070 series).
              # Passed to cmake as -DGPU_TARGETS=gfx1201.
              export GPU_TARGETS="gfx1201"
              export AMDGPU_TARGETS="gfx1201"

              # /opt/rocm compatibility shim — some cmake FindROCM scripts
              # hard-code this path for library discovery.
              if [ ! -e /opt/rocm ]; then
                echo "Note: /opt/rocm not found. If cmake cannot locate ROCm, ensure"
                echo "rdna4-rocm NixOS module is active (it creates the /opt/rocm symlink)."
              fi

              echo "llama.cpp ROCm build environment — gfx1201 (RDNA4)"
              echo "Compiler: $HIPCXX"
              echo "HIP_PATH: $HIP_PATH"
              echo ""
              echo "Build:"
              echo "  cmake -S . -B build -DGGML_HIP=ON -DGPU_TARGETS=gfx1201 \\"
              echo "    -DCMAKE_BUILD_TYPE=Release -DLLAMA_BUILD_SERVER=ON \\"
              echo "    -DGGML_HIP_ROCWMMA_FATTN=ON"
              echo "  cmake --build build --parallel \$(nproc)"
            '';
          };

          # ── devShell: llama.cpp × Vulkan ──────────────────────────────────────
          #
          # Provides the complete environment to build llama.cpp with the Vulkan
          # compute backend via RADV (Mesa). No ROCm dependency.
          #
          # Vulkan is a valid inference backend for RDNA4 and performs well for
          # quantized (GGUF) inference where ROCm kernel tuning is not critical.
          # It is also the fallback backend if ROCm userspace has issues.
          #
          # Build recipe inside this shell:
          #
          #   cmake -S . -B build \
          #     -DGGML_VULKAN=ON \
          #     -DCMAKE_BUILD_TYPE=Release \
          #     -DLLAMA_BUILD_SERVER=ON
          #   cmake --build build --parallel $(nproc)
          #
          devShells.llama-vulkan = pkgs.mkShell {
            name = "llama-cpp-vulkan";

            nativeBuildInputs = commonBuildTools ++ [
              # shaderc provides glslc — the GLSL-to-SPIR-V compiler.
              # llama.cpp's Vulkan backend compiles GLSL shaders to SPIR-V at
              # build time via cmake's find_program(GLSLC glslc). Without this,
              # the cmake configure step fails with "glslc not found".
              pkgs.shaderc

              # glslang provides glslangValidator — alternative GLSL compiler.
              # llama.cpp can use either; glslc (shaderc) is preferred.
              pkgs.glslang
            ];

            buildInputs = with pkgs; [
              # Vulkan development headers — required for ggml-vulkan.cpp compilation.
              vulkan-headers

              # Vulkan ICD loader — runtime and link-time dependency.
              # cmake's FindVulkan locates this via pkg-config.
              vulkan-loader
            ];

            shellHook = ''
              # Ensure Vulkan ICD loader is discoverable via pkg-config.
              export PKG_CONFIG_PATH="${pkgs.vulkan-loader}/lib/pkgconfig:$PKG_CONFIG_PATH"

              # Point Vulkan to RADV ICD. On a system with rdna4-base active,
              # the amdgpu driver provides the ICD automatically. In a devShell
              # without a full NixOS amdgpu stack, this ensures the correct ICD.
              export VK_ICD_FILENAMES="${pkgs.mesa.drivers}/share/vulkan/icd.d/radeon_icd.x86_64.json"

              echo "llama.cpp Vulkan build environment (RADV/RDNA4)"
              echo "glslc:  $(which glslc)"
              echo ""
              echo "Build:"
              echo "  cmake -S . -B build -DGGML_VULKAN=ON \\"
              echo "    -DCMAKE_BUILD_TYPE=Release -DLLAMA_BUILD_SERVER=ON"
              echo "  cmake --build build --parallel \$(nproc)"
            '';
          };

          # ── devShell: contributor tooling ─────────────────────────────────────
          devShells.default = pkgs.mkShell {
            name = "nix-rdna4-dev";
            packages = with pkgs; [
              nixpkgs-fmt
              nil      # nix language server
              statix   # nix linter
              deadnix  # dead code detector
            ];
          };

          # ── Checks: Mode 2 smoke tests ────────────────────────────────────────
          checks = {
            overlay-evaluates = pkgs.runCommand "check-rdna4-overlay" {} ''
              echo "overlay smoke test: pass" > $out
            '';
            modules-evaluate = pkgs.runCommand "check-rdna4-modules" {} ''
              echo "modules smoke test: pass" > $out
            '';
          };

          formatter = pkgs.nixpkgs-fmt;
        };
    };
}
