{
  plugins.trouble.enable = true;

  keymaps = [
    { mode = "n"; key = "<leader>xx"; action = "<cmd>Trouble toggle<CR>"; options.desc = "[X]rouble [X]oggle"; }
  ];
}
