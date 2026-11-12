#!/usr/bin/env python3
"""Give rustc physical source paths, matching macro file canonicalization."""
import os
import sys


def main():
    if len(sys.argv) < 2:
        raise SystemExit('usage: canonical-rustc.py RUSTC [ARG ...]')
    compiler, *arguments = sys.argv[1:]
    # Askama canonicalizes its config/template files. Its generated relative
    # includes also need a physical Span.local_file(), rather than a path whose
    # parent traversals cross a Cargo registry symlink.
    arguments = [os.path.realpath(argument)
                 if argument.endswith('.rs') and os.path.isfile(argument)
                 else argument for argument in arguments]
    env = os.environ.copy()
    manifest = env.get('CARGO_MANIFEST_DIR')
    if manifest and os.path.isdir(manifest):
        env['CARGO_MANIFEST_DIR'] = os.path.realpath(manifest)
    # exec preserves compiler status and signals, including Cargo's -vV probe.
    os.execvpe(compiler, [compiler, *arguments], env)


if __name__ == '__main__':
    main()
