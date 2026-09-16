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
      #
      # One thing in the tree must NOT come from the mount. `-oX` writes an
      # `<?xml-stylesheet href=…?>` naming the nmap.xsl that nmap_fetchfile
      # found, and whoever opens the report later is a browser, not nmap: a
      # href into the mount points at a path that exists nowhere on disk, so
      # the report renders as raw XML and the reference is simply a lie.
      # Upstream's own contract covers this — XSLStyleSheet() returning NULL
      # means "skip the element" — so return NULL when the copy found is the
      # embedded one. `--stylesheet` and `--webxml` still work, and a real
      # nmap.xsl reached through --datadir/$NMAPDIR/~/.nmap is still named.
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

            echo "==> drop the xml-stylesheet when its only copy is embedded"
            substituteInPlace NmapOps.cc \
              --replace-fail 'xsl_stylesheet = filename_to_url(tmpxsl);' \
                'if (strncmp(tmpxsl, NMAPDATADIR "/", strlen(NMAPDATADIR "/")) == 0) return NULL; xsl_stylesheet = filename_to_url(tmpxsl);'

            echo "==> put the VFS objects on nmap's link line"
            substituteInPlace Makefile.in \
              --replace-fail '-o $@ $(OBJS) main.o $(LIBS)' \
                '-o $@ $(OBJS) main.o vfs.o miniz.o unpin_zstd.o ${
                   lib.optionalString (!isDarwin) "liblua_vfs.a "}$(LIBS)'
          '';

          # Compiled after configure, not before: the VFS objects must exist by
          # the time anything links, and nothing here may perturb the conftest
          # links (they carry no vfs.o).
          #
          # 32-bit musl needs no special casing any more. It is _REDIR_TIME64,
          # so <sys/stat.h> asm-renames stat/lstat to __stat_time64/
          # __lstat_time64 and the program references THOSE -- which the shared
          # IR rename already maps onto unpinvfs_stat/lstat. The old
          # -DUNPIN_WRAP_TIME64 existed only to compile matching __wrap_ shims,
          # and there is no --wrap left to feed.
          preBuild = (old.preBuild or "") + ''
            echo "==> pre-compile the unpin-vfs objects"
            UNPIN_VFS_DEFS="-DUNPIN_VFS_DIRS -DUNPIN_VFS_SELF -DUNPIN_VFS_NOWRAP -DUNPIN_VFS_ROOT=\"${vfsRoot}/\""
            MINIZ_DEFS="-DMINIZ_USE_ZSTD -DMINIZ_NO_TIME -DMINIZ_NO_ARCHIVE_WRITING_APIS -DMINIZ_NO_ZLIB_APIS -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES"
            $CC -O2 -c vfs.c        $UNPIN_VFS_DEFS $MINIZ_DEFS -o vfs.o
            $CC -O2 -c miniz.c      -D_GNU_SOURCE -w $MINIZ_DEFS -o miniz.o
            $CC -O2 -c unpin_zstd.c -D_GNU_SOURCE -w $MINIZ_DEFS -DUNPIN_ZSTD_VENDORED -o unpin_zstd.o
          '' + lib.optionalString (!isDarwin) ''
            echo "==> stage a rewritable copy of the EXTERNAL liblua"
            cp ${pkgs.pkgsStatic.lua5_4}/lib/liblua.a liblua_vfs.a
            chmod +w liblua_vfs.a
          '';

          # ONE binding, both platforms. -DUNPIN_VFS_NOWRAP names the
          # interceptors unpinvfs_*, and nix-lib's shared IR rename points
          # nmap's own libc file-op references at them. This replaces the old
          # --wrap (Linux) + -DUNPIN_VFS_DLSYM (darwin) split: both of those
          # bind the WHOLE link and so are not mega-safe, and the dlsym half
          # existed only because there was no IR pass within reach.
          #
          # Coverage differs in kind, and getting it wrong is not subtle:
          # --wrap resolved at the FINAL link and so reached every archive, the
          # store's included; the rename reaches exactly what is rewritten
          # below. nmap loads every .nse/.lua through luaL_loadfile, which lives
          # in liblua -- and on Linux liblua is the EXTERNAL lua-static, not the
          # bundled one darwin uses (--with-liblua=included). Leaving it out
          # builds clean and then dies at runtime with "could not load
          # nse_main.lua", so preBuild stages a writable copy ahead of -llua on
          # the link line and the archive loop below rewrites it.
          postBuild = (old.postBuild or "") + ''
            ${ulib.vfsBindFns {
                syms = [ "open" "fopen" "stat" "lstat" "access"
                         "opendir" "readdir" "closedir" ];
              }}
            ${ulib.vfsBindArchiveFns}
            MT=${ulib.unpinToolchain pkgs.stdenv.buildPlatform.system}/bin/llvm
            echo "==> bind the VFS: rename nmap's libc file-op refs in the IR"
            # NOT the VFS objects themselves -- vfs.c calls the genuine libc, so
            # renaming its references would make each shim call itself.
            for o in $(find . -name '*.o'); do
              case "$(basename "$o")" in vfs.o|miniz.o|unpin_zstd.o) continue ;; esac
              isbc "$o" && bcrewrite "$o"
            done
            for a in $(find . -name '*.a'); do
              [ -n "$($MT ar t "$a" 2>/dev/null | head -1)" ] || continue
              bcrewriteArchive "$a"
            done
            echo "==> relink nmap against the rewritten objects"
            rm -f nmap
            make $makeFlags -j''${NIX_BUILD_CORES:-1} nmap
          '';
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
          # The NSE engine has unit tests of its own and they run offline
          # (`--script=unittest`, upstream's own `check-nse`). What they do NOT
          # do is fail: the script hands its result back as text and nmap exits
          # 0 either way, so `make check-nse` is green even when every test
          # fails — hence the explicit match on the output. The other halves of
          # upstream's `make check` are left out: `check-nsock` and `check-nmap`
          # link test programs of their own, and those link lines carry none of
          # the VFS objects, so the shared IR rename leaves them with an
          # undefined `unpinvfs_open`. The smoke gate covers the complementary
          # half — it reads a script out of the embedded tree.
          doCheck = pkgs.pkgsStatic.stdenv.buildPlatform.canExecute
            pkgs.pkgsStatic.stdenv.hostPlatform;
          checkPhase = ''
            runHook preCheck
            __nse=$(./nmap --datadir . --script=unittest --script-args=unittest.run 2>&1)
            printf '%s\n' "$__nse"
            case "$__nse" in
              *"All tests passed"*) ;;
              *) echo "NSE unit tests did not report success" >&2; exit 1 ;;
            esac
            runHook postCheck
          '';
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
