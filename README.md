# Flake input update watcher

`flake-input-watcher` is a standalone Bash program installed on the user PATH.
The opt-in Home Manager module supplies a graphical-session user service and
timer. The default schedule is five minutes after entering the graphical
session, then every six hours while the session is active. Nothing is activated
until you apply the Home Manager/NixOS configuration.

The program reads the editable checkout's `flake.lock` on every run. It checks
direct inputs, including `flake = false` and aliases declared with `follows`,
against upstream Git refs. It supports GitHub and generic Git sources, default
`HEAD`, branches, full refs and tags (including annotated tags). Explicit
`original.rev` pins and unsupported source types are reported as skipped.
Internal dependencies are not inspected. Changes in `flake.nix` take effect
after the lock file is synchronized through your normal update workflow.

A different upstream commit means an input update, not necessarily a package
version change. The watcher does not change `flake.lock`, download/build the
system, or rebuild it. Network and action failures do not stop checks for the
remaining inputs and make the command return nonzero.

## Configuration

Set an absolute checkout path with `flakePath`, then configure scheduling and
actions in your Home Manager configuration:

```nix
services.flake-input-watcher = {
  enable = true;
  flakePath = "/absolute/path/to/your/flake";

  schedule = {
    afterLogin = "5m";
    interval = "6h";
    afterBoot = null;
    calendar = [ ];
  };

  # Unlisted direct inputs are checked automatically.
  inputs.obsidian-skills.enable = false;

  hooks = {
    notify.type = "notify";
    log = {
      type = "shell";
      command = ''
        printf '%s [%s]: %s -> %s\n' \
          "$FLAKE_INPUT_NAME" "$FLAKE_INPUT_REF" \
          "$FLAKE_LOCKED_REV" "$FLAKE_REMOTE_REV"
      '';
      # packages = [ pkgs.someCommand ];
    };
  };

  rules = [
    { inputs = [ "*" ]; hooks = [ "notify" ]; }
    { inputs = [ "nixpkgs" "home-manager" ]; hooks = [ "log" ]; }
  ];

  requestTimeout = 30;
  hookTimeout = 60;
};
```

`inputs` controls whether to check. `hooks` defines named actions. `rules` binds
input names to those actions. Exact names and `*` are supported; rules add to
each other, and duplicate input/hook pairs run only once per check. Explicit `rules`
replace the default rule that binds all inputs to `notify`. To notify only about
`nixpkgs`, use `rules = [ { inputs = [ "nixpkgs" ]; hooks = [ "notify" ]; } ];`.
The `notify` hook is provided automatically, including when you define additional
shell hooks; explicitly declaring it in the example is optional.

Each shell hook is called **once per updated input on every check**, with these environment
variables:

| Variable | Value |
| --- | --- |
| `FLAKE_PATH` | Canonical absolute checkout path |
| `FLAKE_INPUT_NAME` | Name in the root flake's inputs |
| `FLAKE_INPUT_SOURCE` | Git remote URL |
| `FLAKE_INPUT_REF` | Tracked ref, or `HEAD` |
| `FLAKE_LOCKED_REV` | Revision in the lock file |
| `FLAKE_REMOTE_REV` | Current upstream revision |

Hooks execute as the desktop user in the flake checkout, with closed stdin,
the common runtime dependencies and their additional `packages` on PATH.
Their stdout/stderr goes to stderr/journal;
the check command's stdout remains a JSON report. Hook order is alphabetical by
name; do not rely on one hook's side effects in another hook.

The built-in `notify` action collects matching inputs and sends one notification
at the end of the check, even if multiple named notification hooks are matched.
`notify-send` uses the existing fnott D-Bus notification service. Its body lists
input names, refs, and twelve-character old/new revisions. No update means no
notification.

Every check runs the matching hooks whenever an upstream revision differs from
the lock file, including updates reported by previous checks. Successful actions
are not remembered. Notifications repeat on every check while updates remain.

## Schedule and commands

Time strings use systemd duration syntax. Each schedule field can be disabled:

- `afterLogin = null` disables the graphical-session startup delay.
- `interval = null` disables periodic checks. If it is the only enabled timing
  rule, the first check runs after that interval.
- `afterBoot = "10m"` checks ten minutes after boot. It still waits for a
  graphical session; if the delay has already elapsed at login, it checks then.
- `calendar = [ "daily" ]` adds calendar checks, catching up missed calendar
  runs when the timer starts. Multiple timing rules trigger independently.
- Disabling all timing rules removes the timer, retaining the program and the
  service for manual use. Default timer accuracy is systemd's one-minute window;
  monotonic intervals pause during suspend.

```bash
flake-input-watcher list-inputs
flake-input-watcher check --dry-run
flake-input-watcher check
systemctl --user start flake-input-watcher.service
systemctl --user list-timers flake-input-watcher.timer
journalctl --user -u flake-input-watcher.service
```

`list-inputs` reads and describes inputs without network requests. `--dry-run`
queries upstream and prints results, but runs no hooks and creates no check lock.
The PATH executable is supplied by the package.

Configuration defaults to
`${XDG_CONFIG_HOME:-$HOME/.config}/flake-input-watcher/config.json`.
Use `--config /absolute/path.json` to select a different configuration. Runtime
JSON has `flakePath`, `inputs`, `hooks`, `rules`, `requestTimeout` and
`hookTimeout`; Home Manager generates it. Shell hook `command` values in JSON
are **absolute executable paths**, not shell source. `schedule` belongs to the
Home Manager module and is translated into systemd units.

`${XDG_STATE_HOME:-$HOME/.local/state}/flake-input-watcher/check.lock` prevents
simultaneous checks. No action history is read or written; legacy `state.json`
files are ignored and can be deleted.

Run the isolated regression tests with `bash tests/check.sh`.
They use a temporary local Git repository and simulated hooks/notifications,
without accessing the network or sending desktop notifications.

Check the Home Manager schedule and configuration interfaces with:

```bash
nix eval --impure --json --expr '
  let f = builtins.getFlake ("path:" + toString ./.);
  in import ./tests/module.nix {
    pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
    homeManager = f.inputs.home-manager.outPath;
  }'
```

## Standalone flake

```nix
inputs.flake-input-watcher = {
  url = "github:SpreadZhao/flake-input-watcher/main";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.home-manager.follows = "home-manager";
};
# In a Home Manager module:
imports = [ inputs.flake-input-watcher.homeManagerModules.default ];
services.flake-input-watcher = {
  enable = true;
  flakePath = "/absolute/path/to/your/flake";
};
```

The module is disabled by default and has no dependency on a configuration
repository. With it enabled, scheduling defaults to five minutes after graphical
login and every six hours. Set `flakePath` explicitly.

Build with `nix build`, run CLI help with `nix run -- --help`, and test with
`nix flake check`. Packages, apps, checks, formatter and development shells are
available for x86_64-linux and aarch64-linux. Source is under `src/`, packaging
and the Home Manager module under `nix/`, and tests under `tests/`.
