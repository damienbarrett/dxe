{ pkgs, ... }:
{
  extraPlugins = [
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
  ];

  extraConfigLua = ''
    require("outline").setup({})
  '';

  keymaps = [
    { mode = "n"; key = "<leader>oo"; action = "<cmd>Outline<CR>"; options.desc = "[O]pen [O]utline"; }
  ];
}
