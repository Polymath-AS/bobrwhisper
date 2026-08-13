# Dependency pins for the Nix build of libwhisper.
#
# `rev` and `zigHash` MUST match build.zig.zon. The Nix build stages each source
# under zig-pkg/<zigHash>, and Zig trusts a package directory whose name matches
# the expected hash without re-verifying its contents — so a stale rev here would
# silently build against the wrong source rather than fail. The `dep-pins` flake
# check greps build.zig.zon for both values to catch that drift.
#
# `hash` is Nix's own content hash of the fetch, and has no counterpart in
# build.zig.zon; bumping a rev will make Nix report the new value to use.
{
  whisper = {
    owner = "ggml-org";
    repo = "whisper.cpp";
    rev = "941bdabbe4561bc6de68981aea01bc5ab05781c5";
    zigHash = "N-V-__8AAOZW0gHObmNEfr6yNdj1vYHEp_QdWYYTCkpmDGxk";
    hash = "sha256-NPwxTETy3QU8Pf1/KHaReog7fH8OZha5Mx0lEEqCAyY=";
  };

  llama = {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = "b828e18c75137e29fbfd3f3daa38281172d6a636";
    zigHash = "N-V-__8AACHBrgf72Ho6yyKd9uE9m1LZjfTqNX64koIcguF8";
    hash = "sha256-rA5c3jQjO77c4zX+jqd+a3CJbemthVAdyqRc5ChxCzM=";
  };
}
