{
  lib,
  stdenv,
  lua5_4,
  unzip,
  curl,
  coreutils,
  procps,
  cdp,
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
    # The UI layer's pieces belong beside the CLI: the badge agent is started
    # from inside Steam's container, where nothing outside the store is visible
    # and no session variable exists, so path-relative lookup is the only one
    # that always works.
    install -m755 ${cdp}/bin/ember-cdpd $out/share/ember/ember-cdpd
    install -m644 ${cdp}/share/ember/badge.js $out/share/ember/badge.js
    makeWrapper ${lua5_4}/bin/lua $out/bin/ember \
      --add-flags "$out/share/ember/ember.lua" \
      --prefix PATH : ${lib.makeBinPath [ unzip curl coreutils procps ]}
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
