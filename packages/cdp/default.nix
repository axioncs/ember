{
  lib,
  stdenv,
}:

stdenv.mkDerivation {
  pname = "ember-cdp";
  version = "0.1.0";

  src = ./.;
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -o ember-cdpd ember-cdpd.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 ember-cdpd $out/bin/ember-cdpd
    install -Dm644 badge.js $out/share/ember/badge.js
    runHook postInstall
  '';

  meta = {
    description = "DevTools client for Steam's webhelper, and the store-page badge script";
    license = lib.licenses.agpl3Only;
    platforms = [ "x86_64-linux" ];
  };
}
