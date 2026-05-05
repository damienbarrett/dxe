{ lib, ... }:
{
  keymaps = [
    { mode = "n"; key = "<leader>oe"; action = "<cmd>Ex<CR>"; options.desc = "[O]pen [E]xplore"; }
    { mode = "v"; key = "J"; action = ":m '>+1<CR>gv=gv"; options.desc = "[J] Move Down"; }
    { mode = "v"; key = "K"; action = ":m '<-2<CR>gv=gv"; options.desc = "[K] Move Up"; }
    { mode = "v"; key = "<"; action = "<gv"; options.desc = "Indent Left"; }
    { mode = "v"; key = ">"; action = ">gv"; options.desc = "Indent Right"; }
    { mode = "n"; key = "<leader><Up>"; action = ":resize -2<CR>"; options.desc = "Resize Up"; }
    { mode = "n"; key = "<leader><Down>"; action = ":resize +2<CR>"; options.desc = "Resize Down"; }
    { mode = "n"; key = "<leader><Left>"; action = ":vertical resize +2<CR>"; options.desc = "Resize Left"; }
    { mode = "n"; key = "<leader><Right>"; action = ":vertical resize -2<CR>"; options.desc = "Resize Right"; }
    { mode = "n"; key = "J"; action = "mzJ`z"; options.desc = "[J] Join Lines"; }
    { mode = "n"; key = "<C-d>"; action = "<C-d>zz"; options.desc = "Scroll [D]own"; }
    { mode = "n"; key = "<C-u>"; action = "<C-u>zz"; options.desc = "Scroll [U]p"; }
    { mode = "n"; key = "<C-j>"; action = "<C-d>zz"; options.desc = "Scroll [D]own [Ctrl-J]"; }
    { mode = "n"; key = "<C-k>"; action = "<C-u>zz"; options.desc = "Scroll [U]p [Ctrl-K]"; }
    { mode = "n"; key = "n"; action = "nzzzv"; options.desc = "[N]ext Search"; }
    { mode = "n"; key = "N"; action = "Nzzzv"; options.desc = "[P]revious Search"; }
    { mode = "n"; key = "<leader>y"; action = "\"+y"; options.desc = "[Y]ank to Clipboard"; }
    { mode = "v"; key = "<leader>y"; action = "\"+y"; options.desc = "[Y]ank to Clipboard"; }
    { mode = "n"; key = "<leader>Y"; action = "\"+Y"; options.desc = "[Y]ank Line to Clipboard"; }
    { mode = "n"; key = "<leader>p"; action = "\"+p"; options.desc = "[P]aste from Clipboard"; }
    { mode = "n"; key = "<leader>P"; action = "\"+P"; options.desc = "[P]aste from Clipboard"; }
    { mode = "v"; key = "<leader>p"; action = "\"+p"; options.desc = "[P]aste from Clipboard"; }
    { mode = "v"; key = "<leader>P"; action = "\"+P"; options.desc = "[P]aste from Clipboard"; }
    { mode = "n"; key = "<leader>cb"; action = "<cmd>%bd|e#|bd#<CR>"; options = { silent = true; desc = "[C]lear [B]uffers"; }; }
    { mode = "n"; key = "<leader>cc"; action = "<cmd>nohl<CR>"; options = { silent = true; desc = "[C]lear [S]earch"; }; }
    { mode = "n"; key = "<leader>r"; action = ":set wrap!<CR>"; options = { silent = true; desc = "Toggle W[r]ap"; }; }
    { mode = "n"; key = "k"; action = "v:count ? 'k' : 'gk'"; options = { expr = true; noremap = true; desc = "Move Up (Visual Line)"; }; }
    { mode = "n"; key = "j"; action = "v:count ? 'j' : 'gj'"; options = { expr = true; noremap = true; desc = "Move Down (Visual Line)"; }; }
    { mode = "n"; key = "gj"; action = "j"; options = { silent = true; desc = "Move Down (Physical Line)"; }; }
    { mode = "n"; key = "gk"; action = "k"; options = { silent = true; desc = "Move Up (Physical Line)"; }; }
    { mode = "n"; key = "<leader>h"; action = "<C-w>h"; options.desc = "Window Move Left"; }
    { mode = "n"; key = "<leader>j"; action = "<C-w>j"; options.desc = "Window Move Down"; }
    { mode = "n"; key = "<leader>k"; action = "<C-w>k"; options.desc = "Window Move Up"; }
    { mode = "n"; key = "<leader>l"; action = "<C-w>l"; options.desc = "Window Move Right"; }
    { mode = "n"; key = "<leader>w"; action = "<C-w>"; options.desc = "Window Prefix"; }
    { mode = "n"; key = "<leader>tn"; action = "<cmd>tabnew<CR>"; options.desc = "[T]ab [N]ew"; }
    { mode = "n"; key = "<leader>th"; action = "<cmd>tabprevious<CR>"; options.desc = "[T]ab [P]revious"; }
    { mode = "n"; key = "<leader>tl"; action = "<cmd>tabnext<CR>"; options.desc = "[T]ab [N]ext"; }
    { mode = "n"; key = "<leader>tc"; action = "<cmd>tabclose<CR>"; options.desc = "[T]ab [C]lose"; }
    { mode = "n"; key = "<C-p>"; action = "<cmd>bprevious<CR>"; options.desc = "[P]revious Buffer"; }
    { mode = "n"; key = "<C-n>"; action = "<cmd>bnext<CR>"; options.desc = "[N]ext Buffer"; }
  ];
}
