{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ember;
in
{
  options.programs.ember = {
    enable = lib.mkEnableOption "ember Steam library tooling";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.core;
      defaultText = lib.literalExpression "ember.packages.\${system}.core";
      description = "ember core audit library.";
    };

    steamPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.steam;
      defaultText = lib.literalExpression "pkgs.steam";
      description = "Steam package to wrap with the ember audit library.";
    };
  };

  config = lib.mkIf cfg.enable {
    # extraEnv lands in the FHS profile, which the container init sources.
    programs.steam.package = cfg.steamPackage.override {
      extraEnv = {
        LD_AUDIT = "${cfg.package}/lib/ember/ember-core.so";
      };
    };
  };
}
