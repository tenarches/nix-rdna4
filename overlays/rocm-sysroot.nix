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
#                            and rocBLAS/hipBLAS. llvm/ points to the ROCm
#                            clang (bin/clang++, bin/amdgpu-arch).
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
# The rdna4-rocm NixOS module uses rocmSysroot for /opt/rocm when this
# overlay is applied. The devShells.hip shell exports hipEnv.
#
final: prev:
let
  rocm = final.rocmPackages;

  gpuTargets = [ "gfx1201" ];

  rocmSysroot = final.symlinkJoin {
    name = "rocm-sysroot-${rocm.clr.version}";

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
    ];

    # /opt/rocm/llvm must be the ROCm clang. clr ships its own llvm entry.
    # Replace it so that llvm/bin/clang++ and llvm/bin/amdgpu-arch resolve
    # to rocmPackages.llvm.clang.
    postBuild = ''
      rm -rf "$out/llvm"
      ln -s ${rocm.llvm.clang} "$out/llvm"
    '';

    passthru = {
      rocmVersion = rocm.clr.version;
      clang = rocm.llvm.clang;
    };

    meta = {
      description = "ROCm ${rocm.clr.version} sysroot in /opt/rocm shape (no ISA override)";
      platforms = [ "x86_64-linux" ];
    };
  };

  mkHipEnv =
    { gpuTargets ? [ "gfx1201" ] }:
    let
      targets = final.lib.concatStringsSep ";" gpuTargets;
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
    inherit rocmSysroot mkHipEnv gpuTargets;
    hipEnv = mkHipEnv { inherit gpuTargets; };
  };
}
