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
            borgbackup
            git
            gnupg
            openssh
            sshpass
            rsync
            yq-go
            lefthook
          ];

          shellHook = ''
            ansible-galaxy collection install --upgrade \
              --collections-path ./collections \
              community.sops community.docker community.general ansible.posix \
              > /dev/null 2>&1 &
          '';
        };
      });
}
