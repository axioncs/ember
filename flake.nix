{
  description = "ember — Steam library tooling";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Local until published; switch to github:axioncs/ember-core.
    ember-core = {
      url = "git+file:///home/axioncs/.local/share/ember-core?ref=ember";
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
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          core = pkgs.callPackage ./packages/core { src = ember-core; };
        in
        {
          inherit core;

          # Steam with the audit library injected. Usable directly for testing
          # without a system rebuild: nix run .#steam
          steam = pkgs.steam.override {
            extraEnv.LD_AUDIT = "${core}/lib/ember/ember-core.so";
          };

          default = core;
        }
      );

      nixosModules.default = import ./modules/nixos.nix { inherit self; };
    };
}
