# nix/container.nix — OCI image for Hermes Agent, built with dockerTools
# instead of the Dockerfile.
#
# `pkgsLinux` and `hermes-agent` are a Linux package set and the matching
# build of `packages.default`; they pick the image architecture (linux/amd64
# or linux/arm64). `dockerTools` / `buildEnv` come from the HOST package set
# so the streaming script runs on the machine invoking `nix run` (a macOS
# host needs a Linux builder to realise the contents).
#
#   nix run .#container | docker load          # host arch (arm64 on Apple Silicon)
#   nix run .#container-x86_64-linux | docker load
#   nix run .#container-minimal | docker load  # no Chromium / docker CLI (~1/3 the size)
#   docker run -it -v hermes-data:/opt/data nousresearch/hermes-agent:<version>
#
# Differences from the Dockerfile, on purpose:
#   * No s6-overlay / UID remap / privilege-drop shim. tini is PID 1 (the
#     zombie reaper the Dockerfile used before s6); the process runs as the
#     `hermes` user (UID 10000) directly, and the store is read-only so there
#     is nothing root needs to fix up at boot.
#   * No uv / gcc / cmake: the venv is sealed (HERMES_DISABLE_LAZY_INSTALLS=1)
#     and every optional dependency group `packages.default` carries is
#     already built in, so runtime pip/npm installs have no job to do.
#   * SQLite is whatever nixpkgs' python312 links (>= 3.51.3), so the
#     WAL-reset workaround stage is unnecessary.
{
  lib,
  dockerTools,
  buildEnv,

  pkgsLinux,
  hermes-agent,

  # Flake `self.rev` — null for dirty trees; recorded in the provenance
  # marker and OCI labels so `hermes dump` can name the commit.
  rev ? null,
  imageName ? "nousresearch/hermes-agent",
  imageTag ? hermes-agent.version,
  # Bake agent-browser + Chromium so the browser tool is advertised without
  # a runtime download (Dockerfile parity). Off in `container-minimal`.
  withBrowser ? true,
  # Bake the docker CLI for `terminal.backend: docker` against a mounted
  # socket (Dockerfile parity). Off in `container-minimal`.
  withDockerClient ? true,
}:
assert lib.assertMsg pkgsLinux.stdenv.hostPlatform.isLinux
  "container.nix: pkgsLinux must be a Linux package set (got ${pkgsLinux.stdenv.hostPlatform.system})";
assert lib.assertMsg (hermes-agent.system == pkgsLinux.stdenv.hostPlatform.system)
  "container.nix: hermes-agent (${hermes-agent.system}) and pkgsLinux (${pkgsLinux.stdenv.hostPlatform.system}) must be the same system";
let
  inherit (builtins) toString;

  # Mirrors the Dockerfile: `useradd -u 10000 -m -d /opt/data hermes`.
  user = {
    uid = 10000;
    gid = 10000;
    uname = "hermes";
    gname = "hermes";
  };

  HOME = "/opt/data";

  # Argument routing identical to docker/main-wrapper.sh:
  #   no args                     → hermes
  #   first arg is an executable  → exec it (sleep, bash, …)
  #   anything else               → hermes <args>   (subcommand passthrough)
  #
  # tini is PID 1 in front of this (see config.Entrypoint): hermes spawns MCP
  # servers, agent-browser and shell children whose orphans nobody would
  # wait() on if hermes itself were PID 1 — they accumulate as zombies and
  # hermes_cli/main.py warns about exactly that at startup. `-s` makes tini a
  # child subreaper so it still reaps when a platform init already owns PID 1
  # (`docker run --init`, Fly Machines) instead of refusing to start; `-g`
  # forwards signals to the whole process group so a `docker stop` reaches
  # the children too.
  entrypoint = pkgsLinux.writeShellApplication {
    name = "hermes-container-entrypoint";
    runtimeInputs = [ hermes-agent ];
    text = ''
      mkdir -p "$HERMES_HOME"
      if [ $# -eq 0 ]; then
          exec hermes
      fi
      if command -v "$1" >/dev/null 2>&1; then
          exec "$@"
      fi
      exec hermes "$@"
    '';
  };

  # Read by hermes_cli/image_provenance.py. Its presence marks the runtime as
  # image-managed so `hermes update` refuses to mutate the install in place.
  provenance = pkgsLinux.writeText "image-provenance.json" (
    builtins.toJSON {
      schema = 1;
      deployment_kind = "image";
      manager = "nix";
      image = imageName;
      version = hermes-agent.version;
      revision = rev;
    }
  );

  fakeNss = pkgsLinux.dockerTools.fakeNss.override {
    extraPasswdLines = [
      "${user.uname}:x:${toString user.uid}:${toString user.gid}:Hermes Agent:${HOME}:/bin/bash"
    ];
    extraGroupLines = [
      "${user.gname}:x:${toString user.gid}:"
    ];
  };

  contents = buildEnv {
    name = "hermes-agent-image-root";
    paths = [
      hermes-agent
    ]
    ++ (with pkgsLinux; [
      # The hermes wrapper already suffixes its own PATH with node, git,
      # ripgrep, ffmpeg, tirith, ssh. These are for the terminal tool's
      # shell, `docker exec`, and the system packages the Dockerfile's
      # apt line installs.
      bashInteractive
      coreutils
      findutils
      gnugrep
      gnused
      gawk
      diffutils
      which
      procps
      gnutar
      gzip
      xz
      curl
      iputils
      git
      openssh
      ripgrep
      hermes-agent.hermesNpmLib.nodejs

      dockerTools.caCertificates
      dockerTools.binSh
      dockerTools.usrBinEnv
    ])
    ++ lib.optionals withDockerClient [ pkgsLinux.docker-client ]
    # agent-browser is the CLI the browser tool drives (otherwise it falls
    # back to a runtime `npx` download); AGENT_BROWSER_EXECUTABLE_PATH below
    # points it at this chromium.
    ++ lib.optionals withBrowser [
      pkgsLinux.agent-browser
      pkgsLinux.chromium
    ]
    ++ [ fakeNss ];
  };
in
dockerTools.streamLayeredImage {
  name = imageName;
  tag = imageTag;
  # amd64 / arm64 — derived from the contents, never from the host.
  architecture = pkgsLinux.stdenv.hostPlatform.go.GOARCH;

  inherit contents;

  extraCommands = ''
    mkdir -p ${lib.removePrefix "/" HOME}
    mkdir -p tmp
    chmod 1777 tmp

    mkdir -p etc/hermes
    cp ${provenance} etc/hermes/image-provenance.json
    chmod 0444 etc/hermes/image-provenance.json
  '';

  fakeRootCommands = ''
    chown -R ${toString user.uid}:${toString user.gid} ${lib.removePrefix "/" HOME}
  '';

  config = {
    Entrypoint = [
      (lib.getExe pkgsLinux.tini)
      "-s"
      "-g"
      "--"
      (lib.getExe entrypoint)
    ];
    Cmd = [ ];
    User = "${toString user.uid}:${toString user.gid}";
    WorkingDir = HOME;
    Volumes."${HOME}" = { };
    Env = [
      "PATH=/bin:/usr/bin"
      "HOME=${HOME}"
      "LANG=C.UTF-8"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"

      "PYTHONUNBUFFERED=1"
      "PYTHONDONTWRITEBYTECODE=1"

      "HERMES_HOME=${HOME}"
      "HERMES_WRITE_SAFE_ROOT=${HOME}"
      # /nix/store is immutable and there is no uv/pip in the image; the
      # sealed venv already carries every optional group packages.default
      # enables.
      "HERMES_DISABLE_LAZY_INSTALLS=1"
    ]
    ++ lib.optionals withBrowser [
      "AGENT_BROWSER_EXECUTABLE_PATH=${lib.getExe pkgsLinux.chromium}"
    ];
    Labels = {
      "org.opencontainers.image.title" = "hermes-agent";
      "org.opencontainers.image.source" = "https://github.com/NousResearch/hermes-agent";
      "org.opencontainers.image.version" = hermes-agent.version;
    }
    // lib.optionalAttrs (rev != null) { "org.opencontainers.image.revision" = rev; };
  };
}
