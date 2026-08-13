{
  lib,
  stdenv,
  fetchFromGitHub,
  # Must be a zig whose native libc detection works inside the build sandbox.
  # nixpkgs' zig_0_16 is patched for that; an unpatched upstream build (e.g. from
  # zig-overlay) falls back to musl headers here and fails to compile ggml.
  zig,
  optimize ? "ReleaseFast",
}:
let
  deps = import ./deps.nix;
  sources = lib.mapAttrs (
    _name: dep:
    fetchFromGitHub {
      inherit (dep)
        owner
        repo
        rev
        hash
        ;
    }
  ) deps;

  # Zig 0.16 resolves dependencies from a project-local zig-pkg/<hash>
  # directory, so staging the fetched sources there is what keeps the build
  # offline. No `ar` or `libtool` is needed: CombineArchivesStep drives `zig ar`.
  stageDeps = lib.concatMapStringsSep "\n" (
    name: ''ln -s "${sources.${name}}" "zig-pkg/${deps.${name}.zigHash}"''
  ) (lib.attrNames deps);
in
stdenv.mkDerivation {
  pname = "libwhisper";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../examples
      ../include
      ../pkg
      ../src
    ];
  };

  nativeBuildInputs = [ zig ];

  dontConfigure = true;

  preBuild = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    mkdir -p zig-pkg
    ${stageDeps}
  '';

  buildPhase = ''
    runHook preBuild
    zig build libwhisper -Doptimize=${optimize} --prefix "$out"
    runHook postBuild
  '';

  # Runs the Zig unit tests and the C ABI smoke test in examples/c-smoke, which
  # links the same combined static archive that gets installed.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    zig build test-libwhisper -Doptimize=${optimize}
    runHook postCheck
  '';

  # `--prefix` above already installs into $out.
  dontInstall = true;

  meta = {
    description = "UI-independent local Whisper transcription library";
    homepage = "https://github.com/polymath-as/bobrwhisper";
    license = lib.licenses.bsl11;
    platforms = lib.platforms.unix;
  };
}
