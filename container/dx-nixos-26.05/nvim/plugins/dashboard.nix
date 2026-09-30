{
  plugins.dashboard = {
    enable = true;
    settings.theme = "doom";
    settings.config.center = [
      { action = "ene | startinsert"; desc = " New file"; icon = " "; key = "n"; }
      { action = "Telescope oldfiles"; desc = " Recent files"; icon = " "; key = "r"; }
      { action = "qa"; desc = " Quit"; icon = " "; key = "q"; }
    ];
  };
}
