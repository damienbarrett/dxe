-- Extend the existing vim-tmux-navigator mappings across Herdr pane edges.
-- Herdr's direct Ctrl-h/j/k/l bindings forward into Neovim; this after-plugin
-- handles editor splits first and asks Herdr to move only when no split exists.
if vim.env.HERDR_ENV ~= "1" or not vim.env.HERDR_PANE_ID or vim.env.HERDR_PANE_ID == "" then
  return
end

local function navigate(vim_direction, herdr_direction)
  local previous_window = vim.api.nvim_get_current_win()
  vim.cmd("wincmd " .. vim_direction)

  if previous_window ~= vim.api.nvim_get_current_win() then
    return
  end

  local herdr = vim.fn.exepath("herdr")
  if herdr == "" then
    herdr = "herdr"
  end

  vim.fn.jobstart({
    herdr,
    "pane",
    "focus",
    "--pane",
    vim.env.HERDR_PANE_ID,
    "--direction",
    herdr_direction,
  }, { detach = true })
end

local mappings = {
  ["<C-h>"] = { "h", "left", "Navigate Left (Herdr/Neovim)" },
  ["<C-j>"] = { "j", "down", "Navigate Down (Herdr/Neovim)" },
  ["<C-k>"] = { "k", "up", "Navigate Up (Herdr/Neovim)" },
  ["<C-l>"] = { "l", "right", "Navigate Right (Herdr/Neovim)" },
}

for key, mapping in pairs(mappings) do
  vim.keymap.set("n", key, function()
    navigate(mapping[1], mapping[2])
  end, { silent = true, desc = mapping[3] })
end
