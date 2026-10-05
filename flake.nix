{
  description = "flake-input-watcher — standalone Bash application";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs =
    { self, nixpkgs, ... }:
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
              shellcheck
              nixfmt
            ];
          };
        }
      );
      # Building writeShellApplication already checks Bash syntax and ShellCheck.
      checks = eachSystem (system: {
        default = self.packages.${system}.default;
      });
    };
}
