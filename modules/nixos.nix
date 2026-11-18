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

    cloud = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Serve Steam Cloud saves for games you added, from
        <filename>~/.config/ember/cloud</filename> instead of Steam's own cloud.
        Steam refuses cloud for apps the account does not own; with this on,
        ember answers those requests itself and the saves stay on the machine
        until you sync them. Games you own are never affected.

        Off hands added games back to Steam, where they get no cloud at all.
      '';
    };

    cloudRemote = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "gdrive";
      description = ''
        rclone remote that <command>ember cloud push</command> and
        <command>pull</command> sync saves with — anything rclone supports
        (Google Drive, OneDrive, Dropbox, S3, a NAS, a local path). Set it up
        once with <command>rclone config</command>; the login happens there, in
        your browser, and ember never sees the token.

        Leave null and saves stay local until you set it. A bare remote name
        ("gdrive") uses the remote's root; a remote written with a path
        ("gdrive:backups") is used as written.
      '';
    };

    cloudFolder = lib.mkOption {
      type = lib.types.str;
      default = "ember-cloud";
      description = ''
        Folder inside the remote that saves are synced to, namespaced to ember so
        a different save-sync tool's data in the same remote is never treated as
        ember's to overwrite. The layout below it mirrors the local store,
        <filename>account/app</filename>, so the remote stays readable without
        ember.
      '';
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

    # The CLI runs in an ordinary shell, so it cannot see extraEnv — that one
    # only reaches Steam's container. Session variables give `ember cloud` the
    # same cloud settings the library gets, keeping one source of truth.
    environment.sessionVariables = {
      EMBER_CLOUD = if cfg.cloud then "1" else "0";
    } // lib.optionalAttrs (cfg.cloudRemote != null) {
      EMBER_CLOUD_REMOTE = cfg.cloudRemote;
      EMBER_CLOUD_FOLDER = cfg.cloudFolder;
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
        # Cloud is read by the library from the environment as well as from
        # config.yaml, so the option wins without rewriting a file the user
        # owns. The CLI reads the same variables, keeping one source of truth.
        EMBER_CLOUD = if cfg.cloud then "1" else "0";
      } // lib.optionalAttrs (cfg.cloudRemote != null) {
        EMBER_CLOUD_REMOTE = cfg.cloudRemote;
        EMBER_CLOUD_FOLDER = cfg.cloudFolder;
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
