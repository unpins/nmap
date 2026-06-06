# nmap

Standalone build of [nmap](https://nmap.org/).

[![CI](https://github.com/unpins/nmap/actions/workflows/nmap.yml/badge.svg)](https://github.com/unpins/nmap/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

## Usage

Run `nmap` with [unpin](https://github.com/unpins/unpin):

```bash
unpin nmap -sV scanme.nmap.org
```

To install it onto your PATH:

```bash
unpin install nmap
```

nmap's data files — the service/OS-fingerprint databases and the full NSE
script library — are fetched alongside the binary, so `-sC`/`-sV`/`-O` and the
scripting engine work out of the box.

## Build locally

```bash
nix build github:unpins/nmap
./result/bin/nmap --version
```

Or run directly:

```bash
nix run github:unpins/nmap
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/nmap/releases) page has standalone binaries for manual download, paired with a `nmap-<version>-data` archive holding the script and fingerprint data.

## Man pages

`nmap.1` is embedded in the binary — read it with `unpin man nmap`.

## Build notes

- A few dependency tweaks make the static build link. nixpkgs' `liblinear`
  only builds a shared object (no static-archive path), so it is archived into
  a `liblinear.a`. The `--gc-sections` optimization is turned off because it
  overrides the Makefile `LDFLAGS` that carry nmap's in-tree `-L` search paths.
  And on macOS, where `pkgsStatic.lua` installs only a `liblua.dylib` (no
  static archive), nmap is pointed at its own bundled liblua so the scripting
  engine links statically and the binary stays free of non-system libraries.
- The data files (`nmap-services`, `nmap-os-db`, `nmap-service-probes`, the NSE
  scripts) ship as a companion archive. nmap finds them next to the binary —
  its search tries `<exe-dir>/../share/nmap` before the compiled path — so no
  lookup patch is needed.
- **Windows** is not shipped: nmap's packet capture requires the
  [Npcap](https://npcap.com/) kernel driver, loaded at runtime from a separate
  signed driver install, which can't live inside a self-contained binary (the
  official Nmap for Windows isn't a single executable either).
