{
  lib,
  stdenv,
  fetchurl,
  patchelf,
  curl,
  openssl,
  zlib,
  src ? null,
  release ? null,
}:

# Two ways to get the core, behind one interface.
#
#   src     a tree (the ember-core flake input) -> compile it here
#   release { url, sha256, version }           -> unpack the published artifact
#
# The release path exists because a NixOS rebuild should not have to compile a
# C++ library to install ember, the way the distro installer downloads a
# tarball on Arch and Fedora. The published core carries no RPATH and links only
# libstdc++/libm/libgcc/libc at load time; curl and openssl are dlopen'ed by
# soname at runtime, from the container that already has them. So the artifact
# is installed as-is and nothing is patched.
let
  targeted = if release != null then release.version else "0.3.0";

  common = {
    pname = "ember-core";
    version = targeted;

    nativeBuildInputs = [ patchelf ];

    meta = {
      description = "ember core — Steam client licensing, depot and manifest pipeline";
      homepage = "https://github.com/axioncs/ember";
      license = lib.licenses.agpl3Only;
      platforms = lib.platforms.linux;
    };
  };

  installArtifacts = ''
    runHook preInstall
    install -Dm755 bin/ember-core.so $out/lib/ember/ember-core.so
    install -Dm755 bin/ember-library-inject.so $out/lib/ember/ember-library-inject.so
    install -Dm755 bin/pattern-refresh $out/lib/ember/pattern-refresh
    install -Dm755 tools/ember-autoupdate.sh $out/lib/ember/ember-autoupdate.sh

    # SteamStub. The core resolves its helper relative to its own install
    # root, so the script and the bundled Steamless binaries have to sit
    # under tools/ beside the library. Without them DRM-protected titles
    # fail at launch with "Application load error 6".
    install -Dm755 tools/steamstub-bypass/run-steamless.sh \
      $out/lib/ember/tools/steamstub-bypass/run-steamless.sh
    install -Dm755 tools/steamstub-bypass/install-steamless.sh \
      $out/lib/ember/tools/steamstub-bypass/install-steamless.sh
    install -Dm755 tools/steamstub-bypass/scan-all.sh \
      $out/lib/ember/tools/steamstub-bypass/scan-all.sh
    cp -a tools/steamless-bin $out/lib/ember/tools/steamless-bin
    runHook postInstall
  '';

  fromSource =
    assert src != null;
    (stdenv.mkDerivation (common // {
      inherit src;

      buildInputs = [
        curl
        openssl
        zlib
      ];

      env.GIT_COMMIT_HASH = "ember";
      env.BUILD_BRANCH = "ember";

      postPatch = ''
        patchShebangs embed-version.sh embed-config.sh
      '';

      buildPhase = ''
        runHook preBuild
        make -j$NIX_BUILD_CORES bin/ember-core.so bin/ember-library-inject.so
        make -j$NIX_BUILD_CORES bin/pattern-refresh
        runHook postBuild
      '';

      installPhase = installArtifacts;

      postFixup = ''
        patchelf --force-rpath --set-rpath ${
          lib.makeLibraryPath [
            curl
            openssl
            zlib
            (lib.getLib stdenv.cc.cc)
          ]
        } $out/lib/ember/ember-core.so
      '';
    }));

  fromRelease =
    assert release != null;
    stdenv.mkDerivation (common // {
      src = fetchurl {
        url = release.url;
        sha256 = release.sha256;
      };

      sourceRoot = ".";

      buildPhase = ''
        runHook preBuild
        tar xzf "$src" -C .
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 ember-core.so $out/lib/ember/ember-core.so
        install -Dm755 ember-library-inject.so $out/lib/ember/ember-library-inject.so
        install -Dm755 ember-cdpd $out/lib/ember/ember-cdpd
        install -Dm644 badge.js $out/lib/ember/badge.js
        install -Dm644 ember.lua $out/lib/ember/ember.lua
        install -Dm644 VERSION $out/lib/ember/VERSION
        install -Dm755 ember-autoupdate.sh $out/lib/ember/ember-autoupdate.sh 2>/dev/null || true
        if [ -d tools ]; then
          cp -a tools $out/lib/ember/tools
        fi
        runHook postInstall
      '';
    });
in
if release != null then fromRelease else fromSource