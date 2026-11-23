{
  lib,
  stdenv,
  swift,
  apple-sdk_15,
  darwinMinVersionHook,
  whisper,
}:

let
  frameworks = "${whisper}/build-apple/whisper.xcframework/macos-arm64_x86_64";
in
stdenv.mkDerivation {
  pname = "murmur";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Sources
      ../Resources
    ];
  };

  nativeBuildInputs = [ swift ];
  buildInputs = [
    apple-sdk_15
    (darwinMinVersionHook "14.0")
  ];

  buildPhase = ''
    runHook preBuild
    # Pin the deployment target; swiftc otherwise targets the build machine's macOS.
    swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
      -F ${frameworks} -framework whisper \
      -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
      Sources/*.swift -o Murmur
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    app=$out/Applications/Murmur.app/Contents
    mkdir -p $app/MacOS $app/Resources $app/Frameworks
    cp Murmur $app/MacOS/
    cp Resources/Info.plist $app/
    cp -R ${frameworks}/whisper.framework $app/Frameworks/
    chmod -R u+w $app/Frameworks
    runHook postInstall
  '';

  meta.platforms = [ "aarch64-darwin" ];
}
