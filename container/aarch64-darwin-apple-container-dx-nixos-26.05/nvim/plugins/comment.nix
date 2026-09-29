{
  plugins.comment = {
    enable = true;
    # Treesitter-aware comment strings inside embedded languages (JSX in a
    # .js buffer, Lua in a Nix string, ...) -- ts-context-commentstring.nix
    # provides the plugin this pre_hook calls into. Previously set by a raw
    # second `require('Comment').setup(...)` call that silently overrode
    # whatever this typed option produced (Fable C7).
    settings.pre_hook = "require('ts_context_commentstring.integrations.comment_nvim').create_pre_hook()";
  };
}
