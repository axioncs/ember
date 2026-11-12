{
  description = "ember — Steam library tooling";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Fork of AceSLS/SLSsteam, branch `ember` off `dev-multiarch`.
    # Local git input while the fork is not published; switch to
    # github:axioncs/ember-core once it is.
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
