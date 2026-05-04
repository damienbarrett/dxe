{
  colorschemes.rose-pine = {
    enable = true;
    settings.variant = "dawn";
  };

  plugins = {
    lualine = {
      enable = true;
      settings.options = {
        theme = "rose-pine";
        component_separators = "|";
        section_separators = "";
        icons_enabled = true;
        disabled_filetypes.statusline = [ "NvimTree" ];
      };
    };

    telescope = {
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

    treesitter = {
      enable = true;
      settings.highlight.enable = true;
      nixGrammars = true;
    };

    lsp = {
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

    cmp = {
      enable = true;
      autoEnableSources = true;
      settings = {
        snippet.expand = "function(args) require('luasnip').lsp_expand(args.body) end";
        mapping = {
          "<C-k>" = "cmp.mapping.select_prev_item()";
          "<C-j>" = "cmp.mapping.select_next_item()";
          "<C-u>" = "cmp.mapping.scroll_docs(4)";
          "<C-d>" = "cmp.mapping.scroll_docs(-4)";
          "<C-Space>" = "cmp.mapping.complete()";
          "<C-c>" = "cmp.mapping.abort()";
          "<CR>" = "cmp.mapping.confirm({ select = true })";
          "<Tab>" = "cmp.mapping(function(fallback) if cmp.visible() then cmp.select_next_item() elseif require('luasnip').expand_or_jumpable() then require('luasnip').expand_or_jump() else fallback() end end, { 'i', 's' })";
          "<S-Tab>" = "cmp.mapping(function(fallback) if cmp.visible() then cmp.select_prev_item() elseif require('luasnip').jumpable(-1) then require('luasnip').jump(-1) else fallback() end end, { 'i', 's' })";
        };
        sources = [
          { name = "nvim_lsp"; }
          { name = "luasnip"; }
          { name = "path"; }
          { name = "buffer"; }
        ];
      };
    };

    luasnip.enable = true;
    
    # Use NixVim module for comment, but configure pre_hook in extraConfigLua if needed
    comment = {
      enable = true;
    };

    # Disable builtin undotree (VimScript) and use our extraPlugin (Lua)
    undotree.enable = false;

    trouble.enable = true;
    which-key.enable = true;
    todo-comments.enable = true;
    
    project-nvim = {
      enable = true;
      enableTelescope = true;
      settings = {
        manual_mode = false;
      };
    };
    
    yazi.enable = true;
    lazygit.enable = true;
    web-devicons.enable = true;
    
    harpoon = {
      enable = true;
      enableTelescope = true;
    };
    
    dashboard = {
      enable = true;
      settings.theme = "doom";
      settings.config.center = [
        { action = "ene | startinsert"; desc = " New file"; icon = " "; key = "n"; }
        { action = "Telescope oldfiles"; desc = " Recent files"; icon = " "; key = "r"; }
        { action = "qa"; desc = " Quit"; icon = " "; key = "q"; }
      ];
    };
    
    oil = {
      enable = true;
      settings = {
        view_options = {
          show_hidden = true;
        };
      };
    };
  };
}
