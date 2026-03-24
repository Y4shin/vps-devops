{
  description = "VPS DevOps shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            go-task
            sops
            age
            ansible
            git
            openssh
            sshpass
            rsync
          ];

          shellHook = ''
            ansible-galaxy collection install --upgrade \
              community.sops community.docker community.general ansible.posix \
              > /dev/null 2>&1 &
          '';
        };
      });
}
