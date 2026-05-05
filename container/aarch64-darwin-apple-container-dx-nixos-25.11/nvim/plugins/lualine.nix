{
  plugins.lualine = {
    enable = true;
    settings.options = {
      theme = "rose-pine";
      component_separators = "|";
      section_separators = "";
      icons_enabled = true;
      disabled_filetypes.statusline = [ "NvimTree" ];
    };
  };
}
