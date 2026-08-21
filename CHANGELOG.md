# Changelog

## [Unreleased]

### Changed

- nmap's data files — the service and OS-fingerprint databases, `nse_main.lua`,
  the 614 NSE scripts and the 190 `nselib` modules — are now carried inside the
  binary and read from there. They previously shipped as a separate
  `nmap-<version>-data` archive; that archive is gone, and there is nothing to
  download alongside the binary any more. Your own copies still take
  precedence: `--datadir`, `$NMAPDIR` and `~/.nmap` are searched first, in the
  order upstream nmap documents.

### Fixed

- `-sC`, `-sV`, `-O` and the scripting engine work out of the box. In the
  releases before this one the data archive was built empty, so a downloaded
  binary had no NSE and no fingerprint databases at all.
