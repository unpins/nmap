{
  description = "Standalone build of nmap";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Native Linux/macOS comes from pkgsStatic.nmap with one dependency fix.
  # nixpkgs' liblinear only builds and installs a shared `liblinear.so.5` — its
  # Makefile has no static-install path — so a static link of `-llinear` finds
  # no `.a` and the whole build fails before nmap is even reached. liblinear's
  # Makefile *does* have a `liblinear.a` target, so swap the broken shared build
  # for the static archive and install that. nmap's configure then links it
  # statically (falling back to its own bundled, identical copy if its link
  # probe is unhappy). liblinear feeds nmap alone, so the fix lives here, inline,
  # rather than in nix-lib. postFixup is cleared because its only content is a
  # darwin `install_name_tool` call rewriting the now-absent liblinear dylib.
  #
  # `optimize.gc = false` turns off the Linux-native --gc-sections overlay for
  # this package. That overlay injects `LDFLAGS=…` on the make command line,
  # which *overrides* (not appends to) the Makefile's own `LDFLAGS`. nmap stuffs
  # all its `-L` search paths into that Makefile variable — the in-tree
  # nsock/nbase static libs and the `--with-liblua` lua dir (lua isn't a
  # buildInput, so it never lands in NIX_LDFLAGS) — so overriding it drops them
  # and the link fails on `-lnsock -lnbase -llua`. The cross targets are
  # unaffected (they carry the lld flags via NIX_CFLAGS_LINK, which appends).
  outputs = { self, unpins-lib }:
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "nmap";
      optimize = { gc = false; };
      # nmap needs its data files at runtime (nmap-services, nmap-os-db,
      # nmap-service-probes, the NSE scripts). They ship as the companion
      # `nmap-<ver>-data.tar.zst`; nmap finds them next to the binary because
      # its data search tries `<exe-dir>/../share/nmap` before the compiled
      # NMAPDATADIR, so no lookup patch is needed.
      package_data = true;
      build = pkgs:
        let
          liblinearStatic = pkgs.pkgsStatic.liblinear.overrideAttrs (_: {
            # Build the objects (via predict/train) then archive them: this
            # liblinear release ships no `liblinear.a` make target, only the
            # shared `lib` target musl-static can't link.
            buildFlags = [ "predict" "train" ];
            postBuild = ''
              $AR rcs liblinear.a linear.o newton.o blas/*.o
            '';
            installPhase = ''
              runHook preInstall
              install -Dm644 liblinear.a $out/lib/liblinear.a
              install -D train $bin/bin/liblinear-train
              install -D predict $bin/bin/liblinear-predict
              install -Dm444 -t $dev/include linear.h
              runHook postInstall
            '';
          });
          isDarwin = pkgs.pkgsStatic.stdenv.hostPlatform.isDarwin;
        in
        (pkgs.pkgsStatic.nmap.override { liblinear = liblinearStatic; }).overrideAttrs (oa: {
          # This package ships the nmap scanner. nmap's tree also builds Ncat
          # and Nping, but the single-binary release publishes only `bin/nmap`,
          # so skip them — leaner build, smaller cross/Windows surface.
          #
          # On darwin only, force nmap's *bundled* liblua (statically linked).
          # nixpkgs' `pkgsStatic.lua` on darwin installs just a shared
          # `liblua.5.4.7.dylib` with no static archive, so the default
          # `--with-liblua=${lua5_4}` links it dynamically and the binary ends
          # up with a /nix/store dylib load command that fails the darwin
          # system-lib allow-list. The included liblua compiles into a
          # `liblua.a` and links statically, leaving only /usr/lib system libs.
          # Linux and the musl crosses keep the external lua-static (it ships a
          # real `liblua.a`), so their drv hashes — already built and verified —
          # stay byte-identical.
          configureFlags = oa.configureFlags ++ [ "--without-ncat" "--without-nping" ]
            ++ pkgs.lib.optionals isDarwin [ "--with-liblua=included" ];
          # nixpkgs' nmap hardcodes `CC=<prefix>gcc` in makeFlags whenever
          # build≠host (always true under pkgsStatic). On Linux `<prefix>gcc`
          # exists, but on darwin the toolchain is clang and there is no
          # `<prefix>gcc`, so every sub-make dies with "command not found"
          # (Error 127). Append the generic `<prefix>cc` (clang on darwin, gcc
          # on Linux); the later make-command-line assignment wins. Darwin-only
          # so the Linux build keeps its cache.
          makeFlags = (oa.makeFlags or [ ])
            ++ pkgs.lib.optionals isDarwin
              [ "CC=${pkgs.pkgsStatic.stdenv.cc.targetPrefix}cc" ];
          postFixup = "";
        }
        # The bundled liblua's Makefile bakes the archive operation into its
        # `AR` variable (`AR= ar rcu`) and writes the rule as `$(AR) $@ …`. On
        # the aarch64-darwin *cross*, nmap's own makeFlags override `AR=<prefix>-ar`
        # (binary only, no operation), so the rule expands to `<prefix>-ar
        # liblua.a …` — no operation letter — and `ar` just dumps its usage and
        # fails. (x86_64-darwin is build==host, leaves AR alone, and builds
        # fine.) Move the operation into the rule so it works both ways. Added
        # *only* on darwin: the stock derivation has no `postPatch`, so setting
        # it even to "" on Linux/crosses would perturb their (already built and
        # verified) drv hashes.
        // pkgs.lib.optionalAttrs isDarwin {
          postPatch = (oa.postPatch or "") + ''
            substituteInPlace liblua/Makefile \
              --replace 'AR= ar rcu' 'AR= ar' \
              --replace '$(AR) $@' '$(AR) rcu $@'
          '';
        });
    };
}
