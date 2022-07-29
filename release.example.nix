{ nativePkgs ? import ./default.nix { }, # the native package set
pkgs ? import ./cross-build.nix { }
, # the package set for corss build, we're especially interested in the fully static binary
site, # the site for release, the binary would deploy to it finally
phase, # the phase for release, must be "local", "test" and "production"
}:
let
  nPkgs = nativePkgs.pkgs;
  sPkgs = pkgs.x86-musl64; # for the fully static build
  lib = nPkgs.lib; # lib functions from the native package set
  pkgName = "my-runner";
  innerTarballName = lib.concatStringsSep "." [
    (lib.concatStringsSep "-" [ pkgName site phase ])
    "tar"
    "gz"
  ];

  # define some utility function for release packing ( code adapted from setup-systemd-units.nix )
  deploy-packer = import ./deploy-packer.nix {
    inherit lib;
    pkgs = nPkgs;
  };

  # the deployment env
  my-runner-env = (import
    (builtins.fetchGit { url = "https://github.com/hughjfchen/deploy-env"; }) {
      pkgs = nPkgs;
      modules = [
        ./site/${site}/phase/${phase}/db.nix
        ./site/${site}/phase/${phase}/db-gw.nix
        ./site/${site}/phase/${phase}/api-gw.nix
        ./site/${site}/phase/${phase}/messaging.nix
        ./site/${site}/phase/${phase}/runner.nix
      ];
    }).env;

  # app and dependent config
  my-runner-config = (import (builtins.fetchGit {
    url = "https://github.com/hughjfchen/deploy-config";
  }) {
    pkgs = nPkgs;
    modules = [
      ./site/${site}/phase/${phase}/db.nix
      ./site/${site}/phase/${phase}/db-gw.nix
      ./site/${site}/phase/${phase}/api-gw.nix
      ./site/${site}/phase/${phase}/messaging.nix
      ./site/${site}/phase/${phase}/runner.nix
    ];
    env = my-runner-env;
  }).config;

  my-runner-config-kv = nPkgs.writeTextFile {
    name = lib.concatStringsSep "-" [ pkgName "config" ];
    # generate the key = value format config, refer to the lib.generators for other formats
    text = (lib.generators.toKeyValue { }) my-runner-config.runner;
  };
  my-runner-bin-sh-paths = [
    # list the runtime dependencies, especially those cannot be determined by nix automatically
    nPkgs.wget
    nPkgs.curl
    nPkgs.xvfb-run
    nPkgs.jdk11
    nPkgs.eclipse-mat
    sPkgs.java-analyzer-runner.java-analyzer-runner-exe
  ];
  my-runner-bin-sh = nPkgs.writeShellApplication {
    name = lib.concatStringsSep "-" [ pkgName "bin" "sh" ];
    runtimeInputs = my-runner-bin-sh-paths;
    # wrap the executable, suppose it accept a --config commandl ine option to load the config
    text = ''
      ${sPkgs.java-analyzer-runner.java-analyzer-runner-exe.exeName} --config.file="${my-runner-config-kv}" "$@"
    '';
  };
  # following define the service
  my-runner-service = { lib, pkgs, config, ... }: {
    options = lib.attrsets.setAttrByPath [ "services" pkgName ] {
      enable = lib.mkOption {
        default = true;
        type = lib.types.bool;
        description = "enable to generate a config to start the service";
      };
      # add extra options here, if any
    };
    config = lib.mkIf
      (lib.attrsets.getAttrFromPath [ pkgName "enable" ] config.services)
      (lib.attrsets.setAttrByPath [ "systemd" "services" pkgName ] {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        description = "${pkgName} service";
        serviceConfig = {
          Type = "forking";
          User = "${my-runner-env.runner.processUser}";
          ExecStart =
            "${my-runner-bin-sh}/bin/${my-runner-bin-sh.name} --command=Start";
          Restart = "on-failure";
        };
      });
  };

  serviceNameKey = lib.concatStringsSep "." [ pkgName "service" ];
  serviceNameUnit =
    lib.attrsets.setAttrByPath [ serviceNameKey ] mk-my-runner-service-unit;

  mk-my-runner-service-unit = nPkgs.writeText serviceNameKey
    (lib.attrsets.getAttrFromPath [
      "config"
      "systemd"
      "units"
      serviceNameKey
      "text"
    ] (nPkgs.nixos
      ({ lib, pkgs, config, ... }: { imports = [ my-runner-service ]; })));

in rec {
  inherit nativePkgs pkgs;
  mk-my-runner-service-systemd-setup-or-bin-sh =
    if my-runner-env.runner.isSystemdService then
      (nPkgs.setupSystemdUnits {
        namespace = pkgName;
        units = serviceNameUnit;
      })
    else
      my-runner-bin-sh;

  mk-my-runner-service-systemd-unsetup-or-bin-sh =
    if my-runner-env.runner.isSystemdService then
      (deploy-packer.unsetup-systemd-service {
        namespace = pkgName;
        units = serviceNameUnit;
      })
    else
      { };
  # following derivation just to make sure the setup and unsetup will
  # be packed into the distribute tarball.
  setup-and-unsetup-or-bin-sh = nPkgs.symlinkJoin {
    name = "my-runner-setup-and-unsetup";
    paths = [
      mk-my-runner-service-systemd-setup-or-bin-sh
      mk-my-runner-service-systemd-unsetup-or-bin-sh
    ];
  };

  mk-my-runner-reference =
    nPkgs.writeReferencesToFile setup-and-unsetup-or-bin-sh;

  mk-my-runner-deploy-sh = deploy-packer.mk-deploy-sh {
    env = my-runner-env.runner;
    payloadPath = setup-and-unsetup-or-bin-sh;
    inherit innerTarballName;
    execName = "${my-runner-bin-sh.name}";
    startCmd = "--command=Start";
    stopCmd = "--command=Stop";
  };
  mk-my-runner-cleanup-sh = deploy-packer.mk-cleanup-sh {
    env = my-runner-env.runner;
    payloadPath = setup-and-unsetup-or-bin-sh;
    inherit innerTarballName;
    execName = "${my-runner-bin-sh.name}";
  };
  mk-my-release-packer = deploy-packer.mk-release-packer {
    referencePath = mk-my-runner-reference;
    component = pkgName;
    inherit site phase innerTarballName;
    deployScript = mk-my-runner-deploy-sh;
    cleanupScript = mk-my-runner-cleanup-sh;
  };

}
