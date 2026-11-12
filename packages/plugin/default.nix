{
  lib,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "ember-plugin";
  version = "0.1.0";

  src = ./.;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/ember/plugin
    cp -r plugin.json backend public $out/share/ember/plugin/
    runHook postInstall
  '';

  meta = {
    description = "ember Millennium plugin: ProtonDB ratings on store pages";
    homepage = "https://github.com/axioncs/ember";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.linux;
  };
}
