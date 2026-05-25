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
            fzf
            lefthook
            hcloud
            opentofu
            ansible-lint
            yamllint
            (python3.withPackages (ps: [ ps.hcloud ps.jinja2 ps.pyyaml ]))
          ];

          shellHook = ''
            # Install pinned collections from ansible/requirements.yml (no --upgrade,
            # so versions stay reproducible). This is our reproducibility mechanism
            # in lieu of a containerized Execution Environment.
            ansible-galaxy collection install -r ansible/requirements.yml \
              --collections-path ./collections \
              > /dev/null 2>&1 &
          '';
        };
      });
}
