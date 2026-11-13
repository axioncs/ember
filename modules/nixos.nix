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

    cefDebug = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Give steamwebhelper a DevTools endpoint, so the store-page layer (badges,
        themes) has something to attach to: preloads a shim that appends
        `--remote-debugging-port` when the client spawns the webhelper, and starts
        the badge agent alongside Steam. It opens a local, unauthenticated
        debugging port; set this to false to leave the webhelper untouched.
      '';
    };

    cefPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port the DevTools endpoint listens on when cefDebug is enabled.";
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
        message = "programs.ember.steamPackage must be an overridable Steam package (one built with pkgs.steam.override).";
      }
    ];

    environment.systemPackages = [ cfg.cli ];

    # The UI layer ships as a separate package (DevTools client + badge script).
    # Point the CLI at it: on NixOS nothing lives in ~/.local/share/ember.
    environment.sessionVariables = {
      EMBER_CDPD = "${self.packages.${pkgs.stdenv.hostPlatform.system}.cdp}/bin/ember-cdpd";
      EMBER_BADGE = "${self.packages.${pkgs.stdenv.hostPlatform.system}.cdp}/share/ember/badge.js";
    };

    # extraEnv lands in the FHS profile, which the container init sources. Setting
    # it there rather than in the global environment keeps it scoped to Steam and
    # lets it override any inherited LD_AUDIT.
    #
    # Function form on purpose: an attribute-set override replaces extraEnv
    # wholesale, which would drop whatever another Steam wrapper put there.
    # Applying the function to the previous arguments merges instead.
    programs.steam.package = cfg.steamPackage.override (prev: {
      extraEnv = (prev.extraEnv or { }) // {
        LD_AUDIT = "${cfg.package}/lib/ember/ember-core.so";
      } // lib.optionalAttrs cfg.cefDebug {
        LD_PRELOAD = "${self.packages.${pkgs.stdenv.hostPlatform.system}.cefshim}/lib/ember-cef.so";
        EMBER_CEF_PORT = toString cfg.cefPort;
        # The shim starts the badge agent the first time the client spawns the
        # webhelper, so no unit or wrapper is needed to keep it running.
        EMBER_AGENT = "${cfg.cli}/bin/ember";
      };
    });
  };
}
