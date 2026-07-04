{
  plugins.telescope = {
    enable = true;
    extensions = {
      ui-select.enable = true;
    };
    settings.defaults = {
      path_display = [ "smart" ];
      mappings.i = {
        "<C-j>" = { __raw = "require('telescope.actions').move_selection_next"; };
        "<C-k>" = { __raw = "require('telescope.actions').move_selection_previous"; };
        "<esc>" = { __raw = "require('telescope.actions').close"; };
      };
    };
  };

  keymaps = [
    { mode = "n"; key = "<leader>ob"; action = "<cmd>Telescope buffers<CR>"; options.desc = "[O]pen [B]uffers"; }
    { mode = "n"; key = "<leader>oc"; action = "<cmd>Telescope colorscheme<CR>"; options.desc = "[O]pen [C]olorscheme"; }
    { mode = "n"; key = "<leader>of"; action = "<cmd>Telescope find_files<CR>"; options.desc = "[O]pen [F]iles"; }
    { mode = "n"; key = "<leader>og"; action = "<cmd>Telescope live_grep<CR>"; options.desc = "[O]pen [G]rep"; }
    { mode = "n"; key = "<leader>oh"; action = "<cmd>Telescope help_tags<CR>"; options.desc = "[O]pen [H]elp"; }
    { mode = "n"; key = "<leader>om"; action = "<cmd>Telescope oldfiles<CR>"; options.desc = "[O]pen [M]ost Recent Files"; }
    { mode = "n"; key = "<leader>or"; action = "<cmd>Telescope oldfiles<CR>"; options.desc = "[O]pen [R]ecent files"; }
  ];
}
