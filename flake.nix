{
  description = "flake-input-watcher — standalone Bash application";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      eachSystem = nixpkgs.lib.genAttrs systems;
      mkPkgs = system: import nixpkgs { inherit system; };
    in
    {
      packages = eachSystem (
        system:
        let
          pkgs = mkPkgs system;
          package = pkgs.callPackage ./nix/package.nix { };
        in
        {
          default = package;
          flake-input-watcher = package;
        }
      );
      apps = eachSystem (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/flake-input-watcher";
        };
        flake-input-watcher = self.apps.${system}.default;
      });
      homeManagerModules.default = import ./nix/home-manager.nix;
      formatter = eachSystem (system: (mkPkgs system).nixfmt);
      devShells = eachSystem (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              bash
              git
              jq
              coreutils
              util-linux
              libnotify
              python3
              ripgrep
              gnused
              shellcheck
              nixfmt
            ];
          };
        }
      );
      checks = eachSystem (
        system:
        let
          pkgs = mkPkgs system;
          passed = import ./tests/module.nix {
            inherit pkgs;
            homeManager = inputs.home-manager.outPath;
          };
        in
        {
          default =
            assert passed;
            pkgs.runCommand "flake-input-watcher-checks"
              {
                nativeBuildInputs = with pkgs; [
                  bash
                  git
                  jq
                  coreutils
                  util-linux
                  libnotify
                  python3
                  ripgrep
                  gnused
                  shellcheck
                  nixfmt
                ];
                application = self.packages.${system}.default;

              }
              ''
                cp -R ${./.} source
                chmod -R u+w source

                cd source
                patchShebangs src tests
                export PATH="$PWD/src:$PATH"
                "$application/bin/flake-input-watcher" --help
                shellcheck src/* tests/check.sh
                for file in src/* tests/check.sh; do bash -n "$file"; done
                nixfmt --check flake.nix nix/*.nix tests/module.nix
                bash tests/check.sh
                touch "$out"
              '';
        }
      );
    };
}
