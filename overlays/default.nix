# overlays/default.nix
#
# ISA-scoped ROCm overlay — gfx1201 only.
#
# USE ONLY if you are already doing local ROCm source builds or are storage-
# constrained. Applying this overlay scopes clr to gfx1201, which forces a
# local rebuild of clr and all dependents, bypassing cache.nixos.org.
#
# For most deployments: consume pkgsRocm.* directly from the binary cache.
# cache.nixos.org builds ROCm 7.x for all supported ISAs including gfx1201.
#
# Tracked upstream: NixOS/nixpkgs#486613 (kpack-split) will eventually make
# per-ISA binding possible without expensive full rebuilds.
#
final: prev: {
  rocmPackages = prev.rocmPackages.overrideScope (
    _fs: ps: {
      clr = ps.clr.override {
        localGpuTargets = [ "gfx1201" ];
      };
    }
  );
}
