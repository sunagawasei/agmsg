{
  description = "agmsg test/dev shell — bats + sqlite3 for the tests/ suite";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # `nix develop` (or direnv via .envrc) drops you into a shell with the test
      # toolchain on PATH — bats-core and the sqlite3 CLI the suite shells out to.
      # Node lives in the global home-manager dev.nix, so it is intentionally not
      # duplicated here.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.bats pkgs.sqlite ];
        };
      });
    };
}
