# extra_plugins/'s admission rule (Fable C7): a plugin lives here only when
# no upstream NixVim module exists for it -- true for outline.nvim.
{ pkgs, ... }:
{
  extraPlugins = [
    (pkgs.vimUtils.buildVimPlugin {
      pname = "outline.nvim";
      version = "0-unstable-c293eb5";
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
