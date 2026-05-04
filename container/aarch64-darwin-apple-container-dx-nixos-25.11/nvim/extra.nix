{ pkgs }:
{
  extraPlugins = with pkgs.vimPlugins; [
    # Add plugins not available as NixVim modules or needing specific versions
    (pkgs.vimUtils.buildVimPlugin {
      name = "undotree-lua";
      src = pkgs.fetchFromGitHub {
        owner = "jiaoshijie";
        repo = "undotree";
        rev = "2c0a3c9488a8230213297cd573922ba6238f0c39";
        hash = "sha256-nr7CC7KW9crVdmI8jvZm86z0x4ugRtg0khpJ5Oh5nL8=";
      };
    })
    (pkgs.vimUtils.buildVimPlugin {
      name = "outline-nvim";
      doCheck = false;
      src = pkgs.fetchFromGitHub {
        owner = "hedyhli";
        repo = "outline.nvim";
        rev = "c293eb56db880a0539bf9d85b4a27816960b863e";
        hash = "sha256-xKu05IgOpgtt2W+WqXuTUjX66ffDrU8BDi8z7M6M1q4=";
      };
    })
    nvim-ts-context-commentstring
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

    require("outline").setup({})

    require('ts_context_commentstring').setup({
      enable_autocmd = false,
    })
    require('Comment').setup({
      pre_hook = require('ts_context_commentstring.integrations.comment_nvim').create_pre_hook(),
    })
  '';
}
