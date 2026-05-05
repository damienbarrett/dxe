{
  plugins.oil = {
    enable = true;
    settings = {
      view_options = {
        show_hidden = true;
      };
    };
  };

  keymaps = [
    { mode = "n"; key = "-"; action = "<CMD>Oil<CR>"; options.desc = "Open Oil (Vinegar style)"; }
    { mode = "n"; key = "<leader>ov"; action = "<CMD>Oil<CR>"; options.desc = "[O]pen [V]inegar (Oil)"; }
  ];
}
