# overlays/rocm-sysroot.nix
#
# Cache-friendly ROCm sysroot overlay.
#
# This overlay does NOT override clr or any other rocmPackages member.
# All inputs come from cache.nixos.org as they are. Only the small
# symlinkJoin below is built locally.
#
# It adds one attribute: pkgs.rdna4.
#
#   pkgs.rdna4.rocmSysroot   A symlinkJoin in /opt/rocm shape. It holds the
#                            HIP compiler, the runtime, the device libraries
#                            and rocBLAS, hipBLAS and hipblas-common. llvm/
#                            points to the ROCm clang (bin/clang++, bin/amdgpu-arch).
#                            passthru.rocmVersion gives the ROCm version.
#
#   pkgs.rdna4.hipEnv        An attrset of environment variables for a HIP
#                            CMake build against rocmSysroot, for gfx1201.
#
#   pkgs.rdna4.mkHipEnv      A function { gpuTargets ? [ "gfx1201" ] } -> hipEnv.
#                            Use it for other targets, for example
#                            [ "gfx1200" "gfx1201" ].
#
#   pkgs.rdna4.gpuTargets    The default target list: [ "gfx1201" ].
#
#   pkgs.rdna4.mkRocmSysroot The sysroot builder. The flake checks use it
#                            with small stand-in packages.
#
# SETUP HOOK:
#   The sysroot does not keep the clr setup hook. Its own hook sets the
#   hipEnv variables to sysroot values, but only if they are empty. Thus a
#   shell or derivation that sets hipEnv (or mkHipEnv) keeps its values.
#
# The rdna4-rocm NixOS module uses rocmSysroot for /opt/rocm when this
# overlay is applied. The devShells.hip shell exports hipEnv.
#
final: prev:
let
  rocm = final.rocmPackages;

  gpuTargets = [ "gfx1201" ];

  # Build a sysroot from a list of paths. Exposed as pkgs.rdna4.mkRocmSysroot
  # so that the flake checks can test the setup hook with small stand-in
  # packages. Consumers use pkgs.rdna4.rocmSysroot.
  mkRocmSysroot =
    { name
    , version
    , paths
    , clang
    , gpuTargets ? [ "gfx1201" ]
    }:
    final.symlinkJoin {
      inherit name paths;

      # 1. /opt/rocm/llvm must be the ROCm clang. clr ships its own llvm
      #    entry. Replace it so that llvm/bin/clang++ and llvm/bin/amdgpu-arch
      #    resolve to the given clang.
      #
      # 2. Replace nix-support. symlinkJoin takes nix-support/setup-hook and
      #    nix-support/propagated-build-inputs from the first path (clr).
      #    The clr hook exports HIP_PATH=<clr> and more. It would override
      #    hipEnv in every shell or derivation that has the sysroot as an
      #    input. The clr propagated-build-inputs file also hides the
      #    hipblas one. All of those paths are in the join, so the sysroot
      #    propagates nothing.
      #
      #    The new setup hook sets each hipEnv variable to the sysroot value
      #    ONLY IF the variable is empty. Thus hipEnv (or mkHipEnv) attributes
      #    on the shell or derivation always win.
      postBuild = ''
        rm -rf "$out/llvm"
        ln -s ${clang} "$out/llvm"

        rm -rf "$out/nix-support"
        mkdir -p "$out/nix-support"
        cat > "$out/nix-support/setup-hook" <<EOF
        # rdna4 rocm-sysroot setup hook. Defaults only. It never overrides.
        : "\''${ROCM_PATH:=$out}"; export ROCM_PATH
        : "\''${HIP_PATH:=$out}"; export HIP_PATH
        : "\''${HIP_DEVICE_LIB_PATH:=$out/amdgcn/bitcode}"; export HIP_DEVICE_LIB_PATH
        : "\''${HIPCXX:=$out/llvm/bin/clang++}"; export HIPCXX
        : "\''${CMAKE_HIP_COMPILER:=$out/llvm/bin/clang++}"; export CMAKE_HIP_COMPILER
        : "\''${CMAKE_HIP_COMPILER_ROCM_ROOT:=$out}"; export CMAKE_HIP_COMPILER_ROCM_ROOT
        : "\''${GPU_TARGETS:=${targetsString gpuTargets}}"; export GPU_TARGETS
        : "\''${AMDGPU_TARGETS:=${targetsString gpuTargets}}"; export AMDGPU_TARGETS
        EOF
      '';

      passthru = {
        rocmVersion = version;
        inherit clang;
      };

      meta = {
        description = "ROCm ${version} sysroot in /opt/rocm shape (no ISA override)";
        platforms = [ "x86_64-linux" ];
      };
    };

  targetsString = final.lib.concatStringsSep ";";

  rocmSysroot = mkRocmSysroot {
    name = "rocm-sysroot-${rocm.clr.version}";
    version = rocm.clr.version;
    clang = rocm.llvm.clang;
    inherit gpuTargets;

    # Order is important. symlinkJoin keeps the first path that supplies a
    # file. clr comes first, so bin/hipcc is the clr wrapper. That wrapper
    # sets HIP_PATH, HSA_PATH and DEVICE_LIB_PATH for the Nix store paths.
    paths = with rocm; [
      clr              # HIP runtime, hipcc wrapper, hipconfig, OpenCL ICD
      hipcc            # hipcc perl driver and hipvars.pm
      rocm-runtime     # HSA runtime: lib/libhsa-runtime64.so
      rocm-device-libs # amdgcn/bitcode
      rocm-comgr       # code object manager, used by hiprtc
      rocminfo         # rocminfo, rocm_agent_enumerator
      rocm-smi         # System Management Interface
      rocm-core        # .info/version
      rocblas          # BLAS kernels
      hipblas          # HIP BLAS API over rocBLAS
      hipblas-common   # hipblas-common/hipblas-common.h, included by hipblas.h
    ];
  };

  mkHipEnv =
    { gpuTargets ? [ "gfx1201" ] }:
    let
      targets = targetsString gpuTargets;
      clangxx = "${rocmSysroot}/llvm/bin/clang++";
    in
    {
      ROCM_PATH = "${rocmSysroot}";
      HIP_PATH = "${rocmSysroot}";
      HIP_DEVICE_LIB_PATH = "${rocmSysroot}/amdgcn/bitcode";
      HIPCXX = clangxx;
      CMAKE_HIP_COMPILER = clangxx;
      CMAKE_HIP_COMPILER_ROCM_ROOT = "${rocmSysroot}";
      GPU_TARGETS = targets;
      AMDGPU_TARGETS = targets;
    };
in
{
  rdna4 = (prev.rdna4 or { }) // {
    inherit rocmSysroot mkRocmSysroot mkHipEnv gpuTargets;
    hipEnv = mkHipEnv { inherit gpuTargets; };
  };
}
