{ pkgs, ... }:

{
  extraPlugins = [
    pkgs.vimPlugins.tinted-nvim
  ];

  extraConfigLua = ''
    vim.opt.termguicolors = true

    require("tinted-colorscheme").setup(nil, {
      supports = {
        tinty = true,
        tinted_shell = false,
        live_reload = false,
      },
      highlights = {
        telescope = true,
        telescope_borders = true,
        cmp = true,
        lsp_semantic = true,
      },
    })
  '';
}
