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
      packages = forAllSystems (pkgs: {
        core = pkgs.callPackage ./packages/core { src = ember-core; };
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.core;
      });

      nixosModules.default = import ./modules/nixos.nix { inherit self; };
    };
}
