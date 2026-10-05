{
  writeShellApplication,
  git,
  jq,
  coreutils,
  util-linux,
  libnotify,
}:
writeShellApplication {
  name = "flake-input-watcher";
  runtimeInputs = [
    git
    jq
    coreutils
    util-linux
    libnotify
  ];
  text = builtins.readFile ../src/flake-input-watcher;
}
