{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ember;

  # Two launch paths, the same shape as the distro installer:
  #
  #   steam       "Steam"        programs.steam.package, untouched
  #   steam-ember "Wired Steam"  the same client with ember loaded
  #
  # So the wrapped derivation is a second FHS environment rather than a
  # replacement for programs.steam.package. steam:// links, autostart and the
  # distributor's own entry therefore keep starting the vanilla client, and
  # ember is opt-in per launch.
  steamWired = cfg.steamPackage.override (prev: {
      extraEnv = (prev.extraEnv or { }) // {
        # The libcurl redirector loads first, then the audit library. Both are
        # LD_AUDIT objects, never LD_PRELOAD: the loader rejects a preload that
        # calls into the client, and the core binds exec* through la_symbind64
        # to rewrite the webhelper's --remote-debugging-port argument.
        LD_AUDIT = "${cfg.package}/lib/ember/ember-library-inject.so:${cfg.package}/lib/ember/ember-core.so";
        # Cloud is read by the library from the environment as well as from
        # config.yaml, so the option wins without rewriting a file the user
        # owns. The CLI reads the same variables, keeping one source of truth.
        EMBER_CLOUD = if cfg.cloud then "1" else "0";
      } // lib.optionalAttrs (cfg.cloudRemote != null) {
        EMBER_CLOUD_REMOTE = cfg.cloudRemote;
        EMBER_CLOUD_FOLDER = cfg.cloudFolder;
      } // lib.optionalAttrs (!cfg.cefDebug) {
        EMBER_CEF = "0";
      };

      # PATH is NOT set through extraEnv. That block is emitted as a bare
      # assignment after nixpkgs' own `export PATH=...`, so an extraEnv PATH
      # replaces the container's PATH and Steam stops being executable. This
      # string lands after it and expands $PATH at runtime, so the container's
      # directories survive.
      #
      # The core unpacks manifest archives by shelling out to unzip, gzip and
      # timeout. Inside the FHS container the only directories on PATH are the
      # container's own, so a tool installed in the system profile is invisible
      # even though it exists — which is why manifest import reported unzip
      # missing on a machine that has it.
      extraProfile = (prev.extraProfile or "") + ''
        export PATH="${lib.makeBinPath (with pkgs; [ unzip gzip coreutils ])}:$PATH"
      '';
    });

  # The `steam-ember` command and its menu entry. Exec names the launcher on
  # PATH rather than the store path so the entry survives a rebuild that moves
  # the derivation.
  emberLauncher = pkgs.runCommand "steam-ember-launcher" { } ''
    mkdir -p $out/bin $out/share/applications
    cat > $out/bin/steam-ember <<'EOF'
    #!/bin/sh
    exec ${steamWired}/bin/steam "$@"
    EOF
    chmod 755 $out/bin/steam-ember

    cat > $out/share/applications/wired-steam.desktop <<'EOF'
    [Desktop Entry]
    Type=Application
    Name=Wired Steam
    GenericName=Game Store
    Comment=Steam with ember loaded, for games ember added
    Exec=steam-ember %U
    Icon=steam
    Terminal=false
    Categories=Game;
    StartupWMClass=Steam
    MimeType=x-scheme-handler/steam;x-scheme-handler/steamlink;
    EOF
    chmod 644 $out/share/applications/wired-steam.desktop
  '';
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
        Give steamwebhelper a DevTools endpoint so the store-page layer has
        something to attach to. The core binds the client's exec calls and
        appends `--remote-debugging-port` when the webhelper is spawned, then
        publishes the chosen port to <filename>~/.config/ember/cef_port</filename>.
        The port is local and unauthenticated; set this to false to leave the
        webhelper untouched.
      '';
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

    uiWatch = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the store-page badge watcher as a user service. Steam only opens a
        DevTools endpoint for the webhelper when
        <filename>~/.local/share/Steam/.cef-enable-remote-debugging</filename>
        exists; the core creates it, and this service is what draws the badge
        into each store page while Steam runs. Without it the endpoint is live
        and the badge never appears.
      '';
    };

    cloudSync = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Periodically push ember's save store to the rclone remote named by
        <option>cloudRemote</option>. Off by default: the push runs
        <command>rclone sync</command>, which makes the remote match this
        machine, and a timer running that against a remote you have not
        configured produces a journal entry every interval.
      '';
    };

    cloudSyncInterval = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      description = ''
        systemd calendar interval between cloud save pushes. Any value
        <option>systemd.time</option> accepts, e.g. <literal>15min</literal>,
        <literal>1h</literal>, <literal>30s</literal>. Ignored unless
        <option>cloudSync</option> is enabled.
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

    environment.systemPackages = [ cfg.cli emberLauncher ];

    # The badge watcher is a user unit, not a system one: it needs the user's
    # curl, pgrep and rclone, and it must die with the graphical session. The
    # core creates Steam's remote-debugging marker, so the endpoint exists; this
    # is what draws into it.
    systemd.user.services.ember-ui-watch = lib.mkIf cfg.uiWatch {
      description = "ember store-page badge watcher";
      after = [ "graphical-session.target" ];
      wantedBy = [ "default.target" ];

      serviceConfig = {
        ExecStart = "${cfg.cli}/bin/ember ui watch --quiet";
        Restart = "on-failure";
        RestartSec = 5;
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };

    # Cloud sync is opt-in. `rclone sync` makes the remote match this machine,
    # so a timer against an unconfigured remote fails every interval.
    systemd.user.services.ember-cloud-push = lib.mkIf cfg.cloudSync {
      description = "Push ember cloud saves to the configured rclone remote";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.cli}/bin/ember cloud push";
        TimeoutStartSec = 600;
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };

    systemd.user.timers.ember-cloud-push = lib.mkIf cfg.cloudSync {
      description = "Periodic ember cloud save push";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = cfg.cloudSyncInterval;
        Persistent = true;
        Unit = "ember-cloud-push.service";
      };
    };

    # The CLI runs in an ordinary shell, so it cannot see extraEnv — that one
    # only reaches Steam's container. Session variables give `ember cloud` the
    # same cloud settings the library gets, keeping one source of truth.
    environment.sessionVariables = {
      EMBER_CLOUD = if cfg.cloud then "1" else "0";
    } // lib.optionalAttrs (cfg.cloudRemote != null) {
      EMBER_CLOUD_REMOTE = cfg.cloudRemote;
      EMBER_CLOUD_FOLDER = cfg.cloudFolder;
    };

    # programs.steam.package is deliberately left alone: `steam` and the
    # distributor's "Steam" entry must keep starting the vanilla client. The
    # wrapped environment lives in steamWired and is only reachable through
    # `steam-ember` / "Wired Steam".
  };
}
