{
  description = "BobrWhisper - local-first voice-to-text";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      # arm64-only: Config.zig hardcodes Apple M1 for iOS targets and the
      # Makefile pins `ARCHS=arm64` for xcodebuild.
      pkgs = import nixpkgs { system = "aarch64-darwin"; };
    in
    {
      # mkShellNoCC: the build resolves clang/clang++/metal/xcodebuild via the
      # system Xcode (see src/build/AppleSdk.zig). A nix stdenv would inject a
      # different libc++ and SDK root and break the link against whisper.cpp /
      # llama.cpp.
      devShells.aarch64-darwin.default = pkgs.mkShellNoCC {
        packages = [
          pkgs.zig_0_16
          pkgs.zls
        ];
      };
    };
}
