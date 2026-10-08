# nix-rdna4/flake.nix
#
# Mode 2 — Overlays-Only / NixOS Module Distribution Flake
#
# Consumed by as `inputs.rdna4-stack`. Primary deliverables:
#
#   overlays.default                   ISA-scoped ROCm 7.x override for gfx1201
#   overlays.rocm-sysroot              cache-friendly ROCm sysroot + HIP env (pkgs.rdna4)
#   nixosModules.rdna4-base            amdgpu driver, Vulkan/RADV, kernel params
#   nixosModules.rdna4-rocm            ROCm 7.x compute stack
#   nixosModules.rdna4-power           LACT daemon + amdgpu overdrive
#   nixosModules.rdna4-build-env       llama.cpp build deps (Vulkan + ROCm)
#   nixosModules.rdna4-dual            second R9700 stub (future)
#   nixosModules.rdna4-limits          memlock/nofile limits for render+video, vm.max_map_count
#   nixosModules.rdna4-full            convenience: base + rocm + power + build-env + limits
#
#   devShells.llama-rocm               hermetic env for building llama.cpp w/ HIP
#   devShells.llama-vulkan             hermetic env for building llama.cpp w/ Vulkan
#   devShells.hip                      generic HIP CMake env over the ROCm sysroot
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

        # Cache-friendly. No clr override. Adds pkgs.rdna4.{rocmSysroot,hipEnv}.
        overlays.rocm-sysroot = import ./overlays/rocm-sysroot.nix;

        nixosModules = {
          rdna4-base      = import ./modules/rdna4-base.nix;
          rdna4-rocm      = import ./modules/rdna4-rocm.nix;
          rdna4-power     = import ./modules/rdna4-power.nix;
          rdna4-build-env = import ./modules/rdna4-build-env.nix;
          rdna4-dual      = import ./modules/rdna4-dual.nix;
          # A path, not an import. The module system dedups a path module, so
          # a host can import rdna4-full and rdna4-limits together.
          rdna4-limits    = ./modules/rdna4-limits.nix;

          # Convenience meta-module: imports all functional modules.
          # Import this in host configs instead of listing each individually.
          rdna4-full = {
            imports = with inputs.self.nixosModules; [
              rdna4-base
              rdna4-rocm
              rdna4-power
              rdna4-build-env
              rdna4-limits
            ];
          };
        };
      };

      # ── Per-system outputs ────────────────────────────────────────────────────
      perSystem = { pkgs, system, ... }:
        let
          # pkgs plus the rocm-sysroot overlay. Only pkgs.rdna4 is new.
          # The other devShells and checks keep plain pkgs.
          pkgsHip = pkgs.extend inputs.self.overlays.rocm-sysroot;
          inherit (pkgsHip.rdna4) rocmSysroot hipEnv;

          # Evaluate a minimal NixOS system with the given modules.
          # Used only by eval-level checks. Nothing is built.
          evalNixos = modules: inputs.nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              {
                boot.loader.grub.enable = false;
                fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
                system.stateVersion = "25.11";
              }
            ] ++ modules;
          };

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
              export VK_ICD_FILENAMES="${pkgs.mesa}/share/vulkan/icd.d/radeon_icd.x86_64.json"

              echo "llama.cpp Vulkan build environment (RADV/RDNA4)"
              echo "glslc:  $(which glslc)"
              echo ""
              echo "Build:"
              echo "  cmake -S . -B build -DGGML_VULKAN=ON \\"
              echo "    -DCMAKE_BUILD_TYPE=Release -DLLAMA_BUILD_SERVER=ON"
              echo "  cmake --build build --parallel \$(nproc)"
            '';
          };

          # ── devShell: generic HIP CMake project ─────────────────────────────────
          #
          # Uses the cache-friendly rocm-sysroot overlay. No clr rebuild.
          # Exports every variable in pkgs.rdna4.hipEnv, so that a HIP CMake
          # project finds the compiler, the runtime and the device libraries
          # without /opt/rocm on the host.
          #
          # Build recipe inside this shell:
          #
          #   cmake -S . -B build -G Ninja \
          #     -DCMAKE_BUILD_TYPE=Release \
          #     -DCMAKE_HIP_ARCHITECTURES="$GPU_TARGETS"
          #   cmake --build build
          #
          # nix-radiance reuses the same pkgs.rdna4.hipEnv attrset in its
          # devenv module.
          #
          devShells.hip = pkgsHip.mkShell ({
            name = "hip-rocm-${rocmSysroot.rocmVersion}-gfx1201";

            nativeBuildInputs = with pkgsHip; [
              cmake
              ninja
              pkg-config
              rocmSysroot
            ];

            shellHook = ''
              echo "HIP build environment: ROCm ${rocmSysroot.rocmVersion}, targets $GPU_TARGETS"
              echo "ROCM_PATH:  $ROCM_PATH"
              echo "HIPCXX:     $HIPCXX"
            '';
          } // hipEnv);

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

            # The sysroot builds and holds the files a HIP build needs.
            # This realises the ROCm closure (several GB, all from the cache).
            rocm-sysroot = pkgs.runCommand "check-rdna4-rocm-sysroot" {} ''
              set -eu
              s=${rocmSysroot}
              for f in bin/hipcc lib/libhsa-runtime64.so amdgcn/bitcode \
                       llvm/bin/clang++ llvm/bin/amdgpu-arch \
                       lib/libamdhip64.so lib/librocblas.so lib/libhipblas.so; do
                test -e "$s/$f" || { echo "missing: $f" >&2; exit 1; }
              done
              test -n "$(ls "$s/amdgcn/bitcode")"
              echo "rocm-sysroot ${rocmSysroot.rocmVersion}: pass" > $out
            '';

            # Eval-only checks. They read NixOS config values and build
            # nothing from ROCm.
            module-options = let
              inherit (inputs.nixpkgs) lib;
              self' = inputs.self.nixosModules;
              discard = builtins.unsafeDiscardStringContext;

              full = (evalNixos [
                self'.rdna4-full
                self'.rdna4-dual
                self'.rdna4-limits  # second import: must dedup
                { rdna4.dualGpu.enable = true; rdna4.limits.enable = true; }
              ]).config;

              withSysroot = (evalNixos [
                self'.rdna4-rocm
                { nixpkgs.overlays = [ inputs.self.overlays.rocm-sysroot ]; }
              ]).config;

              withoutSysroot = (evalNixos [ self'.rdna4-rocm ]).config;

              optRocm = c: discard (lib.concatStringsSep " "
                (lib.filter (r: lib.hasPrefix "L+ /opt/rocm " r) c.systemd.tmpfiles.rules));

              limitFor = dom: item: type:
                map (l: toString l.value) (lib.filter
                  (l: l.domain == dom && l.item == item && l.type == type)
                  full.security.pam.loginLimits);

              checks' = {
                "dual: HCC_AMDGPU_TARGET is gfx1201" =
                  full.environment.sessionVariables.HCC_AMDGPU_TARGET == "gfx1201";
                "dual: ROCR_VISIBLE_DEVICES is 0,1" =
                  full.environment.sessionVariables.ROCR_VISIBLE_DEVICES == "0,1";
                "limits: @render memlock soft unlimited" =
                  limitFor "@render" "memlock" "soft" == [ "unlimited" ];
                "limits: @render memlock hard unlimited" =
                  limitFor "@render" "memlock" "hard" == [ "unlimited" ];
                "limits: @video memlock hard unlimited" =
                  limitFor "@video" "memlock" "hard" == [ "unlimited" ];
                "limits: @render nofile hard 65536" =
                  limitFor "@render" "nofile" "hard" == [ "65536" ];
                "limits: vm.max_map_count set" =
                  full.boot.kernel.sysctl."vm.max_map_count" == 1048576;
                "rocm: /opt/rocm uses the sysroot when the overlay is applied" =
                  lib.hasInfix "-rocm-sysroot-" (optRocm withSysroot);
                "rocm: /opt/rocm keeps the old join without the overlay" =
                  lib.hasInfix "-rocm-combined-gfx1201" (optRocm withoutSysroot);
              };
              failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks');
            in
              assert lib.assertMsg (failed == [ ])
                "module-options failed: ${lib.concatStringsSep "; " failed}";
              pkgs.runCommand "check-rdna4-module-options" {} ''
                echo "module-options: ${toString (lib.length (lib.attrNames checks'))} assertions pass" > $out
              '';
          };

          formatter = pkgs.nixpkgs-fmt;
        };
    };
}
