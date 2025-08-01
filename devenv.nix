{ inputs
, pkgs
, lib
, config
, ...
}:
{
  env = {
    DEVENV_NIX = inputs.nix.packages.${pkgs.stdenv.system}.nix-cli;
    # ignore annoying browserlists warning that breaks pre-commit hooks
    BROWSERSLIST_IGNORE_OLD_DATA = "1";
    RUST_LOG = "devenv=debug";
    RUST_LOG_SPAN_EVENTS = "full";
    DATABASE_URL = "sqlite:.devenv/nix-eval-cache.db";
  };

  apple.sdk = if pkgs.stdenv.isDarwin then pkgs.apple-sdk_11 else null;


  claude.code = {
    enable = true;
    permissions = {
      WebFetch = {
        allow = [ "domain:github.com" "domain:docs.rs" "domain:docs.anthropic.com" ];
      };
      Bash = {
        allow = [ "rg:*" "cargo test:*" "nix search:*" "devenv-run-tests:*" "nix-instantiate:*" ];
      };
    };
  };

  packages = [
    pkgs.cairo
    pkgs.git
    pkgs.xorg.libxcb
    pkgs.yaml2json
    pkgs.tesh
    pkgs.watchexec
    pkgs.openssl
    pkgs.sqlx-cli
    pkgs.process-compose
    pkgs.cargo-outdated # Find outdated crates
    pkgs.cargo-machete # Find unused crates
    pkgs.cargo-edit # Adds the set-version command
    pkgs.protobuf # snix
    pkgs.dbus # secretspec
  ];

  languages = {
    nix.enable = true;
    # for cli
    rust.enable = true;
    # for docs
    python = {
      enable = true;
      # speed it up
      uv.enable = true;
      venv = {
        enable = true;
        requirements = ./requirements.txt;
      };
    };
    javascript = {
      enable = true;
      npm = {
        enable = true;
        install.enable = true;
      };
    };
  };

  devcontainer = {
    enable = true;
    settings.customizations.vscode.extensions = [ "jnoortheen.nix-ide" ];
  };
  difftastic.enable = true;

  processes = {
    docs.exec = "mkdocs serve";
    tailwind.exec = "watchexec -e html,css,js devenv-generate-doc-css";
  };

  scripts.devenv-test-cli = {
    description = "Test devenv CLI.";
    exec = ''
      set -xe
      set -o pipefail

      tmp="$(mktemp -d)"
      devenv init "$tmp"
      pushd "$tmp"
        devenv version
        devenv --override-input devenv path:${config.devenv.root}?dir=src/modules test
      popd
      rm -rf "$tmp"

      # Test devenv init with target path
      tmp="$(mktemp -d)"
      pushd "$tmp"
        devenv init target
        test -z "$(ls -A1 | grep -v target)"
        pushd target
          devenv --override-input devenv path:${config.devenv.root}?dir=src/modules test
        popd
      popd
      rm -rf "$tmp"

      # Test devenv integrated into bare Nix flake
      tmp="$(mktemp -d)"
      pushd "$tmp"
        nix flake init --template ''${DEVENV_ROOT}#simple
        nix flake update \
          --override-input devenv ''${DEVENV_ROOT}
        nix develop --accept-flake-config --no-pure-eval --command echo nix-develop started succesfully |& tee ./console
        grep -F 'nix-develop started succesfully' <./console
        grep -F "$(${lib.getExe pkgs.hello})" <./console

        # Assert that nix-develop fails in pure mode.
        if nix develop --command echo nix-develop started in pure mode |& tee ./console
        then
          echo "nix-develop was able to start in pure mode. This is explicitly not supported at the moment."
          exit 1
        fi
        grep -F 'devenv was not able to determine the current directory.' <./console
      popd
      rm -rf "$tmp"

      # Test devenv integrated into flake-parts Nix flake
      tmp="$(mktemp -d)"
      pushd "$tmp"
        nix flake init --template ''${DEVENV_ROOT}#flake-parts
        nix flake update \
          --override-input devenv ''${DEVENV_ROOT}
        nix develop --accept-flake-config --override-input devenv-root "file+file://"<(printf %s "$PWD") --command echo nix-develop started succesfully |& tee ./console
        grep -F 'nix-develop started succesfully' <./console
        grep -F "$(${lib.getExe pkgs.hello})" <./console
        # Test that a container can be built
        if [ "$(uname)" = "Linux" ]
        then
          nix build --override-input devenv-root "file+file://"<(printf %s "$PWD") --accept-flake-config --show-trace .#container-processes
        fi
      popd
      rm -rf "$tmp"
    '';
  };
  scripts."devenv-generate-doc-css" = {
    description = "Generate CSS for the docs.";
    exec = "${lib.getExe pkgs.tailwindcss} -m -i docs/assets/extra.css -o docs/assets/output.css";
  };
  scripts."devenv-generate-doc-options" = {
    description = "Generate option docs.";
    exec = ''
      set -e
      output_file=docs/reference/options.md
      options=$(nix build --accept-flake-config --no-pure-eval --extra-experimental-features 'flakes nix-command' --show-trace --print-out-paths --no-link '.#devenv-docs-options')
      echo "[comment]: # (DO NOT MODIFY. This file was generated by devenv-generate-doc-options.)" > $output_file
      echo "# devenv.nix" >> $output_file
      echo >> $output_file
      cat $options >> $output_file
      # https://github.com/NixOS/nixpkgs/issues/224661
      sed -i 's/\\\././g' $output_file
    '';
  };
  scripts."devenv-generate-languages-example" = {
    description = "Generate an example enabling every supported language.";
    exec = ''
      cat > examples/supported-languages/devenv.nix <<EOF
      # DO NOT MODIFY.
      # This file was generated bu devenv-generate-languages-example.
      { pkgs, ... }: {

        # Enable all languages tooling!
        ${lib.concatStringsSep "\n  " (
          map (lang: "languages.${lang}.enable = true;") (builtins.attrNames config.languages)
        )}

        # If you're missing a language, please contribute it by following examples of other languages <3
      }
      EOF
    '';
  };
  scripts."devenv-generate-docs" = {
    description = "Generate lists of all languages and services.";
    exec = ''
      cat > docs/snippets/services-all.md <<EOF
        \`\`\`nix
        ${lib.concatStringsSep "\n  " (
          map (lang: "services.${lang}.enable = true;") (builtins.attrNames config.services)
        )}
        \`\`\`
      EOF
      cat > docs/snippets/languages-all.md <<EOF
        \`\`\`nix
        ${lib.concatStringsSep "\n  " (
          map (lang: "languages.${lang}.enable = true;") (builtins.attrNames config.languages)
        )}
        \`\`\`
      EOF
    '';
  };
  scripts."devenv-generate-individual-docs" = {
    description = "Generate individual docs of all devenv modules";
    exec = ''
      mkdir -p docs/{supported-languages,supported-services,supported-process-managers}

      nix build --no-pure-eval --extra-experimental-features 'flakes nix-command' --show-trace --print-out-paths '.#devenv-generate-individual-docs'
      cp -r --no-preserve=all result/docs/individual-docs/* docs/
    '';
  };

  scripts."devenv-verify-individual-docs" = {
    description = "Generate missing template markdown files";
    exec = ''

          process_directory() {
            local nix_dir=$1
            local md_dir=$2
            local category=$3

            nixFiles=($(ls $nix_dir/*.nix))
            mdFiles=($(ls $md_dir/*.md))

            declare -a nixList
            declare -a mdList

            # Remove extensions and populate lists
            for file in "''${nixFiles[@]}"; do
              baseName=$(basename "$file" .nix)
              nixList+=("$baseName")
            done

            for file in "''${mdFiles[@]}"; do
              baseName=$(basename "$file" .md)
              mdList+=("$baseName")
            done

            IFS=$'\n' sorted_nix=($(sort <<<"''${nixList[*]}"))
            IFS=$'\n' sorted_md=($(sort <<<"''${mdList[*]}"))

            # Compare and create missing files
            missing_files=()
            for item in "''${sorted_nix[@]}"; do
              if [[ ! " ''${sorted_md[@]} " =~ " $item " ]]; then
                missing_files+=("$item")
                cat << EOF > "$md_dir/$item.md"


      [comment]: # (Please add your documentation on top of this line)

      @AUTOGEN_OPTIONS@
      EOF
                echo "Created missing file: $md_dir/$item.md"
              fi
            done

            if [ ''${#missing_files[@]} -eq 0 ]; then
              echo "All $category docs markdown files are present."
            fi
          }

          process_directory "src/modules/languages" "docs/individual-docs/languages" "language"
          process_directory "src/modules/services" "docs/individual-docs/services" "service"
          process_directory "src/modules/process-managers" "docs/individual-docs/process-managers" "process manager"
    '';
  };

  tasks = {
    "devenv:compile-requirements" = {
      before = [ "devenv:python:virtualenv" ];
      exec = "uv pip compile requirements.in -o requirements.txt";
      execIfModified = [
        "requirements.in"
        "requirements.txt"
      ];
    };
  };

  git-hooks.hooks = {
    nixpkgs-fmt.enable = true;
    rustfmt.enable = true;
    markdownlint = {
      settings.configuration = {
        MD013 = {
          line_length = 120;
        };
        MD033 = false;
        MD034 = false;
      };
    };
    generate-doc-css = {
      enable = true;
      name = "generate-doc-css";
      entry = config.scripts."devenv-generate-doc-css".exec;
      files = "docs/assets/extra.css";
    };
  };
}
