{
  description = "Radmin VPN for Linux via Wine";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, utils }:
    (utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        
        mingwW64 = pkgs.pkgsCross.mingwW64;
        mingw32 = pkgs.pkgsCross.mingw32;

        ddk64 = "${mingwW64.windows.mingw_w64_headers}/include/ddk";
      in
      {
        # Shell for development
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.wineWow64Packages.stable
            pkgs.gnumake
            pkgs.pkg-config
            pkgs.upx
            mingwW64.buildPackages.gcc
            mingw32.buildPackages.gcc
          ];
          buildInputs = [
            pkgs.gtk4
            pkgs.python3
          ];
          shellHook = ''
            export DDK_PATH64="${ddk64}"
          '';
        };

        # Package for NixOS
        packages.default = pkgs.stdenv.mkDerivation rec {
          pname = "radmin-vpn-linux";
          version = self.shortRev or "dirty";
          src = self;

          nativeBuildInputs = [
            pkgs.gnumake
            pkgs.pkg-config
            pkgs.upx
            pkgs.makeWrapper
            mingwW64.buildPackages.gcc
            mingw32.buildPackages.gcc
          ];

          buildInputs = [
            pkgs.gtk4
            pkgs.wineWow64Packages.stable
            pkgs.python3
          ];

          preBuild = ''
            export DDK_PATH64="${ddk64}"
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out/bin $out/share/radmin-vpn-linux
            
            cp -r build/ $out/share/radmin-vpn-linux/
            cp *.sh $out/share/radmin-vpn-linux/
            cp *.py $out/share/radmin-vpn-linux/
            
            cp -r contrib $out/share/radmin-vpn-linux/

            local runtimePath="${pkgs.lib.makeBinPath [ 
              pkgs.wineWow64Packages.stable 
              pkgs.python3 
              pkgs.iproute2 
              pkgs.procps 
              pkgs.gnugrep 
              pkgs.coreutils
              pkgs.gnused
              pkgs.gawk
              pkgs.wget
              pkgs.iptables
            ]}"

            # NOTE: We use makeWrapper instead of wrapProgram here because the upstream scripts resolve BUILD_DIR via `dirname $0`.
            # makeWrapper leaves argv0 alone, whereas wrapProgram overrides it, which would silently break the build paths.
            makeWrapper $out/share/radmin-vpn-linux/run.sh $out/bin/radmin-vpn-linux \
              --prefix PATH : "$runtimePath" \
              --suffix PATH : "/run/wrappers/bin" \
              --run 'export WINEPREFIX="$HOME/.local/share/radmin-vpn-linux/wineprefix"'

            makeWrapper $out/share/radmin-vpn-linux/run_datacenter.sh $out/bin/radmin-vpn-datacenter \
              --prefix PATH : "$runtimePath:${pkgs.lib.makeBinPath [ pkgs.x11vnc pkgs.xvfb pkgs.novnc pkgs.python3Packages.websockify ]}" \
              --suffix PATH : "/run/wrappers/bin" \
              --set NOVNC_PATH "${pkgs.novnc}/share/webapps/novnc" \
              --run 'export WINEPREFIX="$HOME/.local/share/radmin-vpn-linux/wineprefix"'
            
            makeWrapper $out/share/radmin-vpn-linux/run_vps.sh $out/bin/radmin-vpn-vps \
              --prefix PATH : "$runtimePath" \
              --suffix PATH : "/run/wrappers/bin" \
              --run 'export WINEPREFIX="$HOME/.local/share/radmin-vpn-linux/wineprefix"'

            makeWrapper $out/share/radmin-vpn-linux/health_check.sh $out/bin/radmin-vpn-health-check \
              --prefix PATH : "$runtimePath:${pkgs.lib.makeBinPath [ pkgs.nettools pkgs.nftables pkgs.glibc.bin ]}" \
              --suffix PATH : "/run/wrappers/bin" \
              --run 'export WINEPREFIX="$HOME/.local/share/radmin-vpn-linux/wineprefix"'

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Run Radmin VPN on Linux via Wine";
            homepage = "https://github.com/baptisterajaut/radmin-vpn-linux";
            license = licenses.gpl3Only;
            platforms = platforms.linux;
            mainProgram = "radmin-vpn-linux";
          };
        };
      }))

      // {
        # Overlay
        overlays.default = final: prev: {
          radmin-vpn-linux = self.packages.${final.system}.default;
        };
      };
}

