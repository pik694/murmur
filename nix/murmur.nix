{
  lib,
  stdenv,
  swift,
  apple-sdk_15,
  darwinMinVersionHook,
  librsvg,
  libicns,
  whisper,
}:

let
  frameworks = "${whisper}/build-apple/whisper.xcframework/macos-arm64_x86_64";
in
stdenv.mkDerivation {
  pname = "murmur";
  version = "0.1.1";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Sources
      ../Resources
    ];
  };

  nativeBuildInputs = [
    swift
    librsvg
    libicns
  ];
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

    # App icon: render the SVG at every size macOS uses and pack it into an .icns.
    mkdir icon
    for size in 16 32 48 128 256 512 1024; do
      rsvg-convert -w $size -h $size Resources/icon.svg -o icon/$size.png
    done
    png2icns Murmur.icns icon/*.png
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    app=$out/Applications/Murmur.app/Contents
    mkdir -p $app/MacOS $app/Resources $app/Frameworks
    cp Murmur $app/MacOS/
    cp Resources/Info.plist $app/
    cp Murmur.icns $app/Resources/
    cp -R ${frameworks}/whisper.framework $app/Frameworks/
    chmod -R u+w $app/Frameworks
    runHook postInstall
  '';

  meta.platforms = [ "aarch64-darwin" ];
}
