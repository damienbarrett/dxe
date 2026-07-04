# vim-tmux-navigator (Neovim side): prefix-less Ctrl-h/j/k/l navigation that
# moves seamlessly between Neovim splits and tmux panes. The tmux half lives in
# home/tools.nix (programs.tmux.plugins).
#
# TO REVERT THIS FEATURE ENTIRELY (it is intentionally self-contained):
#   1. delete this file,
#   2. remove its line from nixvim.nix `imports`,
#   3. remove the `vim-tmux-navigator` entry from home/tools.nix plugins,
#   4. (optional) drop the note next to the Ctrl-J/Ctrl-K maps in nvim/keymaps.nix.
# Nothing else depends on it. Once removed, the Ctrl-J/Ctrl-K scroll aliases in
# keymaps.nix take effect again.
{ pkgs, ... }:
{
  extraPlugins = [ pkgs.vimPlugins.vim-tmux-navigator ];

  # Map the keys explicitly (rather than the plugin's auto-mappings) so every
  # binding is visible in the Nix config. The Ctrl-J / Ctrl-K scroll aliases
  # were removed from keymaps.nix so these win (Ctrl-D / Ctrl-U still scroll).
  globals.tmux_navigator_no_mappings = 1;

  keymaps = [
    { mode = "n"; key = "<C-h>"; action = "<cmd>TmuxNavigateLeft<CR>";  options = { silent = true; desc = "Navigate Left (tmux/vim)"; }; }
    { mode = "n"; key = "<C-j>"; action = "<cmd>TmuxNavigateDown<CR>";  options = { silent = true; desc = "Navigate Down (tmux/vim)"; }; }
    { mode = "n"; key = "<C-k>"; action = "<cmd>TmuxNavigateUp<CR>";    options = { silent = true; desc = "Navigate Up (tmux/vim)"; }; }
    { mode = "n"; key = "<C-l>"; action = "<cmd>TmuxNavigateRight<CR>"; options = { silent = true; desc = "Navigate Right (tmux/vim)"; }; }
  ];
}
