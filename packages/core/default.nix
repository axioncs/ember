{
  lib,
  stdenv,
  pkg-config,
  patchelf,
  curl,
  openssl,
  zlib,
  src,
}:
stdenv.mkDerivation {
  pname = "ember-core";
  version = "0.3.0";

  inherit src;

  nativeBuildInputs = [
    pkg-config
    patchelf
  ];

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

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/ember-core.so $out/lib/ember/ember-core.so
    install -Dm755 bin/ember-library-inject.so $out/lib/ember/ember-library-inject.so
    install -Dm755 bin/pattern-refresh $out/lib/ember/pattern-refresh
    install -Dm755 tools/ember-autoupdate.sh $out/lib/ember/ember-autoupdate.sh
    runHook postInstall
  '';

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

  meta = {
    description = "ember core — Steam client licensing, depot and manifest pipeline";
    homepage = "https://github.com/axioncs/ember";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.linux;
  };
}