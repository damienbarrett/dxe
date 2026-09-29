# WP2.2 (docs/reviews/2026-09-29-fable.md finding C2): a plain NixVim
# module now, not a `{ pkgs, nixvim, system }:`-wrapped `makeNixvim` call --
# it never used the `pkgs` argument it used to take. flake.nix now builds
# this with `nixvim.legacyPackages.${system}.makeNixvimWithModule { inherit
# pkgs; module = ./nixvim.nix; }`, passing the flake's own per-system
# nixpkgs instance in directly (which sets NixVim's `nixpkgs.pkgs`,
# wrappers/standalone.nix in the pinned NixVim source) instead of NixVim
# constructing a third nixpkgs instance from its own flake input -- which is
# what silenced the `nixpkgs.source`/`follows` evaluation warning.
{
  viAlias = true;
  vimAlias = true;
  imports = [
    ./nvim/options.nix
    ./nvim/keymaps.nix
    ./nvim/plugins/cmp.nix
    ./nvim/plugins/comment.nix
    ./nvim/plugins/dashboard.nix
    ./nvim/plugins/harpoon.nix
    ./nvim/plugins/lazygit.nix
    ./nvim/plugins/lsp.nix
    ./nvim/plugins/lualine.nix
    ./nvim/plugins/luasnip.nix
    ./nvim/plugins/oil.nix
    ./nvim/plugins/project-nvim.nix
    ./nvim/plugins/render-markdown.nix
    ./nvim/plugins/rose-pine.nix
    ./nvim/plugins/telescope.nix
    ./nvim/plugins/tinted-nvim.nix
    ./nvim/plugins/todo-comments.nix
    ./nvim/plugins/treesitter.nix
    ./nvim/plugins/trouble.nix
    ./nvim/plugins/web-devicons.nix
    ./nvim/plugins/which-key.nix
    ./nvim/plugins/yazi.nix
    ./nvim/extra_plugins/outline.nix
    ./nvim/extra_plugins/ts-context-commentstring.nix
    ./nvim/extra_plugins/undotree.nix
    # Seamless tmux/vim Ctrl-h/j/k/l navigation. Remove this line and
    # nvim/plugins/vim-tmux-navigator.nix (and restore the Ctrl-J/Ctrl-K maps in
    # keymaps.nix) to revert.
    ./nvim/plugins/vim-tmux-navigator.nix
  ];
}
