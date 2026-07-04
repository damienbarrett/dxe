{
  plugins.lsp = {
    enable = true;
    servers = {
      lua_ls.enable = true;
      marksman.enable = true;
      nil_ls.enable = true;
      ts_ls.enable = true;
      pyright.enable = true;
      gopls.enable = true;
    };
    keymaps.lspBuf = {
      "K" = { action = "hover"; desc = "LSP Hover"; };
      "gd" = { action = "definition"; desc = "LSP Definition"; };
      "<leader>ca" = { action = "code_action"; desc = "LSP Code Action"; };
    };
  };
}
