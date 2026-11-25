{
  description = "ember — Steam library tooling";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    ember-core = {
      # git, not the github: tarball endpoint, whose fetches truncate here.
      url = "git+https://github.com/axioncs/ember-core?ref=ember";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      ember-core,
    }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (import nixpkgs {
            inherit system;
            config.allowUnfreePredicate =
              pkg:
              builtins.elem (nixpkgs.lib.getName pkg) [
                "steam"
                "steam-unwrapped"
              ];
          })
        );

      # The core release a NixOS install downloads instead of compiling.
      #
      # Set this when a version is tagged, so a rebuild substitutes the
      # published artifact instead of building the core.
      #
      # null is the correct state between tagging a release and pinning its
      # artifact: the hash cannot be known until CI has built it, and a stale
      # hash fails the tag's own verify step. `nix build .#core` builds from
      # source in that window — slower, but it cannot install the wrong
      # library. Set the block immediately after each tag, with the hash the
      # release workflow printed.
      coreRelease = {
        version = "0.8.0-test";
        url =
          "https://github.com/axioncs/ember/releases/download/v0.8.0-test/ember-v0.8.0-test-x86_64-linux.tar.gz";
        sha256 = "4cec4fd7c10dcafe30e180221add02e7c53042587d8a3b0782b88716797f1960";
      };
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          # Source build. Used directly by `nix build .#core-source`, and as the
          # fallback when a release is not wired up.
          coreSource = pkgs.callPackage ./packages/core { src = ember-core; };

          # Prebuilt core: downloads the published artifact, no compilation.
          coreReleasePkg =
            if coreRelease == null then
              null
            else
              pkgs.callPackage ./packages/core {
                release = coreRelease;
              };

          cdp = pkgs.callPackage ./packages/cdp { };
        in
        {
          inherit coreSource cdp;

          # What the module installs by default: the prebuilt artifact, which a
          # rebuild downloads instead of compiling. Set `coreRelease` to null to
          # build from source instead.
          core =
            if coreRelease == null then
              coreSource
            else
              coreReleasePkg;

          cli = pkgs.callPackage ./packages/cli { inherit cdp; };

          # Steam with the audit library injected. Usable directly for testing
          # without a system rebuild: nix run .#steam
          steam = pkgs.steam.override {
            extraEnv.LD_AUDIT = "${self.packages.${pkgs.stdenv.hostPlatform.system}.core}/lib/ember/ember-core.so";
          };

          default = self.packages.${pkgs.stdenv.hostPlatform.system}.core;
        }
      );

      nixosModules.default = import ./modules/nixos.nix { inherit self; };

      checks = forAllSystems (pkgs: {
        stplugin = pkgs.stdenv.mkDerivation {
          pname = "ember-test-stplugin";
          version = "0.8.0-test";
          src = ember-core;
          nativeBuildInputs = [
            pkgs.gnumake
            pkgs.gcc
          ];
          buildPhase = "make test-stplugin";
          installPhase = "mkdir -p $out && touch $out/passed";
        };
      });
    };
}