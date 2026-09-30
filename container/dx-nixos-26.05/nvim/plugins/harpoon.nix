{
  plugins.harpoon = {
    enable = true;
    enableTelescope = true;
  };

  keymaps = [
    { mode = "n"; key = "<leader>ha"; action.__raw = "function() require('harpoon'):list():add() end"; options.desc = "[H]arpoon [A]dd"; }
    { mode = "n"; key = "<leader>hm"; action.__raw = "function() require('harpoon').ui:toggle_quick_menu(require('harpoon'):list()) end"; options.desc = "[H]arpoon [M]enu"; }
    { mode = "n"; key = "<leader>h1"; action.__raw = "function() require('harpoon'):list():select(1) end"; options.desc = "[H]arpoon Goto [1]"; }
    { mode = "n"; key = "<leader>h2"; action.__raw = "function() require('harpoon'):list():select(2) end"; options.desc = "[H]arpoon Goto [2]"; }
    { mode = "n"; key = "<leader>h3"; action.__raw = "function() require('harpoon'):list():select(3) end"; options.desc = "[H]arpoon Goto [3]"; }
    { mode = "n"; key = "<leader>h4"; action.__raw = "function() require('harpoon'):list():select(4) end"; options.desc = "[H]arpoon Goto [4]"; }
    { mode = "n"; key = "<leader>h5"; action.__raw = "function() require('harpoon'):list():select(5) end"; options.desc = "[H]arpoon Goto [5]"; }
    { mode = "n"; key = "<leader>h6"; action.__raw = "function() require('harpoon'):list():select(6) end"; options.desc = "[H]arpoon Goto [6]"; }
    { mode = "n"; key = "<leader>h7"; action.__raw = "function() require('harpoon'):list():select(7) end"; options.desc = "[H]arpoon Goto [7]"; }
    { mode = "n"; key = "<leader>h8"; action.__raw = "function() require('harpoon'):list():select(8) end"; options.desc = "[H]arpoon Goto [8]"; }
    { mode = "n"; key = "<leader>h9"; action.__raw = "function() require('harpoon'):list():select(9) end"; options.desc = "[H]arpoon Goto [9]"; }
    { mode = "n"; key = "<leader>hp"; action.__raw = "function() require('harpoon'):list():prev() end"; options.desc = "[H]arpoon [P]revious"; }
    { mode = "n"; key = "<leader>hn"; action.__raw = "function() require('harpoon'):list():next() end"; options.desc = "[H]arpoon [N]ext"; }
  ];
}
