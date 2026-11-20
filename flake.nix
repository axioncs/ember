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
      # published artifact instead of building the core. While the input
      # tracks a branch that has no release yet, it stays null: pointing it
      # at a tarball that lacks the feature would install the old core and
      # report success.
      coreRelease = {
        version = "0.7.5";
        url =
          "https://github.com/axioncs/ember/releases/download/v0.7.5/ember-v0.7.5-x86_64-linux.tar.gz";
        sha256 = "3bcc13cc25c620f4156cf28d180983839d1e1d12a96637518bec31e3806e645d";
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
          version = "0.2.0";
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