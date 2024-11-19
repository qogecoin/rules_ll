{
  description = "rules_ll development environment";

  inputs = {
    nixpkgs = {
      url = "github:nixos/nixpkgs";

      # This needs to follow the `nixpkgs` from nativelink so that the local LRE
      # toolchains are in sync with the remote toolchains.
      follows = "nativelink/nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
    git-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    nativelink = {
      # Note: Keep this commit in sync with the LRE commit in `ll/init.bzl`.
      url = "github:TraceMachina/nativelink/481226be52a84ad5a6b990cc48e9f97512d8ccd2";

      # This repository provides the autogenerated LRE toolchains which are
      # dependent on the nixpkgs version in the nativelink repository. To keep
      # the local LRE toolchains aligned with remote LRE, we need to use the
      # nixpkgs used by nativelink as the the "global" nixpkgs. We do this by
      # setting `nixpkgs.follows = "nativelink/nixpkgs"` above.

      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-parts.follows = "flake-parts";
      inputs.git-hooks.follows = "git-hooks";
    };
  };

  nixConfig = {
    bash-prompt-prefix = "(rules_ll) ";
    bash-prompt = ''\[\033]0;\u@\h:\w\007\]\[\033[01;32m\]\u@\h\[\033[01;34m\] \w \$\[\033[00m\]'';
    bash-prompt-suffix = " ";
  };

  outputs =
    { self
    , flake-parts
    , flake-utils
    , nativelink
    , nixpkgs
    , git-hooks
    , ...
    } @ inputs:
    flake-parts.lib.mkFlake { inherit inputs; }
      {
        systems = [
          "x86_64-linux"
        ];
        imports = [
          inputs.git-hooks.flakeModule
          inputs.nativelink.flakeModule.local-remote-execution
          ./flake-module.nix
        ];
        perSystem =
          { config
          , pkgs
          , system
          , lib
          , ...
          }:
          {
            _module.args.pkgs = import self.inputs.nixpkgs {
              inherit system;
              # CUDA support
              config.allowUnfree = true;
              config.cudaSupport = true;
            };
            local-remote-execution.settings = {
              inherit (nativelink.packages.${system}.lre-cc.meta) Env;
            };
            pre-commit.settings = {
              hooks = import ./pre-commit-hooks.nix { inherit pkgs; };
            };
            rules_ll.settings.llEnv =
              let
                openssl = (pkgs.openssl.override { static = true; });
              in
              self.lib.defaultLlEnv {
                inherit pkgs;
                LL_CFLAGS = "-I${openssl.dev}/include";
                LL_LDFLAGS = "-L${openssl.out}/lib";
              };
            packages = {
              # TODO(aaronmondal): The nativelink devcluster mounts the current
              # git repository into the kind nodes and derives the lre-cc worker
              # tag from this target. Consider changing this upstream.
              lre-cc = nativelink.packages.${system}.lre-cc;
              ll = import ./devtools/ll.nix {
                inherit pkgs;
                native = inputs.nativelink.packages.${system}.native-cli;
              };
            };
            devShells.default = pkgs.mkShell {
              nativeBuildInputs =
                let
                  bazel = pkgs.writeShellScriptBin "bazel" ''
                    unset TMPDIR TMP
                    exec ${pkgs.bazelisk}/bin/bazelisk "$@"
                  '';
                in
                [
                  bazel
                  self.packages.${system}.ll
                  pkgs.git
                  (pkgs.python3.withPackages (pylib: [
                    pylib.mkdocs-material
                  ]))
                  pkgs.mkdocs
                  pkgs.vale
                  pkgs.go

                  # Cloud tooling
                  pkgs.cilium-cli
                  pkgs.kubectl
                  pkgs.pulumi
                  pkgs.skopeo
                  pkgs.tektoncd-cli
                  pkgs.fluxcd
                  pkgs.kustomize
                ];
              shellHook = ''
                # Generate the .pre-commit-config.yaml symlink when entering the
                # development shell.
                ${config.pre-commit.installationScript}

                # Generate .bazelrc.ll which contains Bazel configuration
                # when rules_ll is run from a nix environment.
                ${config.rules_ll.installationScript}

                # Generate .bazelrc.lre which configures the LRE toolchains.
                ${config.local-remote-execution.installationScript}

                # Ensure that the ll command points to our ll binary.
                [[ $(type -t ll) == "alias" ]] && unalias ll

                # Ensure that the bazel command points to our custom wrapper.
                [[ $(type -t bazel) == "alias" ]] && unalias bazel

                # Prettier color output for the ls command.
                alias ls='ls --color=auto'
              '';
            };
          };
      } // {
      templates = {
        default = {
          path = "${./templates/default}";
          description = "A basic rules_ll workspace";
        };
      };
      flakeModule = ./flake-module.nix;
      lib = { defaultLlEnv = import ./modules/defaultLlEnv.nix; };
    };
}
