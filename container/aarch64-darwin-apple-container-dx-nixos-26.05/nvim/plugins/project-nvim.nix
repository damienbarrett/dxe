{
  plugins.project-nvim = {
    enable = true;
    enableTelescope = true;
    settings = {
      manual_mode = false;
    };
  };

  # project.nvim 4.1.1's write_history() emits an unconditional
  # vim.notify(WARN) "No data available to write!" when there is no project
  # history to persist (dashboard / scratch sessions, via its deferred write
  # and VimLeavePre). It bypasses the plugin's own log.enabled=false gate
  # (history.lua:714), so no config option silences it. Drop exactly that
  # one message and level; pass everything else through.
  extraConfigLua = ''
    do
      local notify = vim.notify
      local empty_history =
        "(project.util.history.write_history): No data available to write!"
      vim.notify = function(msg, level, opts)
        if msg == empty_history and level == vim.log.levels.WARN then
          return
        end
        return notify(msg, level, opts)
      end
    end
  '';

  keymaps = [
    { mode = "n"; key = "<leader>op"; action = "<cmd>Telescope projects<CR>"; options.desc = "[O]pen [P]rojects"; }
  ];
}
