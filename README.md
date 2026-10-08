# nix-rdna4

A Nix flake providing the RDNA4 GPU stack for NixOS hosts.

Covers the full amdgpu driver configuration, ROCm 7.x compute, Vulkan via
RADV, LACT power and fan control, and a complete build environment for
compiling llama.cpp against either the ROCm (HIP) or Vulkan backend.

**Target hardware:** AMD RDNA4 discrete GPUs — ISA `gfx1201`. This includes
the Radeon AI PRO R9700, RX 9070 XT, RX 9070, and RX 9060 XT series.

---

## Contents

- [Design: why this flake is structured the way it is](#design-why-this-flake-is-structured-the-way-it-is)
- [Version pinning policy](#version-pinning-policy)
- [Channel requirement](#channel-requirement)
- [Consuming as a NixOS module](#consuming-as-a-nixos-module)
- [Using the devShells to build llama.cpp](#using-the-devshells-to-build-llamacpp)
- [Module reference](#module-reference)
- [ISA overlay](#isa-overlay)
- [ROCm sysroot overlay](#rocm-sysroot-overlay)
- [Consumers](#consumers)
- [Post-deploy verification](#post-deploy-verification)
- [Invariants](#invariants)

---

## Design: why this flake is structured the way it is

Most Nix flakes are *sealed*: they define `packages.*` or `apps.*` outputs,
and you consume them with `nix build` or `nix run`. That model is the right
choice when the flake *owns* a deliverable — a program, a container image, a
development environment.

This flake does not own a deliverable. It owns **hardware configuration**. Its
job is to augment a NixOS system that already exists in another repository, not
to stand alone as a runnable artifact. That distinction drives every structural
decision here.

### The problem with sealing hardware configuration into packages

A sealed flake carries its own `nixpkgs` evaluation closure. If this flake
exposed `packages.x86_64-linux.rocm-stack`, a consuming system would have two
evaluation paths for `rocmPackages`: one from the system's own nixpkgs, and
one from this flake's closure. They would diverge over time as `nix flake
update` is run independently in each repository. The result is subtle
breakage — mismatched ABI versions between the ROCm runtime the system loaded
and the headers a build was compiled against.

Hardware configuration modules need to participate in *the consumer's system
closure*, not run alongside it. The correct Nix primitive for this is
`nixosModules`, not `packages`.

### The overlays-only distribution pattern

This flake follows the same distribution model as `oxalica/rust-overlay` and
`nix-community/emacs-overlay`: it exposes `overlays.default` and
`nixosModules.*` as its primary surface. The consumer imports these into their
own nixpkgs evaluation, and everything resolves inside a single closure.

The practical consequence:

```
nix build   ← does not apply to this flake's modules (by design)
nix run     ← does not apply
nix develop ← works for devShells (see below)
nix flake check ← runs smoke tests against overlays and modules
```

The absence of `packages.*` is not a limitation. It is the correct shape for
a library of hardware configuration. Trying to expose packages here would mean
either duplicating the system's nixpkgs instance or introducing a runtime
dependency on a second evaluation closure — both are wrong.

### Where devShells fit in

The `devShells.llama-rocm` and `devShells.llama-vulkan` outputs are the one
place where self-contained, runnable outputs are appropriate. A
development shell *is* a sealed deliverable — it provides a reproducible
compiler and library environment for a specific build task. The consumer
enters it from any directory containing a llama.cpp source tree. It does not
need to participate in a NixOS system closure to do its job.

---

## Version pinning policy

**Vulkan (Mesa/RADV) and ROCm are not pinned to specific version numbers in
this flake's source code.** They track `nixos-unstable`.

This is a deliberate choice, not an oversight.

Pinning to a hard-coded nixpkgs commit in the source would require manual
updates every time a ROCm bug fix or Mesa RDNA4 improvement lands in nixpkgs.
Given that ROCm on RDNA4 is still receiving active optimization work, a fixed
pin would frequently mean running a version with known regressions because no
one updated the string.

The `flake.lock` file is the version pin mechanism. Once you run
`nix flake update` and commit the result, the exact nixpkgs commit — and
therefore the exact ROCm and Mesa versions — is locked and reproducible for
every subsequent build from that revision of the flake.

**To inspect what you are running:**

```bash
# Show the locked nixpkgs commit and its date
nix flake metadata github:tenarches/nix-rdna4

# Show the ROCm version provided by your locked closure
nix eval github:tenarches/nix-rdna4#legacyPackages.x86_64-linux.rocmPackages.rocm-core.version

# Show the Mesa version
nix eval github:tenarches/nix-rdna4#legacyPackages.x86_64-linux.mesa.version
```

Or from inside a consuming nix project where the input is locked:

```bash
nix eval .#inputs.rdna4-stack.inputs.nixpkgs.rev
```

**Minimum supported ROCm version:** 7.x. The `gfx1201` ISA target is not
present in ROCm 6.x. If your `flake.lock` resolves to a nixpkgs commit that
carries ROCm 6.x (i.e. a commit predating the ROCm 7.x landing in nixpkgs
unstable in early 2026), this flake will produce a non-functional ROCm stack.
Run `nix flake update` to advance past that point.

---

## Channel requirement

This flake requires `nixpkgs-unstable`. Stable channels do not carry ROCm 7.x:

| Channel | ROCm version | gfx1201 support |
|---|---|---|
| nixpkgs 25.11 | 6.4.3 | No |
| nixpkgs-unstable (26.05+) | 7.x | Yes |

---

## Consuming as a NixOS module

### 1. Add the input to your flake

```nix
# your-system-flake/flake.nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  rdna4-stack = {
    url = "github:tenarches/nix-rdna4";

    # If your system flake already tracks nixos-unstable, follow its
    # nixpkgs to ensure both flakes evaluate against the same closure.
    # This avoids duplicate evaluation and keeps ROCm versions consistent.
    inputs.nixpkgs.follows = "nixpkgs";

    # If your system flake tracks a stable channel, omit .follows.
    # rdna4-stack will carry its own unstable closure. Safe, but adds
    # a second nixpkgs evaluation (~300MB overhead at eval time).
  };
};
```

### 2. Import the modules in a NixOS host configuration

The convenience module `rdna4-full` imports `rdna4-base`, `rdna4-rocm`,
`rdna4-power`, `rdna4-build-env`, and `rdna4-limits` in one shot:

```nix
# hosts/your-rdna4-host/default.nix or a hardware profile
{ inputs, ... }:
{
  imports = [
    inputs.rdna4-stack.nixosModules.rdna4-full
  ];

  # Enable the build environment with both backends active
  rdna4.buildEnv = {
    enable       = true;
    enableRocm   = true;
    enableVulkan = true;
  };
}
```

Or import modules individually for finer control:

```nix
imports = [
  inputs.rdna4-stack.nixosModules.rdna4-base       # Required: driver and Vulkan
  inputs.rdna4-stack.nixosModules.rdna4-rocm        # ROCm compute stack
  inputs.rdna4-stack.nixosModules.rdna4-power       # LACT + overdrive
  inputs.rdna4-stack.nixosModules.rdna4-build-env   # llama.cpp build deps
];
```

`{ inputs, ... }:` requires `specialArgs = { inherit inputs; }` in your
`nixosSystem` call, which is standard practice when consuming external flake
modules.

### 3. Passing `inputs` through `specialArgs`

```nix
nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  specialArgs = { inherit inputs; };
  modules = [ ./hosts/petunia/default.nix ];
}
```

---

## Using the devShells to build llama.cpp

These shells provide hermetic, fully configured build environments. Enter them
from a directory containing a cloned llama.cpp source tree.

### ROCm / HIP backend

Targets `gfx1201`. Enables Flash Attention via rocWMMA (`-DGGML_HIP_ROCWMMA_FATTN=ON`),
which provides meaningful throughput gains on RDNA4 cooperative matrix hardware.

```bash
nix develop github:tenarches/nix-rdna4#llama-rocm
```

Inside the shell, `HIPCXX`, `HIP_PATH`, `ROCM_PATH`, `GPU_TARGETS`, and
`AMDGPU_TARGETS` are all pre-configured. Build with:

```bash
cmake -S . -B build \
  -DGGML_HIP=ON \
  -DGPU_TARGETS=gfx1201 \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_SERVER=ON \
  -DGGML_HIP_ROCWMMA_FATTN=ON
cmake --build build --parallel $(nproc)
```

### Vulkan backend

Targets RADV. No ROCm dependency. Useful for quick validation builds or as a
fallback when the ROCm compute path has issues.

```bash
nix develop github:tenarches/nix-rdna4#llama-vulkan
```

Inside the shell, `glslc`, `glslangValidator`, `vulkan-headers`, and
`vulkan-loader` are all present. `VK_ICD_FILENAMES` is pre-pointed at the
RADV ICD. Build with:

```bash
cmake -S . -B build \
  -DGGML_VULKAN=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_SERVER=ON
cmake --build build --parallel $(nproc)
```

### Generic HIP CMake project (`devShells.hip`)

`devShells.hip` is a HIP build shell for any CMake project. It does not
contain llama.cpp specifics. It uses the [ROCm sysroot overlay](#rocm-sysroot-overlay),
so it does not rebuild `clr`.

```bash
nix develop github:tenarches/nix-rdna4#hip
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_HIP_ARCHITECTURES="$GPU_TARGETS"
cmake --build build
```

The shell contains `cmake`, `ninja`, `pkg-config` and the sysroot. It exports
every variable in `pkgs.rdna4.hipEnv`:

| Variable | Value |
|---|---|
| `ROCM_PATH`, `HIP_PATH`, `CMAKE_HIP_COMPILER_ROCM_ROOT` | the sysroot |
| `HIP_DEVICE_LIB_PATH` | `<sysroot>/amdgcn/bitcode` |
| `HIPCXX`, `CMAKE_HIP_COMPILER` | `<sysroot>/llvm/bin/clang++` |
| `GPU_TARGETS`, `AMDGPU_TARGETS` | `gfx1201` |

The shell does not need `/opt/rocm` on the host.

### Without entering a devShell

If `rdna4.buildEnv.enable = true` is set in your NixOS config, the same
compiler toolchain and libraries are installed system-wide. `HIPCXX`,
`HIP_PATH`, `GPU_TARGETS`, and `AMDGPU_TARGETS` are exported in your login
shell. The cmake invocations above work in any terminal without `nix develop`.

---

## Module reference

### `rdna4-base`

Core driver and graphics configuration. **Required by all other modules.**

- Sets `services.xserver.videoDrivers = ["amdgpu"]`
- Enables `hardware.amdgpu.initrd.enable` (early KMS load)
- Sets kernel parameters: `amdgpu.gpu_recovery=1`,
  `amdgpu.lockup_timeout=10000`, `iommu=pt`
- Configures `hardware.graphics` with 32-bit support and the ROCm OpenCL ICD
- Installs: `nvtopPackages.amd`, `amdgpu_top`, `vulkan-tools`, `clinfo`

No user-configurable options. If you need only Vulkan rendering with no ROCm
compute, importing this module alone is sufficient.

### `rdna4-rocm`

ROCm 7.x compute stack.

- Creates `/opt/rocm` via `systemd.tmpfiles` (required by HIP runtime and most
  ML frameworks for library discovery)
- Source of `/opt/rocm`: if the host applies `overlays.rocm-sysroot`,
  `/opt/rocm` is `pkgs.rdna4.rocmSysroot`. That sysroot also contains
  `hipcc`, `rocm-runtime`, `rocm-device-libs`, `rocm-comgr`, `rocm-core` and
  `llvm/` (the ROCm clang). Thus a generic HIP CMake project can build against
  `/opt/rocm`. If the host does not apply the overlay, `/opt/rocm` is the
  original `rocm-combined-gfx1201` join (`clr`, `rocblas`, `hipblas`,
  `rocminfo`, `rocm-smi`). That join serves llama.cpp only.
- Sets `ROCR_VISIBLE_DEVICES=0` and `HCC_AMDGPU_TARGET=gfx1201`
- Applies udev rules granting `render` group access to `/dev/kfd` and
  `/dev/dri/renderD*`
- Installs: `rocminfo`, `rocm-smi`

Depends on `rdna4-base`.

### `rdna4-power`

GPU power, thermal, and fan management.

- Enables `services.lact.enable` (LACT daemon for power limits, fan curves,
  OC/UV via the `lactd` systemd service)
- Enables `hardware.amdgpu.overdrive.enable` (sets
  `amdgpu.ppfeaturemask=0xffffffff`; required for the Overclock tab in LACT)
- Enables `services.lm_sensors` for board Super I/O fan reading
- Includes a commented udev rule for static power cap (alternative to LACT
  for headless nodes)

LACT's configuration is persisted at runtime to `/etc/lact/config.yaml`.
This file is intentionally not managed declaratively — GPU tuning parameters
are iterative and hardware-specific. Manage it as a host asset outside the
Nix store if you want to commit your tuning state.

### `rdna4-build-env`

Build dependencies for compiling llama.cpp from source.

Options:

| Option | Type | Default | Description |
|---|---|---|---|
| `rdna4.buildEnv.enable` | bool | false | Enable this module |
| `rdna4.buildEnv.enableRocm` | bool | true | ROCm compiler and HIP/BLAS libs |
| `rdna4.buildEnv.enableVulkan` | bool | true | Vulkan headers, loader, shader compiler |

ROCm packages installed when `enableRocm = true`:

| Package | Role |
|---|---|
| `rocmPackages.llvm.clang` | HIP compiler (ROCm-patched LLVM/Clang) |
| `rocmPackages.clr` + `clr.dev` | Compute Language Runtime + headers |
| `rocmPackages.hipblas` | HIP BLAS API |
| `rocmPackages.rocblas` | BLAS kernels |
| `rocmPackages.rocwmma` | Flash Attention headers (RDNA3+/RDNA4) |

Vulkan packages installed when `enableVulkan = true`:

| Package | Role |
|---|---|
| `vulkan-headers` | Vulkan C headers |
| `vulkan-loader` | Vulkan ICD loader |
| `shaderc` | `glslc` — GLSL to SPIR-V compiler |
| `glslang` | `glslangValidator` — alternative GLSL compiler |

Common tools installed regardless of backend selection:
`cmake`, `ninja`, `pkg-config`, `git`, `curl`, `openssl`, `ccache`

### `rdna4-dual`

Stub for a second R9700. Inert until enabled.

```nix
imports = [ inputs.rdna4-stack.nixosModules.rdna4-dual ];
rdna4.dualGpu.enable = true;
```

When enabled: sets `ROCR_VISIBLE_DEVICES=0,1`, `HCC_AMDGPU_TARGET=gfx1201`,
and adds `pcie_bus_config=performance` to kernel parameters.
`HCC_AMDGPU_TARGET` lists each ISA one time. Both cards are `gfx1201`, so the
value is `gfx1201`.

### `rdna4-limits`

Resource limits for GPU compute users. Inert until enabled.

```nix
imports = [ inputs.rdna4-stack.nixosModules.rdna4-limits ];  # or rdna4-full
rdna4.limits.enable = true;
```

HIP pins host memory for DMA and for peer-to-peer transfers between GPUs.
Pinned memory counts against `RLIMIT_MEMLOCK`. A limit of 8 MiB makes large
pinned buffers fail. This module removes that limit for GPU users.

| Option | Type | Default | Description |
|---|---|---|---|
| `rdna4.limits.enable` | bool | false | Enable this module |
| `rdna4.limits.groups` | list of str | `[ "render" "video" ]` | Groups that get the limits |
| `rdna4.limits.nofile` | positive int | 65536 | Soft and hard `nofile` |
| `rdna4.limits.maxMapCount` | positive int | 1048576 | `vm.max_map_count` sysctl |

When enabled:

- `security.pam.loginLimits` sets `memlock` to `unlimited` (soft and hard)
  and `nofile` to `rdna4.limits.nofile` (soft and hard) for each group.
- `boot.kernel.sysctl."vm.max_map_count"` is `rdna4.limits.maxMapCount`.
  NixOS sets the same value with `mkDefault` (priority 1000). This module sets
  it with `mkOverride 999`, so the value stays if the NixOS default changes.
  A plain host assignment (priority 100) wins over this module. A host value
  set with `lib.mkDefault` does not win. To change the value, set
  `rdna4.limits.maxMapCount`.

PAM limits apply to login sessions (console, ssh, su, sudo) and to the
processes they start. PAM limits do not apply to systemd services. For a GPU
service, set `LimitMEMLOCK = "infinity"` and `LimitNOFILE` in `serviceConfig`.

The kernel TTM layer also caps the memory that the GPU can pin. The cap is
the `ttm.pages_limit` kernel parameter, in 4 KiB pages. The default is half of
system RAM. This module does not change it. Measure first. Then set it in the
host, for example `boot.kernelParams = [ "ttm.pages_limit=12582912" ];` for
48 GiB.

The flake exports `rdna4-limits` as a path module. Thus a host can import
both `rdna4-full` and `rdna4-limits` without a duplicate-option error.

### `rdna4-full`

Convenience meta-module. Equivalent to importing `rdna4-base`, `rdna4-rocm`,
`rdna4-power`, `rdna4-build-env`, and `rdna4-limits` individually. Does not
include `rdna4-dual`. `rdna4-limits` stays inert until
`rdna4.limits.enable = true`.

---

## ISA overlay

`overlays.default` scopes `rocmPackages.clr` to `gfx1201` only:

```nix
nixpkgs.overlays = [ inputs.rdna4-stack.overlays.default ];
```

**Do not apply this overlay unless you are already doing local ROCm source
builds.** Applying it forces a rebuild of `clr` and every package that depends
on it, bypassing `cache.nixos.org`. The binary cache carries ROCm 7.x
pre-built for all supported ISAs including `gfx1201` — using it is faster and
requires no local compilation.

The overlay exists for storage-constrained hosts or cases where a custom
single-ISA closure is required. A future upstream improvement
([NixOS/nixpkgs#486613](https://github.com/NixOS/nixpkgs/issues/486613)) will
make per-ISA binding possible without expensive rebuilds, at which point this
overlay becomes obsolete.

---

## ROCm sysroot overlay

`overlays.rocm-sysroot` is cache-friendly. It does not override `clr` or any
other `rocmPackages` member. All ROCm packages come from `cache.nixos.org`.
Only a small `symlinkJoin` builds locally. It is separate from
`overlays.default`. Do not apply both unless you want the `clr` rebuild.

```nix
nixpkgs.overlays = [ inputs.rdna4-stack.overlays.rocm-sysroot ];
```

The overlay adds one attribute set, `pkgs.rdna4`:

| Attribute | Content |
|---|---|
| `rocmSysroot` | `symlinkJoin` in `/opt/rocm` shape |
| `rocmSysroot.rocmVersion` | the ROCm version, for example `7.2.3` |
| `hipEnv` | environment variables for a HIP CMake build, for `gfx1201` |
| `mkHipEnv { gpuTargets = [ ... ]; }` | `hipEnv` for other targets, for example `[ "gfx1200" "gfx1201" ]` |
| `gpuTargets` | the default list, `[ "gfx1201" ]` |

`rocmSysroot` joins `clr`, `hipcc`, `rocm-runtime`, `rocm-device-libs`,
`rocm-comgr`, `rocminfo`, `rocm-smi`, `rocm-core`, `rocblas`, `hipblas` and
`hipblas-common`. `hipblas.h` includes `<hipblas-common/hipblas-common.h>`, so
`hipblas-common` is necessary. `llvm` is a link to `rocmPackages.llvm.clang`,
so `llvm/bin/clang++` and `llvm/bin/amdgpu-arch` exist. `bin/hipcc` is the
`clr` wrapper.

The sysroot does not keep the `clr` files in `nix-support`. The `clr` setup
hook exports `HIP_PATH=<clr>` and would override `hipEnv`. The sysroot has its
own setup hook. That hook sets each `hipEnv` variable to the sysroot value,
but only if the variable is empty. Thus `hipEnv` or `mkHipEnv` attributes on
a shell or derivation always win. The sysroot propagates no inputs, because
all of them are in the join.

`hipEnv` keys: `ROCM_PATH`, `HIP_PATH`, `HIP_DEVICE_LIB_PATH`, `HIPCXX`,
`CMAKE_HIP_COMPILER`, `CMAKE_HIP_COMPILER_ROCM_ROOT`, `GPU_TARGETS`,
`AMDGPU_TARGETS`. `GPU_TARGETS` and `AMDGPU_TARGETS` use `;` as the separator.

Use `hipEnv` in a derivation or a shell:

```nix
pkgs.stdenv.mkDerivation ({
  # ...
  nativeBuildInputs = [ pkgs.cmake pkgs.ninja pkgs.rdna4.rocmSysroot ];
} // pkgs.rdna4.hipEnv)
```

The check `checks.x86_64-linux.rocm-sysroot` builds the sysroot. It confirms
that `bin/hipcc`, `lib/libhsa-runtime64.so`, `amdgcn/bitcode`,
`llvm/bin/clang++`, `llvm/bin/amdgpu-arch`, `include/hipblas/hipblas.h` and
`include/hipblas-common/hipblas-common.h` exist. It also confirms that the
setup hook does not refer to `clr`.

The checks `sysroot-setup-hook` and `sysroot-setup-hook-keeps-env` test the
setup hook with small stand-in packages. They build no ROCm.

---

## Consumers

- nix-radiance (`gitea@code-ssh.novuscotia.com:novuscotia-ops/nix-radiance.git`)
  packages the HIP inference engine `radiance` for `gfx1201`. It sets
  `rdna4.inputs.nixpkgs.follows = "nixpkgs"`. It applies
  `overlays.rocm-sysroot`. It does not apply `overlays.default`. Its devenv
  module uses the same `pkgs.rdna4.hipEnv` attribute set as `devShells.hip`.

Tell the maintainer before you change the names in `pkgs.rdna4` or in
`hipEnv`. Consumers depend on them.

---

## Post-deploy verification

Run in order after `nixos-rebuild switch`:

```bash
# Confirm amdgpu is the active kernel driver
lspci -k | grep -A3 "VGA\|Display"
# Expected: Kernel driver in use: amdgpu

# KFD device is accessible to the render group
ls -la /dev/kfd
# Expected: crw-rw---- 1 root render

# ROCm enumerates the gfx1201 HSA agent
rocminfo | grep -E "Name|ISA"
# Expected: gfx1201, AMD Radeon (R9700 or RX 9070 variant)

# Vulkan sees the RADV RDNA4 device
vulkaninfo --summary 2>/dev/null | grep -E "deviceName|driverName"
# Expected: RADV NAVI48, driverName: radv

# OpenCL ICD is visible
clinfo | grep "Board name"
# Expected: gfx1201

# LACT daemon is running
systemctl status lactd
# Expected: active (running)

# Concurrent access: Vulkan render path and ROCm compute path simultaneously
vkcube &
rocminfo
# Both complete without error, confirming the bifurcated driver interface
```

---

## Invariants

These conditions must hold on any host running this stack:

- `HSA_OVERRIDE_GFX_VERSION` must not be set. That variable overrides ISA
  detection for hardware not supported by the ROCm runtime. `gfx1201` is
  officially supported in ROCm 7.x; applying the override misidentifies the
  ISA and produces incorrect code generation.

- `nixpkgs.config.rocmSupport = true` must not be set globally. It enables
  ROCm in Firefox, Thunderbird, and other unrelated packages, increasing
  closure size and build failure exposure. Use `pkgs.pkgsRocm.*` for
  per-package ROCm support.

- `amdvlk` must not be installed alongside RADV without a specific reason.
  RADV is the correct Vulkan ICD for RDNA4. The ICD loader arbitrates between
  installed ICDs; two ICDs without explicit `VK_ICD_FILENAMES` ordering
  produces non-deterministic driver selection.

- `overlays.default` must not be applied unless local ROCm source builds are
  intentional. See [ISA overlay](#isa-overlay).

---

## Contributing

```bash
# Enter the contributor shell (nixpkgs-fmt, nil, statix, deadnix)
nix develop

# Format
nix fmt

# Lint
statix check .

# Validate flake schema and run smoke tests
nix flake check

# Evaluate everything, but build nothing.
# Use this on a host with less than 6 GiB free in /nix.
nix flake check --no-build
```

`nix flake check` builds `checks.x86_64-linux.rocm-sysroot`. That check fetches
about 2 GiB from the cache (3.6 GiB unpacked). `checks.x86_64-linux.module-options`
evaluates the modules and builds nothing from ROCm.
