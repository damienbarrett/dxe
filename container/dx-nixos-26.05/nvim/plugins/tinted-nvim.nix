{ pkgs, ... }:

{
  extraPlugins = [
    pkgs.vimPlugins.tinted-nvim
  ];

  extraConfigLua = ''
    vim.opt.termguicolors = true

    require("tinted-nvim").setup({
      -- Fallback only; the selector below normally resolves the live scheme.
      -- Tracks dx-theme's `dark` default (home/theme.nix: dxThemes.dark).
      default_scheme = "base16-mocha",
      apply_scheme_on_startup = true,
      selector = {
        enabled = true,
        mode = "file",
        path = vim.fn.expand("~/.local/share/tinted-theming/tinty/current_scheme"),
        watch = true,
      },
      highlights = {
        integrations = { telescope = true, cmp = true },
      },
    })
  '';
}
