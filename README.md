# nmap

[nmap](https://nmap.org/) as a single self-contained binary, built natively for Linux and macOS.

[![CI](https://github.com/unpins/nmap/actions/workflows/nmap.yml/badge.svg)](https://github.com/unpins/nmap/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install nmap`.

## Usage

Run `nmap` with [unpin](https://github.com/unpins/unpin):

```bash
unpin nmap -sV scanme.nmap.org
```

To install it onto your PATH:

```bash
unpin install nmap
```

nmap's data files — the service and OS-fingerprint databases and the full NSE
script library — are inside the binary, so `-sC`/`-sV`/`-O` and the scripting
engine work out of the box with nothing else to download.

## Man pages

`nmap.1` is embedded in the binary — read it with `unpin man nmap`.

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

The [Releases](https://github.com/unpins/nmap/releases) page has standalone binaries for manual download.

## Build notes

- A few dependency tweaks make the static build link. nixpkgs' `liblinear`
  only builds a shared object (no static-archive path), so it is archived into
  a `liblinear.a`. The `--gc-sections` optimization is turned off because it
  overrides the Makefile `LDFLAGS` that carry nmap's in-tree `-L` search paths.
  And on macOS, nmap is pointed at its own bundled liblua so the scripting
  engine links statically. macOS also folds the C++ runtime (`libc++`) in as a
  static archive, since nmap is a C++ program and the dynamic system `libc++`
  isn't on the portable-binary allow-list. Both keep the binary free of
  non-system libraries.
- The data files (`nmap-services`, `nmap-os-db`, `nmap-service-probes`, the NSE
  scripts and `nselib`) are carried inside the binary and read from there. Your
  own copies still win: `--datadir`, `$NMAPDIR` and `~/.nmap` are searched
  first, in exactly the order upstream nmap documents.
- The scripting engine's own unit tests run on every build that can execute what
  it just produced, and CI additionally reads a script out of the embedded tree
  on every platform — a binary that links but cannot reach its data files fails
  the build instead of shipping.
- `-oX` reports carry no `xml-stylesheet` line. The only copy of `nmap.xsl` is
  the one inside the binary, at a path that exists nowhere on disk, so naming it
  would send every reader of the report to a file it cannot open. For a styled
  report in a browser, pass `--webxml` (references nmap.org's copy) or
  `--stylesheet <path>` (your own).
- **Windows** is not shipped: nmap's packet capture requires the
  [Npcap](https://npcap.com/) kernel driver, loaded at runtime from a separate
  signed driver install, which can't live inside a self-contained binary (the
  official Nmap for Windows isn't a single executable either).
