# Main Rules
# ==========
#
# make [all]: does a sandboxed install of trellys-core.
#             Assumes you have Cabal installed, and that the default
#             Cabal install dir is on your path (~/.cabal/bin for
#             default "per-user" setup).  A trellys binary will be
#             installed in ./cabal-dev/bin/trellys, and symlinked
#             to test/trellys (the only place you're expected to run
#             `trellys`).
#
# make test:  runs all tests in ./test.
#
# make sandbox-trellys:
#             does a sandboxed install or trellys-core.  Quicker than
#             `make all`. Assumes you ran `make all` previously.
# make install: does a `cabal install` of trellys-core.

.PHONY: all sandbox-install sandbox-uninstall sandbox-trellys \
	    install uninstall clean test

all: sandbox-install

sandbox-install: sandbox-trellys

sandbox-uninstall:
	-rm -rf cabal-dev

sandbox-trellys: cabal-dev
	cabal-dev install ./src
	ln -fs `pwd`/cabal-dev/bin/trellys test

# You need to have the cabal install dir on your path (by default
# ~/.cabal/bin) so that `cabal-dev` command is found.
cabal-dev:
	cabal install cabal-dev

install:
#	cabal install
	cd src && cabal install

uninstall:
	-ghc-pkg unregister `ghc-pkg list | grep trellys`
	@echo
	@echo You need to manually delete any trellys binaries on your path.
	@echo You can find them with \`which trellys\`

clean:
	-rm -rf src/dist

test:
	cd test && make

etags:
	find ./ -name .svn -prune -o -name '*.hs' -print | xargs hasktags --etags
