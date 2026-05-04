{ lib }:
{
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
    { mode = "n"; key = "<leader>ob"; action = "<cmd>Telescope buffers<CR>"; options.desc = "[O]pen [B]uffers"; }
    { mode = "n"; key = "<leader>oc"; action = "<cmd>Telescope colorscheme<CR>"; options.desc = "[O]pen [C]olorscheme"; }
    { mode = "n"; key = "<leader>of"; action = "<cmd>Telescope find_files<CR>"; options.desc = "[O]pen [F]iles"; }
    { mode = "n"; key = "<leader>og"; action = "<cmd>Telescope live_grep<CR>"; options.desc = "[O]pen [G]rep"; }
    { mode = "n"; key = "<leader>oh"; action = "<cmd>Telescope help_tags<CR>"; options.desc = "[O]pen [H]elp"; }
    { mode = "n"; key = "<leader>om"; action = "<cmd>Telescope oldfiles<CR>"; options.desc = "[O]pen [M]ost Recent Files"; }
    { mode = "n"; key = "<leader>or"; action = "<cmd>Telescope oldfiles<CR>"; options.desc = "[O]pen [R]ecent files"; }
    { mode = "n"; key = "<leader>oe"; action = "<cmd>Ex<CR>"; options.desc = "[O]pen [E]xplore"; }
    { mode = "v"; key = "J"; action = ":m '>+1<CR>gv=gv"; options.desc = "[J] Move Lines Down"; }
    { mode = "v"; key = "K"; action = ":m '<-2<CR>gv=gv"; options.desc = "[K] Move Lines Up"; }
    { mode = "v"; key = "<"; action = "<gv"; options.desc = "Indent Left"; }
    { mode = "v"; key = ">"; action = ">gv"; options.desc = "Indent Right"; }
    { mode = "n"; key = "<leader><Up>"; action = ":resize -2<CR>"; options.desc = "Resize Up"; }
    { mode = "n"; key = "<leader><Down>"; action = ":resize +2<CR>"; options.desc = "Resize Down"; }
    { mode = "n"; key = "<leader><Left>"; action = ":vertical resize +2<CR>"; options.desc = "Resize Left"; }
    { mode = "n"; key = "<leader><Right>"; action = ":vertical resize -2<CR>"; options.desc = "Resize Right"; }
    { mode = "n"; key = "J"; action = "mzJ`z"; options.desc = "Concatenate Lines"; }
    { mode = "n"; key = "<C-d>"; action = "<C-d>zz"; options.desc = "Scroll [D]own"; }
    { mode = "n"; key = "<C-u>"; action = "<C-u>zz"; options.desc = "Scroll [U]p"; }
    { mode = "n"; key = "<C-j>"; action = "<C-d>zz"; options.desc = "Scroll Down [Ctrl-J]"; }
    { mode = "n"; key = "<C-k>"; action = "<C-u>zz"; options.desc = "Scroll Up [Ctrl-K]"; }
    { mode = "n"; key = "n"; action = "nzzzv"; options.desc = "Next Search Result"; }
    { mode = "n"; key = "N"; action = "Nzzzv"; options.desc = "Previous Search Result"; }
    { mode = "n"; key = "<leader>y"; action = "\"+y"; options.desc = "Copy to Clipboard"; }
    { mode = "v"; key = "<leader>y"; action = "\"+y"; options.desc = "Copy to Clipboard"; }
    { mode = "n"; key = "<leader>Y"; action = "\"+Y"; options.desc = "Copy to Clipboard"; }
    { mode = "n"; key = "<leader>p"; action = "\"+p"; options.desc = "Paste from Clipboard"; }
    { mode = "n"; key = "<leader>P"; action = "\"+P"; options.desc = "Paste from Clipboard"; }
    { mode = "v"; key = "<leader>p"; action = "\"+p"; options.desc = "Paste from Clipboard"; }
    { mode = "v"; key = "<leader>P"; action = "\"+P"; options.desc = "Paste from Clipboard"; }
    { mode = "n"; key = "<leader>cb"; action = "<cmd>%bd|e#|bd#<CR>"; options = { silent = true; desc = "[C]lear VIM [B]uffers"; }; }
    { mode = "n"; key = "<leader>cc"; action = "<cmd>nohl<CR>"; options = { silent = true; desc = "[C]lear [Current] Search Results"; }; }
    { mode = "n"; key = "<leader>r"; action = ":set wrap!<CR>"; options = { silent = true; desc = "Toggle W[r]ap"; }; }
    { mode = "n"; key = "k"; action = "v:count ? 'k' : 'gk'"; options = { expr = true; noremap = true; desc = "Move Up (Visual Line)"; }; }
    { mode = "n"; key = "j"; action = "v:count ? 'j' : 'gj'"; options = { expr = true; noremap = true; desc = "Move Down (Visual Line)"; }; }
    { mode = "n"; key = "gj"; action = "j"; options = { silent = true; desc = "Move Down (Physical Line)"; }; }
    { mode = "n"; key = "gk"; action = "k"; options = { silent = true; desc = "Move Up (Physical Line)"; }; }
    { mode = "n"; key = "<leader>h"; action = "<C-w>h"; options.desc = "Windows move left"; }
    { mode = "n"; key = "<leader>j"; action = "<C-w>j"; options.desc = "Window move down"; }
    { mode = "n"; key = "<leader>k"; action = "<C-w>k"; options.desc = "Window move up"; }
    { mode = "n"; key = "<leader>l"; action = "<C-w>l"; options.desc = "Window move right"; }
    { mode = "n"; key = "<leader>w"; action = "<C-w>"; options.desc = "Windows move"; }
    { mode = "n"; key = "<leader>tn"; action = "<cmd>tabnew<CR>"; options.desc = "[T]ab [N]ew"; }
    { mode = "n"; key = "<leader>th"; action = "<cmd>tabprevious<CR>"; options.desc = "[T]ab [H] Left"; }
    { mode = "n"; key = "<leader>tl"; action = "<cmd>tabnext<CR>"; options.desc = "[T]ab [L] Right"; }
    { mode = "n"; key = "<leader>tc"; action = "<cmd>tabclose<CR>"; options.desc = "[T]ab [C]lose"; }
    { mode = "n"; key = "<C-p>"; action = "<cmd>bprevious<CR>"; options.desc = "[Ctrl]-[P]revious Buffer"; }
    { mode = "n"; key = "<C-n>"; action = "<cmd>bnext<CR>"; options.desc = "[Ctrl]-[N]ext Buffer"; }
    { mode = "n"; key = "-"; action = "<CMD>Oil<CR>"; options.desc = "Open Oil (Vinegar style)"; }
    { mode = "n"; key = "<leader>ov"; action = "<CMD>Oil<CR>"; options.desc = "[O]pen [V]inegar (Oil)"; }
    { mode = "n"; key = "<leader>uu"; action = "<cmd>UndotreeToggle<CR>"; options.desc = "[U]ndo Toggle [U]ndo Tree"; }
    { mode = "n"; key = "<leader>oo"; action = "<cmd>Outline<CR>"; options.desc = "[O]pen [O]utline"; }
    { mode = "n"; key = "<leader>op"; action = "<cmd>Telescope projects<CR>"; options.desc = "[O]pen [P]rojects"; }
    { mode = "n"; key = "<leader>lg"; action = "<cmd>LazyGit<CR>"; options.desc = "[L]azy [G]it"; }
    { mode = "n"; key = "<leader>oy"; action = "<cmd>Yazi<CR>"; options.desc = "[O]pen [Y]azi"; }
    { mode = "n"; key = "<leader>xx"; action = "<cmd>Trouble toggle<CR>"; options.desc = "[X]rouble [X]oggle"; }
  ];
}
