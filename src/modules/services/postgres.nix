{ pkgs
, lib
, config
, ...
}:
let
  cfg = config.services.postgres;
  inherit (lib) types;

  q = lib.escapeShellArg;

  runtimeDir = "${config.env.DEVENV_RUNTIME}/postgres";

  parseListenAddresses = input:
    let
      convertSpecialValue = value:
        if value == "*" || value == "0.0.0.0" then "127.0.0.1"
        else if value == "::" then "::1"
        else value;
    in
    lib.pipe input [
      (lib.splitString ",")
      (map lib.trim)
      (map convertSpecialValue)
      (builtins.filter (x: x != ""))
    ];

  # Fetch the first element of a list or return null if the list is empty.
  headWithDefault = default: input:
    if input == [ ]
    then default
    else builtins.head input;

  postgresPkg =
    if cfg.extensions != null
    then
      if builtins.hasAttr "withPackages" cfg.package
      then cfg.package.withPackages cfg.extensions
      else
        builtins.throw ''
          Cannot add extensions to the PostgreSQL package.
          `services.postgres.package` is missing the `withPackages` attribute. Did you already add extensions to the package?
        ''
    else cfg.package;

  # TODO: we can probably clean this up a lot by delegating more "if exists" stuff to psql (à la `DO $$...$$` below)
  setupInitialDatabases =
    if cfg.initialDatabases != [ ]
    then
      (lib.concatMapStrings
        (database:
          let
            psqlUserFlags =
              if (database.user != null && database.pass != null)
              then "--user ${database.user}"
              else "";
          in
          ''
            echo "Checking presence of database: ${database.name}"
            # Create initial databases
            dbAlreadyExists="$(
              echo "SELECT 1 AS exists FROM pg_database WHERE datname = '${database.name}';" | \
              psql --dbname postgres | \
              ${pkgs.gnugrep}/bin/grep -c 'exists = "1"' || true
            )"
            echo $dbAlreadyExists
            if [ 1 -ne "$dbAlreadyExists" ]; then
              echo "Creating database: ${database.name}"
              echo 'CREATE DATABASE "${database.name}";' | psql --dbname postgres
              ${lib.optionalString (database.user != null && database.pass != null) ''
              echo "Creating role ${database.user}..."
              psql --dbname postgres <<'EOF'
              DO $$
                  BEGIN
                      CREATE ROLE "${database.user}" WITH LOGIN PASSWORD '${database.pass}';
                      EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
                  END
              $$;
              GRANT ALL PRIVILEGES ON DATABASE "${database.name}" TO "${database.user}";
              \c ${database.name}
              GRANT ALL PRIVILEGES ON SCHEMA public TO "${database.user}";
              EOF
            ''}
              if [ ${q database.initialSQL} != null ]
              then
                echo "Running initial SQL on database ${database.name}"
                echo ${q database.initialSQL} | psql --dbname ${database.name}
              fi
              ${lib.optionalString (database.schema != null) ''
              echo "Applying database schema on ${database.name}"
              if [ -f "${database.schema}" ]
              then
                echo "Running file ${database.schema}"
                ${pkgs.gawk}/bin/awk 'NF' "${database.schema}" | psql ${psqlUserFlags} --dbname ${database.name}
              elif [ -d "${database.schema}" ]
              then
                # Read sql files in version order. Apply one file
                # at a time to handle files where the last statement
                # doesn't end in a ;.
                ls -1v "${database.schema}"/*.sql | while read f ; do
                   echo "Applying sql file: $f"
                   ${pkgs.gawk}/bin/awk 'NF' "$f" | psql ${psqlUserFlags} --dbname ${database.name}
                done
              else
                echo "ERROR: Could not determine how to apply schema with ${database.schema}"
                exit 1
              fi
            ''}
            fi
          '')
        cfg.initialDatabases)
    else
      lib.optionalString cfg.createDatabase ''
        psql --dbname postgres << EOF
        CREATE DATABASE "''${USER:-$(id -nu)}";
        EOF
      '';

  runInitialScript =
    if cfg.initialScript != null
    then ''
      echo ${q cfg.initialScript} | psql --dbname postgres
    ''
    else "";

  toStr = value:
    if true == value
    then "yes"
    else if false == value
    then "no"
    else if lib.isString value
    then "'${lib.replaceStrings ["'"] ["''"] value}'"
    else toString value;

  configFile =
    pkgs.writeText "postgresql.conf" (lib.concatStringsSep "\n"
      (lib.mapAttrsToList (n: v: "${n} = ${toStr v}") cfg.settings));
  setupPgHbaFileScript =
    if cfg.hbaConf != null
    then
      let
        file = pkgs.writeText "pg_hba.conf" cfg.hbaConf;
      in
      ''cp ${file} "$PGDATA/pg_hba.conf"''
    else "";
  setupScript = pkgs.writeShellScriptBin "setup-postgres" ''
    set -euo pipefail
    export PATH=${postgresPkg}/bin:${pkgs.coreutils}/bin

    POSTGRES_RUN_INITIAL_SCRIPT="false"
    if [[ ! -d "$PGDATA" ]]; then
      initdb ${lib.concatStringsSep " " cfg.initdbArgs}
      POSTGRES_RUN_INITIAL_SCRIPT="true"
      echo
      echo "PostgreSQL initdb process complete."
      echo
    fi

    # Setup config
    cp ${configFile} "$PGDATA/postgresql.conf"

    # Setup pg_hba.conf
    ${setupPgHbaFileScript}

    if [[ "$POSTGRES_RUN_INITIAL_SCRIPT" = "true" ]]; then
      echo
      echo "PostgreSQL is setting up the initial database."
      echo
      OLDPGHOST="$PGHOST"
      PGHOST=${q runtimeDir}

      pg_ctl -D "$PGDATA" -w start -o "-c unix_socket_directories=${runtimeDir} -c listen_addresses= -p ${toString cfg.port}"
      ${setupInitialDatabases}

      ${runInitialScript}
      pg_ctl -D "$PGDATA" -m fast -w stop
      PGHOST="$OLDPGHOST"
      unset OLDPGHOST
    else
      echo
      echo "PostgreSQL database directory appears to contain a database; Skipping initialization"
      echo
    fi
    unset POSTGRES_RUN_INITIAL_SCRIPT

    # Create a file marker to indicate PostgreSQL has completed initialization
    touch "$PGDATA/.devenv_initialized"
  '';
  startScript = pkgs.writeShellScriptBin "start-postgres" ''
    set -euo pipefail
    mkdir -p ${q runtimeDir}
    ${setupScript}/bin/setup-postgres
    exec ${postgresPkg}/bin/postgres
  '';
in
{
  imports = [
    (lib.mkRenamedOptionModule [ "postgres" "enable" ] [
      "services"
      "postgres"
      "enable"
    ])
  ];

  options.services.postgres = {
    enable = lib.mkEnableOption ''
      Add PostgreSQL process.
    '';

    package = lib.mkOption {
      type = types.package;
      description = ''
        The PostgreSQL package to use. Use this to override the default with a specific version.
      '';
      default = pkgs.postgresql;
      defaultText = lib.literalExpression "pkgs.postgresql";
      example = lib.literalExpression ''
        pkgs.postgresql_15
      '';
    };

    extensions = lib.mkOption {
      type = with types; nullOr (functionTo (listOf package));
      default = null;
      example = lib.literalExpression ''
        extensions: [
          extensions.pg_cron
          extensions.postgis
          extensions.timescaledb
        ];
      '';
      description = ''
        Additional PostgreSQL extensions to install.

        The available extensions are:

        ${lib.concatLines (builtins.map (x: "- " + x) (builtins.attrNames pkgs.postgresql.pkgs))}
      '';
    };

    listen_addresses = lib.mkOption {
      type = types.str;
      description = ''
        A comma-separated list of TCP/IP address(es) on which the server should listen for connections.

        By default, the server only accepts connections over unix sockets.

        This option is parsed to set the `PGHOST` environment variable.

        Special values:
          - \'*\' to listen on all available network interfaces.
          - \'0.0.0.0\' to listen on all available IPv4 network interfaces.
          - \'::\' to listen on all available IPv6 network interfaces.
          - \'localhost\' to listen only on the loopback interface.
          - \'\' (empty string) disables TCP/IP connections and listens only on the unix socket.
      '';
      default = "";
      example = "127.0.0.1";
    };

    port = lib.mkOption {
      type = types.port;
      default = 5432;
      description = ''
        The TCP port to accept connections.
      '';
    };

    createDatabase = lib.mkOption {
      type = types.bool;
      default = true;
      description = ''
        Create a database named like current user on startup. Only applies when initialDatabases is an empty list.
      '';
    };

    initdbArgs = lib.mkOption {
      type = types.listOf types.lines;
      default = [ "--locale=C" "--encoding=UTF8" ];
      example = [ "--data-checksums" "--allow-group-access" ];
      description = ''
        Additional arguments passed to `initdb` during data dir
        initialisation.
      '';
    };

    settings = lib.mkOption {
      type = with types; attrsOf (oneOf [ bool float int str ]);
      default = { };
      description = ''
        PostgreSQL configuration. Refer to
        <https://www.postgresql.org/docs/11/config-setting.html#CONFIG-SETTING-CONFIGURATION-FILE>
        for an overview of `postgresql.conf`.

        String values will automatically be enclosed in single quotes. Single quotes will be
        escaped with two single quotes as described by the upstream documentation linked above.
      '';
      example = lib.literalExpression ''
        {
          log_connections = true;
          log_statement = "all";
          logging_collector = true
          log_disconnections = true
          log_destination = lib.mkForce "syslog";
        }
      '';
    };

    initialDatabases = lib.mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = lib.mkOption {
            type = types.str;
            description = ''
              The name of the database to create.
            '';
          };
          schema = lib.mkOption {
            type = types.nullOr types.path;
            default = null;
            description = ''
              The initial schema of the database; if null (the default),
              an empty database is created.
            '';
          };
          user = lib.mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Username of owner of the database (if null, the default $USER is used).
            '';
          };
          pass = lib.mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Password of owner of the database (only takes effect if `user` is not `null`).
            '';
          };
          initialSQL = lib.mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              SQL commands to run on this specific database during it's initialization.
              Multiple SQL expressions can be separated by semicolons.
            '';
            example = lib.literalExpression ''
              CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT);
              INSERT INTO users (name) VALUES ('admin');
              CREATE EXTENSION IF NOT EXISTS pg_uuidv7;
            '';
          };
        };
      });
      default = [ ];
      description = ''
        List of database names and their initial schemas that should be used to create databases on the first startup
        of Postgres. The schema attribute is optional: If not specified, an empty database is created.
      '';
      example = lib.literalExpression ''
        [
          {
            name = "foodatabase";
            schema = ./foodatabase.sql;
          }
          { name = "bardatabase"; }
        ]
      '';
    };

    initialScript = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Initial SQL commands to run during database initialization. This can be multiple
        SQL expressions separated by a semi-colon.
        Use `initialScript` for server-wide setup, such as creating roles or configuring
        global settings. For database-specific initialization, use `initialSQL` within
        `initialDatabases`.
      '';
      example = lib.literalExpression ''
        CREATE ROLE postgres SUPERUSER;
        CREATE ROLE bar;
      '';
    };

    hbaConf = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        The contents of a custom pg_hba.conf file to copy into the postgres installation.
        This allows for custom connection rules that you want to establish on the server.
      '';
      example = lib.literalExpression ''
        builtins.readFile ./my-custom/directory/to/pg_hba.conf
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [ postgresPkg startScript ];

    env.PGDATA = config.env.DEVENV_STATE + "/postgres";
    env.PGHOST =
      let
        parsedAddress = headWithDefault null (parseListenAddresses cfg.listen_addresses);
        host =
          if cfg.listen_addresses != ""
          then parsedAddress
          else runtimeDir;
      in
      lib.mkDefault host;
    # Required for init scripts.
    env.PGPORT = cfg.port;

    services.postgres.settings = {
      listen_addresses = cfg.listen_addresses;
      port = cfg.port;
      unix_socket_directories = lib.mkDefault runtimeDir;
    };

    processes.postgres = {
      exec = "exec ${startScript}/bin/start-postgres";

      process-compose = {
        # SIGINT (= 2) for faster shutdown: https://www.postgresql.org/docs/current/server-shutdown.html
        shutdown.signal = 2;

        readiness_probe = {
          # pg_isready does not distinguish between a server that is ready and one that's being initialized by initdb.
          exec.command = ''
            if [[ -f "$PGDATA/.devenv_initialized" ]]; then
              ${postgresPkg}/bin/pg_isready -d template1 && \
              ${postgresPkg}/bin/psql -c "SELECT 1" template1 > /dev/null 2>&1
            else
              echo "Waiting for PostgreSQL initialization to complete..." 2>&1
              exit 1
            fi
          '';
          initial_delay_seconds = 2;
          period_seconds = 10;
          timeout_seconds = 4;
          success_threshold = 1;
          failure_threshold = 5;
        };

        # https://github.com/F1bonacc1/process-compose#-auto-restart-if-not-healthy
        availability.restart = "on_failure";
      };
    };
  };
}
