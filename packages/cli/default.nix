{
  lib,
  stdenv,
  lua5_4,
  unzip,
  curl,
  makeWrapper,
}:
stdenv.mkDerivation {
  pname = "ember-cli";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/ember
    install -m644 ember.lua $out/share/ember/ember.lua
    makeWrapper ${lua5_4}/bin/lua $out/bin/ember \
      --add-flags "$out/share/ember/ember.lua" \
      --prefix PATH : ${lib.makeBinPath [ unzip curl ]}
    runHook postInstall
  '';

  meta = {
    description = "ember command line interface";
    homepage = "https://github.com/axioncs/ember";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "ember";
  };
}
