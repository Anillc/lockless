{
  inputs.substituter-api.url = "github:Anillc/substituter-api";
  outputs = inputs@{
    self, nixpkgs, flake-parts, substituter-api, ...
  }: flake-parts.lib.mkFlake { inherit inputs; } {
    systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    transposition.lib.adHoc = true;
    perSystem = { pkgs, self', ... }: {
      imports = [ ./lockless.nix ];
      packages.default = self'.lib.mkNodeModules {
        date = "2026-10-01T00:00:00Z";
        package = {
          name = "lockless-demo";
          version = "0.0.0";
          dependencies.lodash = "^4.17.0";
        };
      };
      devShells.default = pkgs.mkShell {
        nativeBuildInputs = with pkgs; [ nodejs curl ];
      };
    };
  };
}
