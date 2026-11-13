{
  lib,
  stdenv,
}:

stdenv.mkDerivation {
  pname = "ember-cef";
  version = "0.1.0";

  src = ./.;
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -shared -fPIC -o ember-cef.so ember-cef.c -ldl
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 ember-cef.so $out/lib/ember-cef.so
    runHook postInstall
  '';

  meta = {
    description = "Preload shim that hands steamwebhelper a DevTools endpoint";
    license = lib.licenses.agpl3Only;
    platforms = [ "x86_64-linux" ];
  };
}
