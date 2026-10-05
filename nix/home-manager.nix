{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.flake-input-watcher;
  inherit (lib) mkOption types;
  duration =
    default: description:
    mkOption {
      type = types.nullOr types.str;
      inherit default description;
    };
  runtimeInputs = with pkgs; [
    git
    jq
    coreutils
    util-linux
    libnotify
  ];
  package = pkgs.callPackage ./package.nix { };
  hooks = lib.mapAttrs (
    name: hook:
    {
      inherit (hook) type;
    }
    // lib.optionalAttrs (hook.type == "shell") {
      command = "${
        pkgs.writeShellApplication {
          name = "flake-input-watcher-hook-${name}";
          runtimeInputs = runtimeInputs ++ hook.packages;
          text = hook.command;
        }
      }/bin/flake-input-watcher-hook-${name}";
    }
  ) cfg.hooks;
  configuration = pkgs.writeText "flake-input-watcher-config.json" (
    builtins.toJSON {
      inherit (cfg)
        flakePath
        inputs
        rules
        requestTimeout
        hookTimeout
        ;
      inherit hooks;
    }
  );
  sessionTarget = config.wayland.systemd.target;
  hasTimer =
    cfg.schedule.afterLogin != null
    || cfg.schedule.interval != null
    || cfg.schedule.afterBoot != null
    || cfg.schedule.calendar != [ ];
  # An interval-only configuration still needs an initial check.
  initialDelay =
    if cfg.schedule.afterLogin != null then
      cfg.schedule.afterLogin
    else if cfg.schedule.afterBoot == null && cfg.schedule.calendar == [ ] then
      cfg.schedule.interval
    else
      null;
in
{
  options.services.flake-input-watcher = {
    enable = lib.mkEnableOption "periodic flake input update checks";
    package = lib.mkOption {
      type = types.package;
      default = package;
      description = "Standalone flake-input-watcher executable.";
    };
    flakePath = mkOption {
      type = types.str;
      description = "Absolute path to the editable flake checkout; flake.lock is read each run.";
    };
    inputs = mkOption {
      type = types.attrsOf (
        types.submodule {
          options.enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to check this direct input.";
          };
        }
      );
      default = { };
      description = "Check switches for direct inputs. Unlisted inputs are checked automatically.";
    };
    hooks = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            type = mkOption {
              type = types.enum [
                "notify"
                "shell"
              ];
              default = "shell";
              description = "Built-in combined notification, or a per-input shell command.";
            };
            command = mkOption {
              type = types.lines;
              default = "";
              description = "Shell hook body. Receives FLAKE_PATH and FLAKE_INPUT_* / FLAKE_*_REV environment variables.";
            };
            packages = mkOption {
              type = types.listOf types.package;
              default = [ ];
              description = "Additional commands placed on this shell hook's PATH.";
            };
          };
        }
      );
      default = { };
      description = "Named reusable update actions. Shell hooks run once per input; notifications are combined.";
    };
    rules = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            inputs = mkOption {
              type = types.listOf types.str;
              description = "Exact direct input names, or * to match all checked inputs.";
            };
            hooks = mkOption {
              type = types.listOf types.str;
              description = "Names of hooks to run for matching updates.";
            };
          };
        }
      );
      default = [
        {
          inputs = [ "*" ];
          hooks = [ "notify" ];
        }
      ];
      description = "Additive input-to-hook bindings, deduplicated per input. Explicit rules replace the default binding.";
    };
    requestTimeout = mkOption {
      type = types.ints.positive;
      default = 30;
      description = "Timeout in seconds for each remote Git query.";
    };
    hookTimeout = mkOption {
      type = types.ints.positive;
      default = 60;
      description = "Timeout in seconds for each hook, including notification delivery.";
    };
    schedule = {
      afterLogin = duration "5m" "Delay after the graphical session starts; null disables this trigger.";
      interval = duration "6h" "Interval between check starts; null disables periodic checks.";
      afterBoot = duration null "Delay since system boot, gated by the graphical session; null disables this trigger.";
      calendar = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional systemd OnCalendar expressions. Missed calendar runs are caught up on login.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.flake-input-watcher.hooks.notify.type = lib.mkDefault "notify";
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.flakePath;
        message = "services.flake-input-watcher.flakePath must be absolute.";
      }
      {
        assertion = lib.all (rule: lib.all (name: builtins.hasAttr name cfg.hooks) rule.hooks) cfg.rules;
        message = "services.flake-input-watcher.rules references an undefined hook.";
      }
      {
        assertion = lib.all (hook: hook.type != "shell" || hook.command != "") (
          builtins.attrValues cfg.hooks
        );
        message = "flake-input-watcher shell hooks require a nonempty command.";
      }
    ];
    home.packages = [ cfg.package ];
    xdg.configFile."flake-input-watcher/config.json".source = configuration;
    systemd.user.services.flake-input-watcher = {
      Unit = {
        Description = "Check direct flake inputs for upstream updates";
        After = [ sessionTarget ];
        Requisite = [ sessionTarget ];
        PartOf = [ sessionTarget ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${cfg.package}/bin/flake-input-watcher check --config ${configuration}";
        TimeoutStartSec = "infinity";
      };
    };
    systemd.user.timers.flake-input-watcher = lib.mkIf hasTimer {
      Unit = {
        Description = "Schedule flake input update checks";
        # The implicit Before=timers.target conflicts with After=graphical-session.target,
        # which is itself ordered after basic.target and timers.target.
        DefaultDependencies = false;
        Conflicts = [ "shutdown.target" ];
        Before = [ "shutdown.target" ];
        PartOf = [ sessionTarget ];
        After = [ sessionTarget ];
        Requisite = [ sessionTarget ];
      };
      Timer = {
        Unit = "flake-input-watcher.service";
        Persistent = cfg.schedule.calendar != [ ];
      }
      // lib.optionalAttrs (initialDelay != null) { OnActiveSec = initialDelay; }
      // lib.optionalAttrs (cfg.schedule.interval != null) { OnUnitActiveSec = cfg.schedule.interval; }
      // lib.optionalAttrs (cfg.schedule.afterBoot != null) { OnBootSec = cfg.schedule.afterBoot; }
      // lib.optionalAttrs (cfg.schedule.calendar != [ ]) { OnCalendar = cfg.schedule.calendar; };
      Install.WantedBy = [ sessionTarget ];
    };
  };
}
