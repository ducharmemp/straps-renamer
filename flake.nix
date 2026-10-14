{
  description = "straps-renamer — :StrapsRename titles a straps session with a cheap model so the session is greppable";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    straps.url = "git+ssh://git@github.com/ducharmemp/straps";
    straps.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, straps }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkRenamer = pkgs: pkgs.vimUtils.buildVimPlugin {
        pname = "straps-renamer";
        version = self.shortRev or self.dirtyShortRev or "dev";
        src = self;
        meta = {
          description = "Model-generated, grep-friendly titles for straps.nvim sessions";
          license = nixpkgs.lib.licenses.mit;
        };
      };
    in
    {
      packages = forAllSystems (pkgs: rec {
        straps-renamer = mkRenamer pkgs;
        default = straps-renamer;
      });

      overlays.default = final: prev: {
        vimPlugins = prev.vimPlugins // { straps-renamer = mkRenamer final; };
      };

      # Import alongside the straps module:
      #   imports = [ straps.nixvimModules.default straps-renamer.nixvimModules.default ];
      #   plugins.straps.enable = true;
      #   plugins.straps-renamer.enable = true;
      # setup() runs after straps' own setup (lib.mkAfter), which is all the
      # command redefinition needs; the plugin file also redefines it on
      # VimEnter for non-nixvim installs where straps' plugin file loads later.
      nixvimModules = rec {
        straps-renamer = { lib, config, pkgs, ... }:
          let
            cfg = config.plugins.straps-renamer;
          in
          {
            options.plugins.straps-renamer = {
              enable = lib.mkEnableOption "straps-renamer, model-generated session titles";
              package = lib.mkOption {
                type = lib.types.package;
                default = mkRenamer pkgs;
                defaultText = lib.literalExpression ''straps-renamer.packages.''${system}.default'';
                description = "The straps-renamer plugin package.";
              };
              settings = lib.mkOption {
                type = with lib.types; attrsOf anything;
                default = { };
                example = {
                  anthropic_model = "claude-haiku-4-5-20251001";
                  openai_model = "gpt-4.1-mini";
                  max_title_chars = 60;
                };
                description = ''
                  Passed verbatim to require("straps_renamer").setup(). See the
                  config table in lua/straps_renamer/init.lua for every key.
                '';
              };
            };
            config = lib.mkIf cfg.enable {
              extraPlugins = [ cfg.package ];
              extraPackages = [ pkgs.curl ];
              extraConfigLua = lib.mkAfter ''
                require("straps_renamer").setup(${lib.generators.toLua { } cfg.settings})
              '';
            };
          };
        default = straps-renamer;
      };

      checks = forAllSystems (pkgs: {
        tests = pkgs.stdenvNoCC.mkDerivation {
          name = "straps-renamer-tests";
          src = self;
          nativeBuildInputs = [
            pkgs.neovim pkgs.curl
            pkgs.luajitPackages.busted pkgs.luajitPackages.nlua
          ];
          dontBuild = true;
          doCheck = true;
          checkPhase = ''
            export HOME=$TMPDIR
            export XDG_DATA_HOME=$TMPDIR/data XDG_STATE_HOME=$TMPDIR/state XDG_CACHE_HOME=$TMPDIR/cache
            export STRAPS_ROOT=${straps}
            fail=0
            for t in tests/*_spec.lua; do
              echo "== $t"
              busted "$t" || fail=1
            done
            [ "$fail" = 0 ]
          '';
          installPhase = "touch $out";
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.neovim pkgs.curl
            pkgs.luajitPackages.busted pkgs.luajitPackages.nlua
          ];
          shellHook = ''
            export STRAPS_ROOT=''${STRAPS_ROOT:-${straps}}
          '';
        };
      });
    };
}
