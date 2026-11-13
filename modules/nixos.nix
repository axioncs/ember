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

    cli = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.cli;
      defaultText = lib.literalExpression "ember.packages.\${system}.cli";
      description = "ember command line interface.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.programs.steam.enable;
        message = "programs.ember needs programs.steam.enable = true; otherwise the library is built but nothing loads it.";
      }
      {
        assertion = cfg.steamPackage ? override;
        message = "programs.ember.steamPackage must be an overridable Steam package (one built with pkgs.steam.override, e.g. pkgs.steamWithMillennium).";
      }
    ];

    environment.systemPackages = [ cfg.cli ];

    # extraEnv lands in the FHS profile, which the container init sources. Setting
    # it there rather than in the global environment keeps it scoped to Steam and
    # lets it override any inherited LD_AUDIT.
    #
    # Function form on purpose: an attribute-set override replaces extraEnv
    # wholesale, which would drop whatever another Steam wrapper put there
    # (Millennium's runtime paths, for one). Applying the function to the
    # previous arguments merges instead.
    programs.steam.package = cfg.steamPackage.override (prev: {
      extraEnv = (prev.extraEnv or { }) // {
        LD_AUDIT = "${cfg.package}/lib/ember/ember-core.so";
      };
    });
  };
}
