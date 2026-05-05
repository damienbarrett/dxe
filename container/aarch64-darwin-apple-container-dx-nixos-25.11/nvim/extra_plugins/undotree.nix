{ pkgs, ... }:
{
  plugins.undotree.enable = false;

  extraPlugins = [
    (pkgs.vimUtils.buildVimPlugin {
      name = "undotree-lua";
      src = pkgs.fetchFromGitHub {
        owner = "jiaoshijie";
        repo = "undotree";
        rev = "2c0a3c9488a8230213297cd573922ba6238f0c39";
        hash = "sha256-nr7CC7KW9crVdmI8jvZm86z0x4ugRtg0khpJ5Oh5nL8=";
      };
    })
  ];

  extraConfigLua = ''
    require('undotree').setup({
      float_diff = true,
      layout = "left_bottom",
      position = "left",
      ignore_filetype = { 'undotree', 'undotreeDiff', 'qf', 'TelescopePrompt', 'spectre_panel', 'tsplayground' },
      window = { winblend = 30 },
      keymaps = {
        ['j'] = "move_next",
        ['k'] = "move_prev",
        ['gj'] = "move2parent",
        ['J'] = "move_change_next",
        ['K'] = "move_change_prev",
        ['<cr>'] = "action_enter",
        ['p'] = "enter_diffbuf",
        ['q'] = "quit",
      },
    })
  '';

  keymaps = [
    { mode = "n"; key = "<leader>uu"; action = "<cmd>UndotreeToggle<CR>"; options.desc = "[U]ndo Toggle [U]ndo Tree"; }
  ];
}
