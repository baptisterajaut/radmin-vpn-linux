# NixOS installation and development guide

This project supports NixOS out of the box using **Nix Flakes**.

The packaged derivation automatically isolates the required Wine environment into `~/.local/share/radmin-vpn/wineprefix` to prevent any interference with your system or personal Wine configurations.

## Temporary installing or testing

You can execute this project directly from GitHub, without cloning the repository:
```bash
nix run github:baptisterajaut/radmin-vpn-linux
```

## Declarative installing

To add Radmin VPN to your NixOS system configuration:

### 1. Add to your `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs"; # or your release of nixpkgs

    radmin-vpn-linux.url = "github:baptisterajaut/radmin-vpn-linux";
  };

  outputs = { self, nixpkgs, radmin-vpn-linux, ... }: {
    nixosConfigurations.your-host = nixpkgs.lib.nixosSystem {
      modules = [
        { nixpkgs.overlays = [ radmin-vpn-linux.overlays.default ]; }

        # your other modules, like configuration.nix, etc.
      ];
    };
  };
}
```

### 2. Add package to your environment:

In your configuration file (e.g., `configuration.nix` or `packages.nix`):

```nix
{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    radmin-vpn-linux
  ];
}
```

### 3. Rebuild:

```bash
sudo nixos-rebuild switch --flake .
```

And you're done!

## Usage

`radmin-vpn-linux` is equal to `run.sh`

`radmin-vpn-vps` is equal to `run_vps.sh`

`radmin-vpn-datacenter` is equal to `run_datacenter.sh`


Everything else is the same!

## Entering a development shell and building a package

### 1. Clone repository:

```bash
git clone https://github.com/baptisterajaut/radmin-vpn-linux.git
cd radmin-vpn-linux
```

### 2. Entering a development shell:

```bash
nix develop
```

### 3. Building a package:

```bash
nix build
```

You will get `result` directory that is symlink to /nix/store path of the built package.
