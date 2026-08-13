{
  description = "nmap as a single self-contained binary";

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
      dnsFallback = true; # resolves hostnames; opt into the Android DNS fallback
      name = "nmap";
      smoke = [ "--version" ];
      smokePattern = "^Nmap version [0-9]+\\.[0-9]+";
      # Build via the unpin-llvm engine so nmap links the same engine-built
      # openssl/zlib/… closure the rest of the catalog does. useEngine kicks in
      # on linux/darwin (single binary → self-fold N=1, no multicall block).
      engine = "unpin-llvm";

      # Two dead store-path strings survive in the static binary and must be
      # scrubbed to keep the 0-external-ref invariant:
      #   - lua-static: liblua's compiled-in LUA_PATH_DEFAULT/LUA_CPATH_DEFAULT
      #     (`…/lua/5.4/?.lua`, `?.so`). nmap runs its own bundled nselib and a
      #     static binary can never dlopen a Lua C module, so these are unused.
      #   - nmap-static: the compiled-in NMAPDATADIR (`…/share/nmap`) pointing
      #     at the base build. nmap looks up its data dir exe-relative first,
      #     and the data ships as the companion sidecar, so this baked fallback
      #     is never reached. (unpinEmbedWrap copies the binary to a fresh store
      #     path, turning that baked self-path into an external cross-ref.)
      # Name-substring patterns, arch-agnostic; darwin has no external lua ref
      # (bundled liblua) so only the nmap-static one matches there.
      removeReferences = [ "lua-static" "nmap-static" ];
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
          # libdnet-stripped's bundled (pre-generated) configure probes for
          # Linux PF_PACKET with a nested function inside main()
          # (`int foo() { return ETH_P_ALL; }`) — a GNU C extension gcc accepts
          # but clang rejects ("function definition is not allowed here"). Under
          # the engine (clang) the probe fails to compile → "no" → configure
          # aborts with "Ethernet support not found for this system". Rewrite it
          # to the valid form the sibling arp probe already uses
          # (`int foo = SIOCGARP;`) so the macro is referenced, not called.
          # No-op on darwin (Linux-only probe; headers absent there anyway).
          fixLibdnetPfPacket = ''
            substituteInPlace libdnet-stripped/configure \
              --replace 'int foo() { return ETH_P_ALL; }' 'int foo = ETH_P_ALL;'
          '';
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
          # real `liblua.a`), so the darwin-only flag never reaches them.
          configureFlags = oa.configureFlags ++ [ "--without-ncat" "--without-nping" ]
            ++ pkgs.lib.optionals isDarwin [
              "--with-liblua=included"
              # Force the bundled sub-libs (libdnet-stripped, libpcap, libssh2,
              # libz — all pulled in via AC_CONFIG_SUBDIRS, so this arg is
              # forwarded to each) to build static-only on darwin. Under the
              # engine the linker is ld64.lld, whose `--version` advertises
              # "compatible with GNU linkers"; libtool's GNU-ld probe trips on
              # that and emits ELF `-Wl,-soname` for shared libs, which ld64
              # rejects ("unknown argument '-soname'"). We only ever link the
              # static archives anyway, so skip the broken shared build. Use the
              # `--enable-shared=no` spelling (not `--disable-shared`, which
              # mkStandaloneFlake's filterEnableStaticOnDarwin strips on darwin
              # to dodge the `--enable-static → LDFLAGS=-static` probe breakage).
              # Linux keeps building the shared libs (ld/lld there accept
              # -soname), so this stays darwin-only.
              "--enable-shared=no"
            ];
          # libdnet-stripped PF_PACKET probe fix (see `fixLibdnetPfPacket`).
          # Applied unconditionally — the whole package rebuilds under the
          # engine, so there is no cached Linux drv hash to preserve.
          postPatch = (oa.postPatch or "") + fixLibdnetPfPacket;
          # nixpkgs' nmap hardcodes `CC=<prefix>gcc` in makeFlags whenever
          # build≠host (always true under pkgsStatic). The unpin-llvm engine is
          # clang-only on *every* target — there is no `<prefix>gcc` — so every
          # sub-make would die with "command not found" (Error 127). Append the
          # generic `<prefix>cc` (the engine clang wrapper, present on all
          # platforms); the later make-command-line assignment wins.
          makeFlags = (oa.makeFlags or [ ])
            ++ [ "CC=${pkgs.pkgsStatic.stdenv.cc.targetPrefix}cc" ];
          postFixup = "";
        }
        # The bundled liblua's Makefile bakes the archive operation into its
        # `AR` variable (`AR= ar rcu`) and writes the rule as `$(AR) $@ …`. On
        # the aarch64-darwin *cross*, nmap's own makeFlags override `AR=<prefix>-ar`
        # (binary only, no operation), so the rule expands to `<prefix>-ar
        # liblua.a …` — no operation letter — and `ar` just dumps its usage and
        # fails. (x86_64-darwin is build==host, leaves AR alone, and builds
        # fine.) Move the operation into the rule so it works both ways.
        # Darwin-only: the Linux/cross builds use the external lua-static and
        # never touch the bundled liblua Makefile.
        // pkgs.lib.optionalAttrs isDarwin {
          # optionalAttrs' postPatch REPLACES (shadows) the base one, so repeat
          # the shared libdnet fix here before the darwin-only liblua AR fix.
          postPatch = (oa.postPatch or "") + fixLibdnetPfPacket + ''
            substituteInPlace liblua/Makefile \
              --replace 'AR= ar rcu' 'AR= ar' \
              --replace '$(AR) $@' '$(AR) rcu $@'
          '';
          # nmap is C++; on darwin the link otherwise imports the dynamic
          # /usr/lib/libc++.1.dylib, which action-build's darwin allow-list
          # rejects (only libSystem + libobjc + declared frameworks are allowed;
          # libc++ *can* be linked statically, so it must be). Same shim
          # chafa/fpcalc/ffmpeg use: expose the static libc++.a as
          # libc++.a/libstdc++.a/libc++abi.a on a -L dir ahead of the system
          # dylib dirs and pass -search_paths_first so ld64 takes the archive
          # instead of its default -search_dylibs_first (which finds the dylib).
          preConfigure = (oa.preConfigure or "") + ''
            mkdir -p "$TMPDIR/cxx-static"
            ln -sf ${pkgs.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libc++.a"
            ln -sf ${pkgs.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libstdc++.a"
            ln -sf ${pkgs.libcxx}/lib/libc++abi.a "$TMPDIR/cxx-static/libc++abi.a"
            export NIX_LDFLAGS="-L$TMPDIR/cxx-static $NIX_LDFLAGS"
            export LDFLAGS="-Wl,-search_paths_first ''${LDFLAGS:-}"
            export LIBS="-lc++abi ''${LIBS:-}"
          '';
        });
    };
}
