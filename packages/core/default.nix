{
  lib,
  stdenv,
  pkg-config,
  patchelf,
  curl,
  dbus,
  luajit,
  src,
}:
stdenv.mkDerivation {
  pname = "ember-core";
  version = "0.1.0";

  inherit src;

  nativeBuildInputs = [
    pkg-config
    patchelf
  ];

  buildInputs = [
    curl
    dbus
    luajit
  ];

  # embed-version.sh reads these instead of shelling out to git, which does not
  # exist inside the build sandbox.
  env.GIT_COMMIT_HASH = "ember";
  env.BUILD_BRANCH = "ember";

  postPatch = ''
    patchShebangs embed-version.sh embed-config.sh
  '';

  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES audit-libs
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/SLSsteam.so $out/lib/ember/ember-core.so
    runHook postInstall
  '';

  # Pin dependencies by absolute path: the client's FHS sandbox would otherwise
  # shadow libcurl/dbus/libstdc++ with older runtime copies.
  postFixup = ''
    patchelf --force-rpath --set-rpath ${
      lib.makeLibraryPath [
        curl
        dbus
        (lib.getLib stdenv.cc.cc)
      ]
    } $out/lib/ember/ember-core.so
  '';

  meta = {
    description = "ember core — Steam client licensing and depot hook";
    homepage = "https://github.com/axioncs/ember";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.linux;
  };
}
