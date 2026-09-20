# nix/packages.nix — Hermes Agent package built with uv2nix
{ inputs, withSystem, ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      inputs',
      ...
    }:
    let

      sandbox = pkgs.callPackage ./sandbox.nix { };

      # OCI images. Contents come from the Linux build of `default` for the
      # requested system; the streaming script itself is built for the host
      # (see nix/container.nix). `container*` follows the host CPU (Darwin →
      # same-arch Linux); the `-<system>` suffix pins the architecture.
      # `container-minimal*` is the same agent without Chromium/agent-browser
      # and the docker CLI (tag `<version>-minimal`).
      mkContainer =
        linuxSystem: args:
        pkgs.callPackage ./container.nix (
          {
            pkgsLinux = withSystem linuxSystem ({ pkgs, ... }: pkgs);
            hermes-agent = withSystem linuxSystem ({ config, ... }: config.packages.default);
            rev = inputs.self.rev or null;
          }
          // args
        );
      hostLinuxSystem = "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux";
      containerVariants = {
        container = { };
        container-minimal = {
          withBrowser = false;
          withDockerClient = false;
          imageTag = "${full.version}-minimal";
        };
      };
      containers = lib.concatMapAttrs (
        name: args:
        {
          ${name} = mkContainer hostLinuxSystem args;
        }
        // lib.genAttrs' [ "x86_64-linux" "aarch64-linux" ] (system: {
          name = "${name}-${system}";
          value = mkContainer system args;
        })
      ) containerVariants;

      minimal = pkgs.callPackage ./hermes-agent.nix {
        inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;
        npm-lockfile-fix = inputs'.npm-lockfile-fix.packages.default;
        # Only embed clean revs — dirtyRev doesn't represent any upstream
        # commit, so comparing it would always claim "update available".
        rev = inputs.self.rev or null;
      };

      # All platform-portable optional integrations pre-built.
      full = minimal.override {
        extraDependencyGroups = [
          "anthropic"
          "azure-identity"
          "bedrock"
          "daytona"
          "dingtalk"
          "edge-tts"
          "exa"
          "fal"
          "feishu"
          "firecrawl"
          "hindsight"
          "honcho"
          "messaging"
          "modal"
          "parallel-web"
          "tts-premium"
          "vercel"
          "voice"
        ]
        # matrix is Linux-only (oqs/liboqs lacks aarch64-darwin wheels).
        ++ lib.optionals pkgs.stdenv.isLinux [ "matrix" ];
      };
    in
    {
      packages = containers // {
        node-gyp =
          (pkgs.callPackage ./lib.nix {
            inherit (pkgs) npm-lockfile-fix;
          }).node-gyp;
        default = full;

        inherit sandbox;

        inherit minimal;

        # Ships discord.py + python-telegram-bot + slack-sdk so a plain
        # `nix profile install .#messaging` connects to Discord/Telegram/Slack
        # on first run — lazy-install can't write to the read-only /nix/store.
        messaging = minimal.override {
          extraDependencyGroups = [ "messaging" ];
        };

        tui = full.hermesTui;
        web = full.hermesWeb;
        desktop = full.hermesDesktop;

        update-npm-lockfile = full.hermesNpmLib.updateNpmLockfile;
      };
    };
}
