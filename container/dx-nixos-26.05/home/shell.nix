{ config, pkgs, ... }:

{
  # WP7.4 (docs/reviews/2026-09-29-fable.md finding C4): starship, direnv
  # and the yazi `y` cd-on-exit wrapper used to be hand-rolled three times
  # (once per shell) with three different guard idioms (bash: `command -v`,
  # fish: `type -q`, nushell: neither -- it had no starship/direnv hook at
  # all, undocumented). Typed options render all three consistently and
  # keep drift like that impossible by construction.
  programs.starship = {
    enable = true;
    # Settings deliberately empty: dx-theme (home/theme.nix, scripts/
    # dx-theme*.sh) owns starship.toml at runtime via
    # ~/.cache/dx/tinty/shell.sh / tinty's hooks, not Home Manager. Verified
    # with `nix eval`: config.xdg.configFile has no "starship.toml" key
    # when settings and presets are both empty, so nothing here can collide
    # with dx-theme's file.
    enableBashIntegration = true;
    enableFishIntegration = true;
    enableNushellIntegration = true;
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    enableBashIntegration = true;
    enableFishIntegration = true;
    enableNushellIntegration = true;
  };

  programs.yazi = {
    enable = true;
    shellWrapperName = "y";
    enableBashIntegration = true;
    enableFishIntegration = true;
    enableNushellIntegration = true;
  };

  programs.bash = {
    enable = true;
    profileExtra = ''
      # Read the validated raw D-Bus address as data.
      keyring_address_file=/persist/home/dx/.local/state/dx/keyring-address
      keyring_library="$HOME/.local/lib/dx/dx-keyring.sh"
      if [ -f "$keyring_library" ] && [ -f "$keyring_address_file" ]; then
        . "$keyring_library"
        DBUS_SESSION_BUS_ADDRESS="$(dx_keyring_read_address "$keyring_address_file" 2>/dev/null || true)"
        if [ -n "$DBUS_SESSION_BUS_ADDRESS" ]; then export DBUS_SESSION_BUS_ADDRESS; else unset DBUS_SESSION_BUS_ADDRESS; fi
      fi
    '';
    initExtra = ''
      set -o vi

      if [ -f "$HOME/.cache/dx/tinty/lazygit.yml" ]; then
        export LG_CONFIG_FILE="$HOME/.config/lazygit/config.yml,$HOME/.cache/dx/tinty/lazygit.yml"
      else
        export LG_CONFIG_FILE="$HOME/.config/lazygit/config.yml"
      fi
      if [ -f "$HOME/.cache/dx/tinty/shell.sh" ]; then
        # shellcheck disable=SC1090
        . "$HOME/.cache/dx/tinty/shell.sh"
      fi
      if [ -x "$HOME/.local/bin/dx-theme-restore" ]; then
        "$HOME/.local/bin/dx-theme-restore" 2>/dev/null || true
      fi
    '';
  };

  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      # Read the raw D-Bus address as one bounded data record.
      set -l keyring_address_file /persist/home/dx/.local/state/dx/keyring-address
      if test -f "$keyring_address_file"
        read -l keyring_address < "$keyring_address_file"
        if string match -rq '^unix:path=/' -- "$keyring_address"
          set -gx DBUS_SESSION_BUS_ADDRESS "$keyring_address"
        end
      end
      set -g fish_greeting
      fish_vi_key_bindings

      if test -f "$HOME/.cache/dx/tinty/lazygit.yml"
        set -gx LG_CONFIG_FILE "$HOME/.config/lazygit/config.yml,$HOME/.cache/dx/tinty/lazygit.yml"
      else
        set -gx LG_CONFIG_FILE "$HOME/.config/lazygit/config.yml"
      end
      if test -f "$HOME/.cache/dx/tinty/shell.sh"
        sh "$HOME/.cache/dx/tinty/shell.sh"
      end
      if test -x "$HOME/.local/bin/dx-theme-restore"
        "$HOME/.local/bin/dx-theme-restore" 2>/dev/null
      end
    '';
  };

  programs.nushell = {
    enable = true;
    # Nushell Tinted-shell startup support is intentionally not enabled.
    # It has not been proven for the selected Tinty template version.
    settings = {
      show_banner = false;
      edit_mode = "vi";
    };
    configFile.text = ''
      try { ^/home/dx/.local/bin/dx-theme-restore }
    '';
    envFile.text = ''
      # Read the raw D-Bus address as data.
      let keyring_address_file = "/persist/home/dx/.local/state/dx/keyring-address"
      if ($keyring_address_file | path exists) {
        let address = (open $keyring_address_file | str trim)
        if ($address | str starts-with "unix:path=/") {
          $env.DBUS_SESSION_BUS_ADDRESS = $address
        }
      }
      $env.EDITOR = "nvim"
      $env.VISUAL = "nvim"
      $env.SSL_CERT_FILE = $"($nu.home-dir)/.nix-profile/etc/ssl/certs/ca-bundle.crt"
      $env.NIX_SSL_CERT_FILE = $"($nu.home-dir)/.nix-profile/etc/ssl/certs/ca-bundle.crt"
      $env.PERSIST = "/persist"
      $env.TZ = ":/etc/localtime"
      $env.TZDIR = "${pkgs.tzdata}/share/zoneinfo"
      let lazygit_config = $"($nu.home-dir)/.config/lazygit/config.yml"
      let lazygit_theme = $"($nu.home-dir)/.cache/dx/tinty/lazygit.yml"
      $env.LG_CONFIG_FILE = if ($lazygit_theme | path exists) {
        $"($lazygit_config),($lazygit_theme)"
      } else {
        $lazygit_config
      }
    '';
  };

  # WP7.4 (Fable C4): the three per-shell PATH prepends (bash's
  # profileExtra export, fish's `fish_add_path --prepend`, nushell's
  # `$env.PATH = ...`) and home.sessionVariables.PATH below all did the
  # same thing by hand. home.sessionPath renders through Home Manager's
  # own `prependToVar` for every shell (including nushell), so the dx-ai
  # profile still wins over ~/.local/bin and the rest of PATH -- verified
  # with `nix eval`.
  home.sessionPath = [
    "/persist/home/dx/.local/state/dx-ai/current/profile/bin"
    # ~/.nix-profile/bin must be listed: a bare login shell (raw `ssh dx@guest
    # "bash -lc ..."`) starts from sshd's default PATH, which has no Nix
    # directory, and this guest has no /etc/profile.d/nix.sh to add one.
    # Dropped once during WP7.4 and caught by the dx-test live gate.
    "$HOME/.nix-profile/bin"
    "$HOME/.local/bin"
  ];

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    SSL_CERT_FILE = "$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt";
    NIX_SSL_CERT_FILE = "$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt";
    PERSIST = "/persist";
    TZ = ":/etc/localtime";
    TZDIR = "${pkgs.tzdata}/share/zoneinfo";
  };

  home.shellAliases = {
    agy = "agy --dangerously-skip-permissions";
    claude = "claude --dangerously-skip-permissions";
    codex = "codex --dangerously-bypass-approvals-and-sandbox";
    usage = "/persist/git/agent-stats/run-stats.sh";
  };
}
