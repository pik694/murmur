{
  description = "Murmur: local, private dictation for macOS (whisper.cpp)";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};

      # Prebuilt whisper.cpp framework from the official release (Metal-enabled).
      whisper = pkgs.fetchzip {
        url = "https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.4/whisper-v1.8.4-xcframework.zip";
        hash = "sha256-JkYIuHmrB2gD/tZ8kR5BWoc2HR8Y1KEs14dBODPBNwM=";
        stripRoot = false;
      };

      murmur = pkgs.callPackage ./nix/murmur.nix { inherit whisper; };

      # `nix run .#dist` -> dist/Murmur-<version>.dmg, signed with the local self-signed
      # "Murmur Code Signing" identity so macOS treats every release as the same app.
      # Uses the system codesign/hdiutil (signing needs the user's keychain), so it runs
      # outside the Nix sandbox.
      dist = pkgs.writeShellApplication {
        name = "murmur-dist";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          identity="''${MURMUR_SIGN_IDENTITY:-Murmur Code Signing}"
          out="''${1:-dist}"
          dmg="$out/Murmur.dmg" # stable name: releases/latest/download/Murmur.dmg
          stage=$(mktemp -d)
          trap 'rm -rf "$stage"' EXIT

          cp -R ${murmur}/Applications/Murmur.app "$stage/"
          chmod -R u+w "$stage/Murmur.app"
          /usr/bin/codesign --force --deep --timestamp=none -s "$identity" "$stage/Murmur.app"
          /usr/bin/codesign --verify --deep --strict "$stage/Murmur.app"

          ln -s /Applications "$stage/Applications"
          cp ${./docs/install.html} "$stage/Read me first.html"

          mkdir -p "$out"
          rm -f "$dmg"
          /usr/bin/hdiutil create -quiet -volname Murmur -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
          /usr/bin/codesign --force --timestamp=none -s "$identity" "$dmg"
          echo "$dmg"
        '';
      };
    in
    {
      packages.${system} = {
        default = murmur;
        inherit murmur;
      };

      apps.${system}.dist = {
        type = "app";
        program = "${dist}/bin/murmur-dist";
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [ pkgs.swift ];
        WHISPER_FRAMEWORKS = "${whisper}/build-apple/whisper.xcframework/macos-arm64_x86_64";
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
