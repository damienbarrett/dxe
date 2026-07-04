{
  plugins.project-nvim = {
    enable = true;
    enableTelescope = true;
    settings = {
      manual_mode = false;
    };
  };

  keymaps = [
    { mode = "n"; key = "<leader>op"; action = "<cmd>Telescope projects<CR>"; options.desc = "[O]pen [P]rojects"; }
  ];
}
