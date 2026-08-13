{
  description = "BobrWhisper - local-first voice-to-text";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Zig for the dev shell, pinned independently of nixpkgs so contributors get
    # the exact upstream release. Deliberately NOT used for the libwhisper
    # package: see the zig argument in the packages block below.
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, zig, ... }:
    let
      inherit (nixpkgs) lib;

      # libwhisper needs no Swift, Xcode, or audio capture, so it builds on every
      # system here. The app is a different story: it is arm64-macOS only, since
      # Config.zig hardcodes Apple M1 for iOS targets and the Makefile pins
      # ARCHS=arm64 for xcodebuild.
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems = f: lib.genAttrs systems (system: f system);

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          # BobrWhisper is BSL-1.1. Permit only this package while retaining
          # accurate license metadata on the derivation.
          config.allowUnfreePredicate = pkg: lib.getName pkg == "libwhisper";
        };

      zigFor = system: zig.packages.${system}."0.16.0";

      libwhisperFor =
        system: optimize:
        (pkgsFor system).callPackage ./nix/libwhisper.nix {
          # nixpkgs' zig, not the zig-overlay one, and this is load-bearing:
          # nixpkgs patches native libc detection so it works inside the build
          # sandbox. The unpatched overlay build finds no glibc, falls back to
          # musl headers, and dies on a missing `bits/alltypes.h` while
          # compiling ggml. The overlay is still what the dev shell uses, where
          # the host libc is visible.
          zig = (pkgsFor system).zig_0_16;
          inherit optimize;
        };
    in
    {
      packages = forAllSystems (system: rec {
        libwhisper-debug = libwhisperFor system "Debug";
        libwhisper-releasesafe = libwhisperFor system "ReleaseSafe";
        libwhisper-releasefast = libwhisperFor system "ReleaseFast";

        # Aliases rather than separate derivations, so the attributes cannot
        # drift apart or build the same thing twice.
        libwhisper = libwhisper-releasefast;
        default = libwhisper;
      });

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          deps = import ./nix/deps.nix;

          # Grep build.zig.zon for every rev and Zig package hash in
          # nix/deps.nix. Zig does not re-verify a staged zig-pkg/<hash>
          # directory, so drift here would silently build the wrong source.
          pinChecks = lib.concatMapStringsSep "\n" (
            name:
            let
              dep = deps.${name};
            in
            ''
              for value in "${dep.rev}" "${dep.zigHash}"; do
                if ! grep -qF "$value" "$zon"; then
                  echo "nix/deps.nix pins ${name} at a value absent from build.zig.zon: $value" >&2
                  status=1
                fi
              done
            ''
          ) (lib.attrNames deps);
        in
        {
          # Builds libwhisper and runs its Zig tests plus the C ABI smoke test.
          libwhisper = libwhisperFor system "ReleaseSafe";

          dep-pins = pkgs.runCommand "libwhisper-dep-pins" { } ''
            zon=${./build.zig.zon}
            status=0
            ${pinChecks}
            if [ "$status" -ne 0 ]; then
              echo "Update nix/deps.nix so its rev and hash match build.zig.zon." >&2
              exit 1
            fi
            touch "$out"
          '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          # mkShellNoCC: on Darwin the build resolves clang/clang++/metal/
          # xcodebuild via the system Xcode (see src/build/AppleSdk.zig), and a
          # nix stdenv would inject a different libc++ and SDK root and break the
          # link against whisper.cpp / llama.cpp. Zig brings its own clang and
          # `zig ar`, so no stdenv or binutils is needed on Linux either.
          default = pkgs.mkShellNoCC {
            packages = [
              (zigFor system)
              pkgs.zls
            ];
          };
        }
      );
    };
}
