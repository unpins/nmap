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
    let
      ulib = unpins-lib.lib;

      # Mount point of the embedded data tree. nmap composes every data path as
      # "<datadir>/<file>", so this is exactly the value NMAPDATADIR takes; the
      # VFS root itself is this plus the trailing slash.
      vfsRoot = "/__unpins_nmapdata__";

      # Carry nmap's data tree (nse_main.lua, the NSE scripts and nselib,
      # nmap-services, nmap-os-db, nmap-service-probes, nmap-mac-prefixes)
      # INSIDE the binary, served by the shared unpin-vfs core from the ZIP the
      # build appends at EOF. Without it nmap silently loses NSE, -sV, -O and
      # service names and degrades to a raw port scanner: `unpinEmbedWrap`
      # rebuilds $out from scratch and keeps only bin/ and share/man, so any
      # data tree left on disk is discarded by construction.
      #
      # Nothing in nmap's lookup path needs patching, and that is why this is
      # cheap. Every read of the tree goes through plain libc, which is exactly
      # the call set the VFS fronts: `file_is_readable` is stat+access
      # (nbase/nbase_misc.c), the databases are fopen (services.cc, protocols.cc,
      # osscan.cc, service_scan.cc, MACLookup.cc), NSE lists directories with
      # opendir/readdir (nse_fs.cc) and loads .nse/.lua through luaL_loadfile,
      # itself fopen. The single std::ifstream in the tree (nmap_dns.cc) reads
      # /etc/hosts -- a real system file, outside the mount.
      #
      # Reaching the mount is one build variable: NMAPDATADIR is
      # `-DNMAPDATADIR=\"$(nmapdatadir)\"` in Makefile.in. Pointing it at the
      # mount leaves nmap's documented search order untouched -- --datadir,
      # $NMAPDIR, ~/.nmap, the exe dir, <exe>/../share/nmap, and only then the
      # embedded copy as the last resort. A user's own data files still win,
      # exactly as upstream documents.
      injectVfs = pkgs: drv: drv.overrideAttrs (old:
        let
          lib = pkgs.lib;
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
        in
        {
          postPatch = (old.postPatch or "") + ''
            echo "==> inject unpin-vfs core (vfs.c + miniz.c)"
            cp ${ulib.vfsCore}/*.c ${ulib.vfsCore}/*.h .

            echo "==> point the compiled-in NMAPDATADIR at the VFS mount"
            substituteInPlace Makefile.in \
              --replace-fail '-DNMAPDATADIR=\"$(nmapdatadir)\"' '-DNMAPDATADIR=\"${vfsRoot}\"'

            echo "==> put the VFS objects on nmap's link line"
            substituteInPlace Makefile.in \
              --replace-fail '-o $@ $(OBJS) main.o $(LIBS)' \
                '-o $@ $(OBJS) main.o vfs.o miniz.o unpin_zstd.o $(LIBS)'
          '';

          # After configure, for the same reason zsh does it there: the `--wrap`
          # flags must not reach the conftest links, which have no vfs.o and
          # would fail on an undefined __wrap_fopen -- silently mis-detecting
          # features rather than erroring.
          #
          # -DUNPIN_WRAP_TIME64 (32-bit musl) is spliced into UNPIN_VFS_DEFS
          # rather than appended by the 32-bit block below, which runs after
          # that compile and so would never reach vfs.c. Getting it wrong is not
          # a warning: the --wrap flag then asks the linker for a shim nothing
          # compiled, and i686/armv7l die on `undefined symbol:
          # __wrap___stat_time64`. This note lives at Nix level on purpose -- a
          # comment inside the shell string below is build-script text, so it
          # would re-hash every target instead of the two it describes.
          preBuild = (old.preBuild or "") + ''
            echo "==> pre-compile the unpin-vfs objects"
            # -DUNPIN_VFS_DLSYM (darwin): the binding where vfs.c DEFINES the
            # libc entry points and reaches the real ones through
            # dlsym(RTLD_NEXT). Bare __APPLE__ would instead select the rename
            # binding, which needs an IR-rewrite pass this build has no
            # equivalent of. It is linker-global, which is fine here: nmap emits
            # no multicall module (no `multicall` block), so nothing folds this
            # binary together with another.
            UNPIN_VFS_DEFS="-DUNPIN_VFS_DIRS -DUNPIN_VFS_SELF -DUNPIN_VFS_ROOT=\"${vfsRoot}/\"${lib.optionalString isDarwin " -DUNPIN_VFS_DLSYM"}${lib.optionalString (!isDarwin && pkgs.stdenv.hostPlatform.is32bit) " -DUNPIN_WRAP_TIME64"}"
            MINIZ_DEFS="-DMINIZ_USE_ZSTD -DMINIZ_NO_TIME -DMINIZ_NO_ARCHIVE_WRITING_APIS -DMINIZ_NO_ZLIB_APIS -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES"
            $CC -O2 -c vfs.c        $UNPIN_VFS_DEFS $MINIZ_DEFS -o vfs.o
            $CC -O2 -c miniz.c      -D_GNU_SOURCE -w $MINIZ_DEFS -o miniz.o
            $CC -O2 -c unpin_zstd.c -D_GNU_SOURCE -w $MINIZ_DEFS -DUNPIN_ZSTD_VENDORED -o unpin_zstd.o
          '' + lib.optionalString (!isDarwin) ''
            echo "==> Linux: route nmap's libc file calls through the VFS shims"
            # Via NIX_LDFLAGS, not the makefile: nmap stuffs its own -L paths
            # into LDFLAGS and the cc-wrapper appends these to the final link
            # regardless. `--wrap` resolves at final link, so it reaches the
            # members of liblua.a/libnbase.a too -- which matters, since
            # luaL_loadfile (all of NSE) lives in liblua.
            export NIX_LDFLAGS="$NIX_LDFLAGS --wrap=open --wrap=stat --wrap=lstat --wrap=access --wrap=opendir --wrap=readdir --wrap=closedir --wrap=fopen"
          '' + lib.optionalString (!isDarwin && pkgs.stdenv.hostPlatform.is32bit) ''
            echo "==> 32-bit musl is _REDIR_TIME64: wrap the __stat_time64 aliases too"
            # Pairs with -DUNPIN_WRAP_TIME64 above, which compiles the shims.
            export NIX_LDFLAGS="$NIX_LDFLAGS --wrap=__stat_time64 --wrap=__lstat_time64"
          '';

          # macOS needs no extra link step: under -DUNPIN_VFS_DLSYM vfs.c
          # DEFINES open/stat/..., and a definition in a linked object shadows
          # the libSystem import for every reference.
        });
    in
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      dnsFallback = true; # resolves hostnames; opt into the Android DNS fallback
      name = "nmap";
      # `--version` was a tautology: it never opens the data tree, so it stayed
      # green through the whole window in which the shipped binary had no NSE
      # at all. `--script-help` is the cheapest call that actually exercises
      # the embedded tree end to end -- it loads nse_main.lua, walks scripts/
      # and pulls nselib modules, and fails if any of that is unreachable.
      # The pattern deliberately does not mention the binary name: the smoke
      # job runs the artifact under a renamed path on some targets.
      smoke = [ "--script-help=http-git" ];
      smokePattern = "^Categories: ";
      # Build via the unpin-llvm engine so nmap links the same engine-built
      # openssl/zlib/… closure the rest of the catalog does. No `multicall`
      # block: nmap ships one binary and nothing needs its bitcode module, so
      # `wantModule` (nix-lib/flake.nix:5098 — `multicall != null && …`) stays
      # false and no fold pass runs at all. That is NOT a "self-fold N=1", which
      # is what this comment used to claim.
      engine = "unpin-llvm";

      # One dead store-path string survives in the static binary and must be
      # scrubbed to keep the 0-external-ref invariant: liblua's compiled-in
      # LUA_PATH_DEFAULT/LUA_CPATH_DEFAULT (`…/lua/5.4/?.lua`, `?.so`). nmap
      # runs its own bundled nselib and a static binary can never dlopen a Lua
      # C module, so these are unused. Name-substring pattern, arch-agnostic.
      #
      # `nmap-static` used to be in this list too, for the compiled-in
      # NMAPDATADIR (`…/share/nmap`) pointing at the base build — a baked
      # self-path that unpinEmbedWrap turns into an external cross-ref when it
      # copies the binary to a fresh store path. NMAPDATADIR is the VFS mount
      # now, so that string is not in the binary at all; measured with the
      # entry dropped, the artifact still carries zero references.
      removeReferences = [ "lua-static" ];
      optimize = { gc = false; };
      # The data tree rides the binary (see `injectVfs`). It used to ship as
      # the companion `nmap-<ver>-data.tar.zst` via `package_data`, which is
      # gone: that option publishes `result/share`, and `unpinEmbedWrap` keeps
      # only `share/man` there, so since the move to the engine the tarball was
      # empty of everything that matters and the released binary would have had
      # no NSE at all.
      runtimeEmbed = {
        native = pkgs: base: {
          man = true;
          # Stage the CONTENTS of share/nmap at the ZIP root: that root is what
          # NMAPDATADIR names, and nmap asks for tree-relative paths
          # ("nse_main.lua", "scripts/http-git.nse", "nselib/http.lua").
          runtimeStage = ''
            cp -a ${base}/share/nmap/. "$__unpin_stage/"
            chmod -R u+w "$__unpin_stage"
          '';
        };
      };
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
        injectVfs pkgs
        ((pkgs.pkgsStatic.nmap.override { liblinear = liblinearStatic; }).overrideAttrs (oa: {
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
        }));
    };
}
