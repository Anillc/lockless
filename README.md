# lockless

Build a `node_modules` (or just a `package-lock.json`) from a `package.json`,
without writing hashes or a lock file by hand.

Packuments come from [stable-npm](https://github.com/Anillc/stable-npm) through
[substituter-api](https://github.com/Anillc/substituter-api), so nothing needs a
hash and npm still does all the version resolution.

```nix
{
  inputs.lockless.url = "github:Anillc/lockless";

  outputs = { lockless, ... }: {
    packages.my-app = lockless.lib.x86_64-linux.mkNodeModules {
      date = "2026-10-01T00:00:00Z";
      package = builtins.fromJSON (builtins.readFile ./package.json);
    };
  };
}
```

The substituter has to be trusted:

```nix
nix.settings = {
  extra-substituters = [ "https://sns.ani.llc" ];
  extra-trusted-public-keys = [ "substituter-api-1:aJyds2K19yTBaVA2SyQIDqADwkhweR9w1Yib4Eqv4eY=" ];
};
```

## mkLock / mkNodeModules

Both take the same arguments. `mkLock` returns a directory containing
`package-lock.json`, `mkNodeModules` returns the `node_modules` directory.

| argument | type | default | meaning |
| --- | --- | --- | --- |
| `date` | string | | point in time to resolve at, RFC3339 UTC with second precision (e.g. `2026-10-01T00:00:00Z`) |
| `package` | attrset | | the parsed `package.json` |
| `server` | string | `https://sns.ani.llc` | substituter-api base url |
| `optional` | bool | `true` | resolve `optionalDependencies` too |
| `peer` | bool | `false` | resolve `peerDependencies` too |
| `nodejs` | package | `pkgs.nodejs` | node used to run npm |

`date` and `package` are required, the rest have defaults.

## How it works

1. Walk the dependency graph one level at a time, fetching packuments with one
   batched `poke` per level.
2. Serve those packuments from a local registry and run
   `npm install --package-lock-only` against it, offline.
3. Fetch whatever npm asks for that is still missing and run npm again, until
   it resolves everything.
