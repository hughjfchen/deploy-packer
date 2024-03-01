{ lib, pkgs, ... }:

let

  # unsetup the systemd service
  # inspired by setup-systemd-service
  unsetup-systemd-service =
    { units # : AttrSet String (Either Path { path : Path, wanted-by : [ String ] })
    # ^ A set whose names are unit names and values are
    # either paths to the corresponding unit files or a set
    # containing the path and the list of units this unit
    # should be wanted-by (none by default).
    #
    # The names should include the unit suffix
    # (e.g. ".service")
    , namespace # : String
    # The namespace for the unit files, to allow for
    # multiple independent unit sets managed by
    # `setupSystemdUnits`.
    }:
    let
      remove-unit-snippet = name: file: ''
        oldUnit=$(readlink -f "$unitDir/${name}" || echo "$unitDir/${name}")
        if [ -f "$oldUnit" ]; then
          unitsToStop+=("${name}")
          unitFilesToRemove+=("$unitDir/${name}")
          ${
            lib.concatStringsSep "\n" (map (unit: ''
              unitWantsToRemove+=("$unitDir/${unit}.wants/${name}")
            '') file.wanted-by or [ ])
          }
        fi
      '';
    in pkgs.writeScriptBin "unsetup-systemd-units" ''
      #!${pkgs.bash}/bin/bash -e
      export PATH=${pkgs.coreutils}/bin:${pkgs.systemd}/bin

      unitDir=/etc/systemd/system
      if [ ! -w "$unitDir" ]; then
        unitDir=/nix/var/nix/profiles/default/lib/systemd/system
      fi
      declare -a unitsToStop unitFilesToRemove unitWantsToRemove

      ${lib.concatStringsSep "\n"
      (lib.mapAttrsToList remove-unit-snippet units)}
      if [ ''${#unitsToStop[@]} -ne 0 ]; then
        echo "Stopping unit(s) ''${unitsToStop[@]}" >&2
        systemctl stop "''${unitsToStop[@]}"
        if [ ''${#unitWantsToRemove[@]} -ne 0 ]; then
           echo "Removing unit wants-by file(s) ''${unitWantsToRemove[@]}" >&2
           rm -fr "''${unitWantsToRemove[@]}"
        fi
        echo "Removing unit file(s) ''${unitFilesToRemove[@]}" >&2
        rm -fr "''${unitFilesToRemove[@]}"
      fi
      if [ -e /etc/systemd-static/${namespace} ]; then
         echo "removing systemd static namespace ${namespace}"
         rm -fr /etc/systemd-static/${namespace}
      fi
      systemctl daemon-reload
    '';

  # define some utility function for release packing ( code adapted from setup-systemd-units.nix )
  mk-release-packer = { referencePath # : Path
    # paths to the corresponding reference file
    , component # : String
    # The name for the deployed component
    # e.g., "my-postgresql", "my-postgrest"
    , site # : String
    # The name for the deployed target site
    # e.g., "my-site", "local"
    , phase # : String
    # The name for the deployed target phase
    # e.g., "local", "test", "production"
    , innerTarballName # : String
    # The name for the deployed inner tarball
    # e.g., "component"+"site"+"phase".tar.gz
    , deployScript # : Path
    # the deploy script path
    , cleanupScript # : Path
    # the cleanup script path
    }:
    let
      namespace = lib.concatStringsSep "-" [ component site phase ];
      referenceKey = lib.concatStringsSep "." [ namespace "reference" ];
      reference = lib.attrsets.setAttrByPath [ referenceKey ] referencePath;
      static = pkgs.runCommand "${namespace}-reference-file-static" { } ''
        mkdir -p $out
        ${lib.concatStringsSep "\n"
        (lib.mapAttrsToList (nm: file: "ln -sv ${file} $out/${nm}") reference)}
      '';
      gen-changed-pkgs-list = name: file: ''
        oldReference=$(readlink -f "$referenceDir/${name}" || echo "$referenceDir/${name}")
        if [ -f "$oldReference" -a "$oldReference" != "${file}" ]; then
          echo "$oldReference <-> ${file}"
          LC_ALL=C comm -13 <(LC_ALL=C sort -u $oldReference) <(LC_ALL=C sort -u "${file}") > "$referenceDir/${name}.delta"
          fileListToPack="$referenceDir/${name}.delta"
        else
          fileListToPack="${file}"
        fi
        ln -sf "/nix/var/reference-file-static/${namespace}/${name}" \
          "$referenceDir/.${name}.tmp"
        mv -T "$referenceDir/.${name}.tmp" "$referenceDir/${name}"
      '';
    in pkgs.writeScriptBin "mk-release-packer-for-${site}-${phase}" ''
      #!${pkgs.bash}/bin/bash -e
      export PATH=${pkgs.coreutils}/bin:${pkgs.gnutar}/bin:${pkgs.gzip}/bin:${pkgs.gawk}/bin:${pkgs.findutils}/bin:${pkgs.gnused}/bin:${pkgs.makeself}/bin

      fileListToPack="${referencePath}"

      referenceDir=/nix/var/reference-file
      mkdir -p "$referenceDir"

      oldStatic=$(readlink -f /nix/var/reference-file-static/${namespace} || true)
      if [ "$oldStatic" != "${static}" ]; then
        ${
          lib.concatStringsSep "\n"
          (lib.mapAttrsToList gen-changed-pkgs-list reference)
        }
        mkdir -p /nix/var/reference-file-static
        ln -sfT ${static} /nix/var/reference-file-static/.${namespace}.tmp
        mv -T /nix/var/reference-file-static/.${namespace}.tmp /nix/var/reference-file-static/${namespace}
      else
        echo "Dependence reference file not exist or unchanged, will do a full release pack" >&2
      fi

      # pack the systemd service or executable sh and dependencies with full path
      tar zPcf ./${innerTarballName} -T "$fileListToPack"

      # pack the previous tarball and the two scripts for distribution
      packDirTemp=$(mktemp -d)

      # add timestamp to the directory name and final tarball name
      # to avoid overwrite, that would make it eay to rollback to
      # any previous deployed version
      currentTimeStamp=$(date "+%Y%m%d%H%M%S")
      packDirWithTS="${namespace}-dist-$currentTimeStamp"
      packDirWithTSFull="$packDirTemp/$packDirWithTS"
      mkdir -p "$packDirWithTSFull"
      cp "${deployScript}/mk-deploy-sh" "$packDirWithTSFull/deploy-${component}-to-${site}-${phase}"
      cp "${cleanupScript}/mk-cleanup-sh" "$packDirWithTSFull/cleanup-${component}-on-${site}-${phase}"
      mv "./${innerTarballName}"  "$packDirWithTSFull"

      # tar zcf "./$packDirWithTS.tar.gz" \
      #   -C "$packDirTemp" \
      #   "packDirWithTS"

      # use makeself instead
      makeself --gzip --current "$packDirTemp" "./$packDirWithTS.sh" \
               "Deploy ${component} to ${site} ${phase} environment" \
               "$packDirWithTS/deploy-${component}-to-${site}-${phase}"
      rm -fr "$packDirTemp"

    '';
  # following script running at the target machine during deployment while nix store not available yet
  # so switch to writeTextFile to use target host bash
  mk-deploy-sh =
    { env # : AttrsSet the environment for the deployment target machine
    , payloadPath # : Path the nix path to the script which sets up the systemd service or wrapping script
    , innerTarballName # : String the tarball file name for the inner package tar
    , execName # : String the executable file name
    , startCmd ? "" # : String command line to start the program, default ""
    , stopCmd ? "" # : String command line to stop the program, default ""
    }:
    pkgs.writeTextFile rec {
      name = "mk-deploy-sh";
      executable = true;
      destination = "/${name}";
      text = ''
        #!/usr/bin/env bash

        # this script need to be run with root or having sudo permission
        [ $EUID -ne 0 ] && ! sudo echo >/dev/null 2>&1 && echo "need to run with root or sudo without password" && exit 127

        # some command fix up for systemd service, especially web server
        getent group nogroup > /dev/null || sudo groupadd nogroup

        # create user and group
        getent group "${env.processUser}" > /dev/null || sudo groupadd "${env.processUser}"
        getent passwd "${env.processUser}" > /dev/null || sudo useradd -m -p Passw0rd -g "${env.processUser}" "${env.processUser}"

        # create directories
        for dirToMk in "${env.runDir}" "${env.dataDir}"
        do
          FIRST_C=$(echo "$dirToMk" | cut -c1)

          if [ "X$FIRST_C" != "X/" ]; then
            echo "the path must be a absolute path."
            exit 111
          fi

          if [ -d "$dirToMk" ]; then
            # directory exists
            if [ $(stat --format '%U' "$dirToMk") != "${env.processUser}" ]; then
              # but belongs to other users, that should be an error
              echo "the path $dirToMk exists but owner is not the process user ${env.processUser}, abort."
              exit 110
            else
              # directory already exists and belongs to the process user
              # check if we could create files under this directory
              if ! sudo su - "${env.processUser}" -c "touch "$dirToMk"/.check.if.we.could.create.files.under.this.directory > /dev/null 2>&1"; then
                echo "Directory $dirToMk exists, owned by ${env.processUser}, however, ${env.processUser} could not create files under this dir."
                echo "Please check the mode of the whole directory tree."
                exit 111
              else
                # clean up the check
                rm -fr "$dirToMk"/.check.if.we.could.create.files.under.this.directory
              fi
            fi
          else
            # directory not exists
            NONEXIST_TOP_PATH="$dirToMk"
            NONEXIST_LAST_PATH=""
            while [ "X$NONEXIST_TOP_PATH" != "X" ] && [ ! -d "$NONEXIST_TOP_PATH" ]
            do
              NONEXIST_LAST_PATH=$(echo "$NONEXIST_TOP_PATH" | awk -F'/' '{print $NF}')
              NONEXIST_TOP_PATH=$(echo "$NONEXIST_TOP_PATH" | sed 's:\(.*\)/\(.*\)$:\1:g')
            done

            [[ "X$NONEXIST_LAST_PATH" != "X" ]] && NONEXIST_TOP_PATH=$(echo "$NONEXIST_TOP_PATH/$NONEXIST_LAST_PATH")

            sudo mkdir -p "$dirToMk"
            sudo chown -R ${env.processUser}:${env.processUser} "$NONEXIST_TOP_PATH"
            sudo chmod -R 755 "$NONEXIST_TOP_PATH"

            # Even after having changed the owner to the user from the top non-exist directory
            # We still cannot make sure the user can create files under the given directory
            # check if we could create files under this directory
            if ! sudo su - "${env.processUser}" -c "touch "$dirToMk"/.check.if.we.could.create.files.under.this.directory > /dev/null 2>&1"; then
              echo "Directory $dirToMk created and change the owner to {env.processUser}, however, ${env.processUser} could not create files under this dir."
              echo "Please check the mode of the whole directory tree from $NONEXIST_TOP_PATH and make sure the user has write permission to all directories"
              exit 111
            else
              # clean up the check
              rm -fr "$dirToMk"/.check.if.we.could.create.files.under.this.directory
            fi
          fi
        done

        # now unpack(note we should preserve the /nix/store directory structure)

        # determine the PWD
        [ "X$USER_PWD" != "X" ] && MYPWD="$USER_PWD/$(dirname $0)" || MYPWD="$(dirname $0)"

        sudo tar zPxf "$MYPWD"/${innerTarballName}

        # the /nix should belong to root
        sudo chown -R root:root /nix
        sudo chmod 555 /nix
        sudo chmod 555 /nix/store

        # save the user name of the current process
        MY_CURRENT_USER=$(id -nu)

        # setup the systemd service or create a link to the executable
        ${lib.concatStringsSep "\n" (if env.isSystemdService then
          [ "sudo ${payloadPath}/bin/setup-systemd-units" ]
        else [''
          # there is a previous version here, stop it first
          if [ -e ${env.runDir}/stop.sh ]; then
            # do not do any output, because the app may rely on its output to function properly
            # echo "stopping ${execName}"
            sudo su - "${env.processUser}" -c '${env.runDir}/stop.sh "$@"'
          fi

          # since the payload path changed for every deployment,
          # the start/stop scripts must be generated each deployment
          {
            echo "#!/usr/bin/env bash"
            echo "MY_CURRENT_USER=\$(id -nu)"
            echo "[[ \"\$MY_CURRENT_USER\" != \"${env.processUser}\" ]] && echo \"this script should be run with the user name ${env.processUser}\" && exit 127"
            echo "exec ${payloadPath}/bin/${execName} ${startCmd} \"\$@\""
          } > ${env.runDir}/start.sh
          {
            echo "#!/usr/bin/env bash"
            echo "MY_CURRENT_USER=\$(id -nu)"
            echo "[[ \"\$MY_CURRENT_USER\" != \"${env.processUser}\" ]] && echo \"this script should be run with the user name ${env.processUser}\" && exit 127"
            echo "exec ${payloadPath}/bin/${execName} ${stopCmd} \"\$@\""
          } > ${env.runDir}/stop.sh
          sudo chown -R ${env.processUser}:${env.processUser} "${env.runDir}"

          chmod +x ${env.runDir}/start.sh ${env.runDir}/stop.sh
          # do not do any output, because the app may rely on its output to function properly
          # echo "starting the program ${execName}"
          sudo su - "${env.processUser}" -c '${env.runDir}/start.sh "$@"'
          # do not do any output, because the app may rely on its output to function properly
          # echo "check the scripts under ${env.runDir} to start or stop the program."''])}

      '';
    };
  # following script running at the target machine during deployment while nix store not available yet
  # so switch to writeTextFile to use target host bash
  mk-cleanup-sh = { env # the environment for the deployment target machine
    , payloadPath # the nix path to the script which unsets up the systemd service or wrapping script
    , innerTarballName # : String the tarball file name for the inner package tar
    , execName # : String the executable file name
    }:
    pkgs.writeTextFile rec {
      name = "mk-cleanup-sh";
      executable = true;
      destination = "/${name}";
      text = ''
        #!/usr/bin/env bash

        # this script need to be run with root or having sudo permission
        [ $EUID -ne 0 ] && ! sudo echo >/dev/null 2>&1 && echo "need to run with root or sudo without password" && exit 127

        # check to make sure we are running this cleanup script after deploy script
        alreadyDeployed=""
        ${lib.concatStringsSep "\n" (if env.isSystemdService then [''
          if [ -e ${payloadPath}/bin/unsetup-systemd-units ]; then
             alreadyDeployed="true"
          else
             alreadyDeployed="false"
          fi''] else [''
            if [ -e ${env.runDir}/start.sh ] && [ -e ${env.runDir}/stop.sh ]; then
               newBinSh=$(awk '/exec/ {print $2}' "${env.runDir}/start.sh")
               if [ -e "$newBinSh" ]; then
                  alreadyDeployed="true"
               else
                  alreadyDeployed="false"
               fi
            else
               alreadyDeployed="false"
            fi
          ''])}
        [ $alreadyDeployed == "false" ] && echo "service not installed yet or installed with a previous version. please run the deploy script first." && exit 126

        # ok, the deploy script had been run now we can run the cleanup script
        echo "BIG WARNING!!!"
        echo "This script will also ERASE all data generated during the program running."
        echo "That means all data generated during the program running will be lost and cannot be restored."
        echo "Think twice before you answer Y nad hit ENTER. You have been warned."
        echo "If your are looking for how to start/stop the program,"
        echo "Refer to the following command"
        ${lib.concatStringsSep "\n" (if env.isSystemdService then [''
          serviceNames=$(awk 'BEGIN { FS="\"" } /unitsToStop\+=\(/ {print $2}' ${payloadPath}/bin/unsetup-systemd-units)
          echo "To stop - sudo systemctl stop <service-name>"
          echo "To start - sudo systemctl start <service-name>"
          echo "Where <service-name> is $serviceNames"
        ''] else [''
          echo "To stop - under the user name ${env.processUser}, run ${env.runDir}/stop.sh"
          echo "To start - under the user name ${env.processUser}, run ${env.runDir}/start.sh"
        ''])}

        read -p "Continue? (Y/N): " confirm && [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]] || exit 129

        # how do we unsetup the systemd unit? we do not unsetup the systemd service for now
        # we just stop it before doing the cleanup
        ${lib.concatStringsSep "\n" (if env.isSystemdService then [''
          sudo ${payloadPath}/bin/unsetup-systemd-units
        ''] else [''
          sudo su - "${env.processUser}" -c '${env.runDir}/stop.sh "$@"'
        ''])}

        for dirToRm in "${env.runDir}" "${env.dataDir}"
        do
          FIRST_C=$(echo "$dirToRm" | cut -c1)

          if [ "X$FIRST_C" != "X/" ]; then
            echo "the path must be a absolute path."
            exit 111
          fi

          if [ -d "$dirToRm" ]; then
            if [ $(stat --format '%U' "$dirToRm") != "${env.processUser}" ]; then
              echo "the path $dirToRm exists but owner is not the process user ${env.processUser}, abort."
              exit 110
            else
              EXIST_TOP_PATH="$dirToRm"
              EXIST_LAST_PATH=""
              while [ "X$EXIST_TOP_PATH" != "X" ] && [ -d "$EXIST_TOP_PATH" ] && [ $(stat --format '%U' "$EXIST_TOP_PATH") == "${env.processUser}" ]
              do
                EXIST_LAST_PATH=$(echo "$EXIST_TOP_PATH" | awk -F'/' '{print $NF}')
                EXIST_TOP_PATH=$(echo "$EXIST_TOP_PATH" | sed 's:\(.*\)/\(.*\)$:\1:g')
              done

              [[ "X$EXIST_LAST_PATH" != "X" ]] && EXIST_TOP_PATH=$(echo "$EXIST_TOP_PATH/$EXIST_LAST_PATH")

              sudo rm -fr "$EXIST_TOP_PATH"
            fi
          else
            echo "the path $dirToRm not exists, skip."
          fi

        done

        # FOLLOWING IS REALLY DANGEROUS!!! DO NOT DO THAT!!!
        # BECAUSE SOME DEPENDENCIES ARE SHARED BY MORE THAN ONE PACKAGE!!!
        # YOU HAVE BEEN WARNED!!!
        # do we need to delete the program and all its dependencies in /nix/store?
        # we will not do that for now

        # determine the PWD
        # [ "X$USER_PWD" != "X" ] && MYPWD="$USER_PWD/$(dirname $0)" || MYPWD="$(dirname $0)"

        # if [ -f "$MYPWD/${innerTarballName}" ]; then
        #   tar zPtvf "$MYPWD/${innerTarballName}"|awk '{print $NF}'|grep '/nix/store/'|awk -F'/' '{print "/nix/store/" $4}'|sort|uniq|xargs sudo rm -fr
        # else
        #   echo "cannot find the release tarball $MYPWD/${innerTarballName}, skip cleaning the distribute files."
        # fi

        # well, shall we remove the user and group? maybe not
        # we will do that for now.
        getent passwd "${env.processUser}" > /dev/null && sudo userdel -fr "${env.processUser}"
        getent group "${env.processUser}" > /dev/null && sudo groupdel -f "${env.processUser}"

      '';
    };
in {
  inherit unsetup-systemd-service mk-release-packer mk-deploy-sh mk-cleanup-sh;
}
