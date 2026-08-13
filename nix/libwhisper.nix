{
  lib,
  stdenv,
  callPackage,
  # Must be a zig whose native libc detection works inside the build sandbox.
  # nixpkgs' zig_0_16 is patched for that; an unpatched upstream build (e.g. from
  # zig-overlay) falls back to musl headers here and fails to compile ggml.
  zig,
  optimize ? "ReleaseFast",
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "libwhisper";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../build.zig.zon.nix
      ../examples
      ../include
      ../pkg
      ../src
    ];
  };

  # build.zig.zon.nix is generated from build.zig.zon by zon2nix, which is in the
  # dev shell. Deriving the pins instead of restating them is what makes drift
  # between the Nix and Zig views of a dependency impossible; regenerate it in the
  # same commit as any build.zig.zon dependency change.
  deps = callPackage ../build.zig.zon.nix {
    name = "libwhisper-cache-${finalAttrs.version}";
  };

  nativeBuildInputs = [ zig ];

  dontConfigure = true;

  preBuild = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
  '';

  # --system points Zig at the prebuilt package set, which is what keeps the
  # build offline: whisper.cpp and llama.cpp are lazy dependencies, so without it
  # Zig would try to fetch them mid-build.
  buildPhase = ''
    runHook preBuild
    zig build libwhisper \
      --system "${finalAttrs.deps}" \
      -Doptimize=${optimize} \
      --prefix "$out"
    runHook postBuild
  '';

  # Runs the Zig unit tests and the C ABI smoke test in examples/c-smoke, which
  # links the same combined static archive that gets installed.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    zig build test-libwhisper \
      --system "${finalAttrs.deps}" \
      -Doptimize=${optimize}
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
})
