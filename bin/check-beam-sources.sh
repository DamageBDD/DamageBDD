#!/bin/sh
# Check the conventional apps/*/src layout before a production build.
# This is a basename/output-collision check, not an Erlang parser or a
# replacement for Rebar's effective application/profile configuration.
# Invoke from the repository root. --with-tests also audits apps/*/test.
set -eu

WITH_TESTS=false
case "${1:-}" in
    '') ;;
    --with-tests) WITH_TESTS=true; shift ;;
    *) echo 'usage: sh bin/check-beam-sources.sh [--with-tests]' >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { echo 'unexpected arguments' >&2; exit 2; }
[ -d apps ] || { echo 'Run check-beam-sources.sh from the repository root' >&2; exit 2; }

umask 077
LIST=$(mktemp "${TMPDIR:-/tmp}/damage-beam-sources.XXXXXX")
trap 'rm -f "$LIST"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

RESULT=0
for APP in apps/*; do
    [ -d "$APP/src" ] || continue
    # Follow source-directory links too: aliases can discover the same
    # output basename twice. find failures (including loops) fail closed.
    find -L "$APP/src" -type f -name '*.erl' -print > "$LIST"
    if [ "$WITH_TESTS" = true ] && [ -d "$APP/test" ]; then
        find -L "$APP/test" -type f -name '*.erl' -print >> "$LIST"
    fi
    # Repository source filenames must not contain embedded newlines.
    # Spaces are supported. Different applications have separate ebin dirs.
    if ! awk -v app="$APP" '
        {
            n = split($0, parts, "/")
            name = parts[n]
            paths[name] = paths[name] "\n    " $0
            count[name]++
        }
        END {
            bad = 0
            for (name in count) {
                if (count[name] > 1) {
                    printf "Duplicate Erlang source basename in %s: %s%s\n", \
                        app, name, paths[name]
                    bad = 1
                }
            }
            exit bad
        }
    ' "$LIST" >&2; then
        RESULT=1
    fi
done

if [ "$RESULT" -ne 0 ]; then
    echo 'Resolve these source collisions before compiling; do not retry or delete files while a compiler is running.' >&2
fi
exit "$RESULT"
