# Changelog

## [Unreleased]

### Changed

- nmap's data files — the service and OS-fingerprint databases, `nse_main.lua`,
  the 612 NSE scripts and the 133 `nselib` modules — are now carried inside the
  binary and read from there. They previously shipped as a separate
  `nmap-<version>-data` archive; that archive is gone, and there is nothing to
  download alongside the binary any more. Your own copies still take
  precedence: `--datadir`, `$NMAPDIR` and `~/.nmap` are searched first, in the
  order upstream nmap documents.

### Fixed

- `-sC`, `-sV`, `-O` and the scripting engine work out of the box. Downloading
  the binary from the releases page used to get you none of them: it answered
  `could not locate nse_main.lua` and fell back to a plain port scanner unless
  you also downloaded the data archive and unpacked it into a `share/nmap`
  directory beside the binary, which nothing told you to do.
