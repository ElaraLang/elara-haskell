{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
    flake-parts.url = "github:hercules-ci/flake-parts";
    haskell-flake.url = "github:srid/haskell-flake";
    flake-root.url = "github:srid/flake-root";
    just-flake.url = "github:juspay/just-flake";
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";

    h2jvm.url = "github:ElaraLang/h2jvm";

    diagnose.url = "github:bristermitten/diagnose";
    diagnose.flake = false;

    hlint.url = "github:ndmitchell/hlint";
    hlint.flake = false;

    fourmolu.url = "github:fourmolu/fourmolu";
    fourmolu.flake = false;
  };

  outputs = inputs@{ self, pre-commit-hooks, nixpkgs, ... }:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {

      systems = import inputs.systems;

      imports = [
        inputs.haskell-flake.flakeModule
        inputs.flake-root.flakeModule
        inputs.just-flake.flakeModule
      ];

      perSystem = { self', lib, system, config, pkgs, ... }: {

        haskellProjects.default = {

          autoWire = [ "packages" "apps" "checks" ]; # Wire all but the devShell

          basePackages = pkgs.haskell.packages.ghc910;


          packages = {
            h2jvm.source = inputs.h2jvm;
            diagnose.source = inputs.diagnose;
            # megaparsec.source = inputs.megaparsec;
            polysemy-test.source = "0.10.0.0";
            hlint.source = inputs.hlint;
            fourmolu.source = inputs.fourmolu;
          };

          settings = {
            hlint.jailbreak = true;
            fourmolu.check = false;
            polysemy-test.jailbreak = true;
            polysemy-conc.jailbreak = true;
            polysemy-conc.check = false;
            polysemy-log.jailbreak = true;
            polysemy-plugin.jailbreak = true;
            incipit-base.jailbreak = true;
            incipit-core.jailbreak = true;
            polysemy-resume.jailbreak = true;
            polysemy-time.jailbreak = true;

            diagnose = {
              extraBuildDepends = [
                # pkgs.haskellPackages
              ];
              cabalFlags.megaparsec-compat = true;
              jailbreak = true;
            };

            type-errors = {
              extraSetupDepends = [ pkgs.haskellPackages.doctest ];
              extraBuildDepends = [ pkgs.haskellPackages.doctest ];
              check = false;
            };

            h2jvm = {
              # Skip the tests due to conflicting base version
              check = false;
            };

            ghcid = {
              separateBinOutput = false;
            };

            crypton-x509 = { check = false; };
          };

          devShell = {
            tools = hp: {
              # treefmt = config.treefmt.build.wrapper;
            };

            hlsCheck.enable = false;
          };
        };


        checks = {
          pre-commit-check = pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              # treefmt.package = config.treefmt.build.wrapper;
              treefmt.enable = true;
            };
          };
        };

        just-flake.features = {
          treefmt.enable = true;
        };




        packages.default = self'.packages.elara;

        devShells.default = pkgs.mkShell {
          inputsFrom = [
            config.haskellProjects.default.outputs.devShell
            config.flake-root.devShell
            config.just-flake.outputs.devShell
          ];
          inherit (self.checks.${system}.pre-commit-check) shellHook;

          nativeBuildInputs = [ pkgs.just pkgs.convco pkgs.treefmt ];

          buildInputs =
            let
              stack-wrapped = pkgs.symlinkJoin
                {
                  name = "stack"; # will be available as the usual `stack` in terminal
                  paths = [ pkgs.stack ];
                  buildInputs = [ pkgs.makeWrapper ];
                  postBuild = ''
                    wrapProgram $out/bin/stack \
                      --add-flags "\
                        --nix \
                        --system-ghc \
                        --no-install-ghc \
                      "
                  '';
                };
            in
            [
              stack-wrapped
              pkgs.haskellPackages.haskell-debug-adapter
              pkgs.haskellPackages.ghci-dap
              pkgs.haskellPackages.hpack
              pkgs.git-cliff
            ];
        };

      };
    };
}
