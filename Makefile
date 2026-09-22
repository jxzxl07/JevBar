# JevBar.
#
# `make` rebuilds, signs, installs to ~/Applications and restarts it. That is
# the whole loop: a native app has no hot reload, so a code change means a new
# binary, but nothing about permissions has to be done again — the signing
# identity and the install path are both stable, which is what lets an
# Accessibility grant survive a rebuild.

.PHONY: all test check run clean

all:
	@./package.sh

test:
	@swift test

# Everything a change has to pass before it is worth installing.
check:
	@swift build 2>&1 | grep -E "error|warning:" || true
	@swift test

# Rebuild and restart without taking focus, for when you are mid-form.
run:
	@JEVBAR_NO_LAUNCH=1 ./package.sh

clean:
	@rm -rf .build dist
