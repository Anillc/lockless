{ pkgs, lib, inputs', self', ... }: let
  fetchMany = inputs'.substituter-api.lib.fetchMany;
  inherit (builtins) attrNames baseNameOf dirOf fromJSON readFile replaceStrings toJSON;
  defaultServer = "https://sns.ani.llc";
  defaultNodejs = pkgs.nodejs;

  # Scoped names encode their slash so the name stays one path segment.
  packumentUrl = date: name:
    "http://127.0.0.1:3000/${date}/${replaceStrings [ "/" ] [ "%2f" ] name}";

  # One poke for the whole batch.  The layout matches npm's requests
  # (`/@scope%2fname` decodes to `@scope/name`), and reading from here
  # substitutes the whole batch at once.
  packuments = { server, date, names }: let
    fetched = lib.zipListsWith (name: drv: { inherit name drv; }) names (fetchMany {
      inherit server;
      urls = map (packumentUrl date) names;
    });
  in pkgs.runCommand "packuments" {} ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n"
      ({ name, drv }: ''
        mkdir -p $out/${dirOf name}
        cp ${drv} $out/${dirOf name}/${baseNameOf name}
      '')
      fetched}
  '';

  wantedDependencies = { optional, peer }: deps:
    lib.filterAttrs (_: spec: !(lib.hasPrefix "npm:" spec))
      ((deps.dependencies or {})
      // lib.optionalAttrs optional (deps.optionalDependencies or {})
      // lib.optionalAttrs peer (deps.peerDependencies or {}));

  # stable-npm only serves `latest`, so that is the version we follow.
  dependenciesOf = { optional, peer }: doc:
    wantedDependencies { inherit optional peer; } (doc.versions.${doc."dist-tags".latest} or {});

  rootDependencies = { package, optional, peer }:
    wantedDependencies { inherit optional peer; } package // (package.devDependencies or {});

  # Dependency names reachable from the root, one level per poke.  Only a seed:
  # npm may still want a dependency of an older version, which `mkLock` picks
  # up from npm's 404s.
  dependencyNames = { server, date, optional, peer, rootDependencies }: let
    step = seen: frontier: let
      fresh = lib.subtractLists seen frontier;
      bundle = packuments { inherit server date; names = fresh; };
      docs = map (name: fromJSON (readFile "${bundle}/${name}")) fresh;
      next = lib.pipe docs [
        (lib.concatMap (doc: attrNames (dependenciesOf { inherit optional peer; } doc)))
        lib.unique
      ];
    in if fresh == [] then seen else step (seen ++ fresh) next;
  in step [] (attrNames rootDependencies);
in {
  lib = {
    mkLock = {
      date, package, server ? defaultServer, optional ? true, peer ? false, nodejs ? defaultNodejs
    }: let
      packageJson = pkgs.writeText "package.json" (toJSON package);
      seed = dependencyNames {
        inherit server date optional peer;
        rootDependencies = rootDependencies { inherit package optional peer; };
      };

      # Reports the names npm wanted but we lacked, and never fails on npm's
      # behalf so `run` can retry.
      attempt = names: pkgs.runCommand "package-lock" {
        nativeBuildInputs = [ nodejs pkgs.curl ];
        passthru.closure = names;
      } ''
        export HOME=$TMPDIR
        export npm_config_cache=$TMPDIR/npm-cache
        mkdir -p $TMPDIR/app
        cp ${packageJson} $TMPDIR/app/package.json

        ROOT=${packuments { inherit server date names; }} MISSING=$TMPDIR/missing \
          node -e '
            const fs = require("fs"), http = require("http"), path = require("path");
            http.createServer((req, res) => {
              const rel = decodeURIComponent(req.url.split("?")[0]).replace(/^\/+/, "");
              const file = path.join(process.env.ROOT, rel);
              if (rel && fs.existsSync(file) && fs.statSync(file).isFile()) {
                res.writeHead(200, { "content-type": "application/json" });
                return res.end(fs.readFileSync(file));
              }
              const parts = rel.split("/").filter(Boolean);
              const name = parts[0] && parts[0].startsWith("@") ? parts.slice(0, 2).join("/") : parts[0];
              if (name) fs.appendFileSync(process.env.MISSING, name + "\n");
              res.writeHead(404, { "content-type": "application/json" });
              res.end("{\"error\":\"Not found\"}\n");
            }).listen(8123, "127.0.0.1");
          ' &
        registry_pid=$!
        trap 'kill $registry_pid 2>/dev/null || true' EXIT

        # Wait for the registry to accept connections (`000` means refused).
        for _ in $(seq 1 200); do
          code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8123/ || true)
          case "$code" in "" | 000) sleep 0.05 ;; *) break ;; esac
        done

        cd $TMPDIR/app
        status=0
        npm install --package-lock-only --ignore-scripts --no-audit --no-fund \
          --no-update-notifier \
          --registry=http://127.0.0.1:8123/ \
          --replace-registry-host=never \
          ${lib.optionalString (!optional) "--omit=optional"} \
          ${lib.optionalString (!peer) "--omit=peer"} || status=$?

        mkdir -p $out
        if [ -f package-lock.json ]; then cp package-lock.json $out/package-lock.json; fi
        echo "$status" > $out/npm-status
        sort -u $TMPDIR/missing 2>/dev/null > $out/missing-names || true
      '';

      # Feed npm's 404s back as new packuments until it resolves everything.
      run = fetched: let
        result = attempt (lib.unique (seed ++ fetched));
        status = lib.pipe (readFile "${result}/npm-status") [
          (lib.removeSuffix "\n")
          lib.toInt
        ];
        missing = lib.pipe (readFile "${result}/missing-names") [
          (lib.splitString "\n")
          (lib.filter (name: name != ""))
        ];
      in if status == 0 then result
      else if missing == [] then
        throw "npm failed (exit ${toString status}) without naming any missing packuments; see the log of ${result}"
      else if lib.subtractLists fetched missing == [] then
        throw "npm still wants ${lib.concatStringsSep ", " missing}, which we already served; see the log of ${result}"
      else
        run (fetched ++ missing);
    in run [];

    mkNodeModules = args: pkgs.importNpmLock.buildNodeModules {
      inherit (args) package;
      nodejs = args.nodejs or defaultNodejs;
      derivationArgs = args.derivationArgs or {};
      packageLock = fromJSON (readFile "${self'.lib.mkLock (builtins.removeAttrs args [ "derivationArgs" ])}/package-lock.json");
    };
  };
}
