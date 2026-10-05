{ pkgs, homeManager }:

let
  inherit (pkgs) lib;
  evaluate =
    settings:
    (import (homeManager + "/modules") {
      inherit pkgs;
      configuration = {
        imports = [ ../nix/home-manager.nix ];
        config = {
          home = {
            username = "watcher-test";
            homeDirectory = "/home/watcher-test";
            stateVersion = "24.11";
          };
          services.flake-input-watcher = {
            enable = true;
            flakePath = "/tmp/checkout with spaces";
          }
          // settings;
        };
      };
    }).config;
  unconfigured =
    (import (homeManager + "/modules") {
      inherit pkgs;
      configuration = {
        imports = [ ../nix/home-manager.nix ];
        home = {
          username = "test";
          homeDirectory = "/home/test";
          stateVersion = "24.11";
        };
      };
    }).config;
  defaults = evaluate { };
  intervalOnly = evaluate {
    schedule.afterLogin = null;
    schedule.interval = "2h";
  };
  bootOnly = evaluate {
    schedule.afterLogin = null;
    schedule.interval = null;
    schedule.afterBoot = "10m";
  };
  calendarOnly = evaluate {
    schedule.afterLogin = null;
    schedule.interval = null;
    schedule.calendar = [ "daily" ];
  };
  manualOnly = evaluate {
    schedule.afterLogin = null;
    schedule.interval = null;
  };
  disabled = evaluate { enable = false; };
  explicitRules = evaluate {
    hooks.log.command = ''printf '%s\n' "$FLAKE_INPUT_NAME"'';
    rules = [
      {
        inputs = [ "nixpkgs" ];
        hooks = [ "log" ];
      }
    ];
  };
  failed =
    settings:
    !(builtins.tryEval (builtins.deepSeq (evaluate settings).home.activationPackage true)).success;
  results = lib.runTests {
    testModuleIsOptIn = {
      expr = unconfigured.services.flake-input-watcher.enable;
      expected = false;
    };
    testDefaultTimer = {
      expr = defaults.systemd.user.timers.flake-input-watcher.Timer;
      expected = {
        Unit = "flake-input-watcher.service";
        Persistent = false;
        OnActiveSec = "5m";
        OnUnitActiveSec = "6h";
      };
    };
    testGraphicalTimerAvoidsEarlyBootOrdering = {
      expr = defaults.systemd.user.timers.flake-input-watcher.Unit.DefaultDependencies;
      expected = false;
    };
    testIntervalHasFirstTrigger = {
      expr = intervalOnly.systemd.user.timers.flake-input-watcher.Timer.OnActiveSec;
      expected = "2h";
    };
    testBootOnly = {
      expr = bootOnly.systemd.user.timers.flake-input-watcher.Timer;
      expected = {
        Unit = "flake-input-watcher.service";
        Persistent = false;
        OnBootSec = "10m";
      };
    };
    testCalendarOnly = {
      expr = calendarOnly.systemd.user.timers.flake-input-watcher.Timer;
      expected = {
        Unit = "flake-input-watcher.service";
        Persistent = true;
        OnCalendar = [ "daily" ];
      };
    };
    testAllTimingRulesCanBeDisabled = {
      expr = builtins.hasAttr "flake-input-watcher" manualOnly.systemd.user.timers;
      expected = false;
    };
    testDisabledServiceIsAbsent = {
      expr = builtins.hasAttr "flake-input-watcher" disabled.systemd.user.services;
      expected = false;
    };
    testExplicitRulesReplaceDefault = {
      expr = explicitRules.services.flake-input-watcher.rules;
      expected = [
        {
          inputs = [ "nixpkgs" ];
          hooks = [ "log" ];
        }
      ];
    };
    testAdditionalHooksKeepBuiltinNotification = {
      expr = explicitRules.services.flake-input-watcher.hooks.notify.type;
      expected = "notify";
    };
    testUnknownHookRejected = {
      expr = failed {
        rules = [
          {
            inputs = [ "*" ];
            hooks = [ "missing" ];
          }
        ];
      };
      expected = true;
    };
    testRelativeCheckoutRejected = {
      expr = failed { flakePath = "./config"; };
      expected = true;
    };
    testEmptyShellHookRejected = {
      expr = failed {
        hooks.empty.type = "shell";
        rules = [ ];
      };
      expected = true;
    };
  };
in
assert lib.assertMsg (results == [ ]) (builtins.toJSON results);
true
