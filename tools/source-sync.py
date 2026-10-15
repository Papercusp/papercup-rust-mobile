#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded, cache-preserving transfer between two mobile checkouts.

The destination is an existing checkout owned by the native runner.  Only
paths in the source Git inventory are copied and only stale *tracked* paths
are removed.  Ignored build caches therefore never enter the transfer or get
deleted as a side effect of a source refresh.
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('mobile_ci', Path(__file__).with_name('android-ci.py'))
mobile_ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mobile_ci)


class SyncRefused(ValueError):
    """The source, destination, or admission budget is unsafe."""


class Budget:
    def __init__(self, seconds):
        if seconds <= 0:
            raise SyncRefused('time budget must be positive')
        self.deadline = time.monotonic() + seconds

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise SyncRefused('source sync time budget exhausted')
        return remaining


def _git(root: Path, *args: str, budget=None) -> bytes:
    process = subprocess.Popen(['git', '-c', 'core.hooksPath=/dev/null', *args], cwd=root,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        data, _ = process.communicate(timeout=min(60, budget.remaining()) if budget else 60)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        raise
    if process.returncode:
        raise SyncRefused(f"git {' '.join(args)} failed: " + data.decode(errors='replace').strip())
    return data


def _status(root: Path, budget=None) -> list[str]:
    return _git(root, 'status', '--porcelain=v1', '--untracked-files=all', budget=budget).decode().splitlines()


def _assert_source_safe(root: Path, budget=None) -> None:
    if _status(root, budget):
        raise SyncRefused('source requires exact clean committed source')


def _assert_destination_safe(root: Path, budget=None) -> None:
    # Existing ignored caches are explicitly allowed. Any visible untracked
    # collision is refused because deleting or overwriting it is unsafe.
    rows = _status(root, budget)
    collisions = [line for line in rows if line.startswith('?? ')]
    unsafe = [line for line in rows if not line.startswith('?? ')]
    if collisions:
        raise SyncRefused("destination has untracked paths: " + ", ".join(collisions[:8]))
    if unsafe:
        raise SyncRefused("destination checkout has modified/staged/conflicted paths: " + ", ".join(unsafe[:8]))


def inventory(root: Path, budget=None) -> tuple[set[str], set[str]]:
    """Read file paths and initialized Gitlinks from the index, never caches."""
    paths, modules = set(), set()
    for entry in _git(root, 'ls-files', '--stage', '-z', budget=budget).split(b'\0'):
        if not entry:
            continue
        metadata, raw = entry.split(b'\t', 1)
        mode, _, stage = metadata.split()
        relative = os.fsdecode(raw)
        if (stage != b'0' or Path(relative).is_absolute() or '..' in Path(relative).parts
                or '.git' in Path(relative).parts):
            raise SyncRefused('invalid/conflicted inventory path')
        if mode == b'160000':
            modules.add(relative)
        elif mode in (b'100644', b'100755', b'120000'):
            paths.add(relative)
        else:
            raise SyncRefused('unsupported Git mode: ' + mode.decode())
    return paths, modules


def _size(root: Path, paths: set[str]) -> int:
    total = 0
    for relative in paths:
        path = root / relative
        if path.is_symlink():
            total += len(os.readlink(path).encode())
        else:
            total += path.stat().st_size
    return total


def _safe_path(root, relative, tracked):
    path = root / relative
    for parent in path.parents:
        if parent == root:
            break
        if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
            raise SyncRefused('non-directory/symlink inventory ancestor: ' + relative)
    if path.exists() or path.is_symlink():
        if relative not in tracked:
            raise SyncRefused('destination untracked/ignored collision: ' + relative)
        if path.is_dir() and not path.is_symlink():
            raise SyncRefused('destination directory collides with source file: ' + relative)


def _plans(source, destination, budget):
    budget.remaining()
    for root in (source, destination):
        actual = Path(os.fsdecode(_git(root, 'rev-parse', '--show-toplevel', budget=budget)).strip()).resolve()
        if actual != root:
            raise SyncRefused('expected exact repository root')
    _assert_source_safe(source, budget)
    _assert_destination_safe(destination, budget)
    paths, modules = inventory(source, budget)
    tracked, old_modules = inventory(destination, budget)
    if modules != old_modules:
        raise SyncRefused('submodule topology changed; prepare initialized checkouts first')
    for relative in paths:
        budget.remaining()
        path = source / relative
        if not path.is_file() and not path.is_symlink():
            raise SyncRefused('missing source path: ' + relative)
        if path.is_symlink() and not path.resolve().is_relative_to(source):
            raise SyncRefused('source symlink escapes checkout: ' + relative)
        _safe_path(destination, relative, tracked)
    for relative in tracked - paths:
        _safe_path(destination, relative, tracked)
    plan = {'source': source, 'destination': destination, 'paths': paths,
            'stale': tracked - paths, 'commit': os.fsdecode(_git(source, 'rev-parse', 'HEAD', budget=budget)).strip()}
    result = [plan]
    for relative in sorted(modules):
        child = destination / relative
        if child.is_symlink() or not (child / '.git').exists():
            raise SyncRefused('destination submodule must already be initialized: ' + relative)
        result.extend(_plans(source / relative, child, budget))
    return result


def preflight(source: Path, destination: Path, *, max_bytes: int, max_files: int, budget=None) -> dict:
    source = source.resolve(strict=True)
    destination = destination.resolve(strict=True)
    if source.is_relative_to(destination) or destination.is_relative_to(source):
        raise SyncRefused('source and destination must be disjoint')
    if not (source / ".git").exists() or not (destination / ".git").exists():
        raise SyncRefused("source and destination must be Git checkouts")
    if max_bytes <= 0 or max_files <= 0:
        raise SyncRefused('byte/file budgets must be positive')
    budget = budget or Budget(600)
    plans = _plans(source, destination, budget)
    file_count = sum(len(plan['paths']) for plan in plans)
    bytes_to_copy = sum(_size(plan['source'], plan['paths']) for plan in plans)
    if file_count > max_files:
        raise SyncRefused(f'source inventory has {file_count} files; budget is {max_files}')
    if bytes_to_copy > max_bytes:
        raise SyncRefused(f"source transfer is {bytes_to_copy} bytes; budget is {max_bytes}")
    # Android CI includes this ignored private input in source identity. Never
    # copy a secret as a side effect; reject differing configurations up front.
    for plan in plans:
        configs = [root / 'android/app/google-services.json'
                   for root in (plan['source'], plan['destination'])]
        config_values = [p.read_bytes() if p.is_file() else None for p in configs]
        if config_values[0] != config_values[1]:
            raise SyncRefused('private Firebase configuration differs; source transfer refused')
    identity = mobile_ci.source_identity(source)
    if identity['dirty']:
        raise SyncRefused('source/submodules require clean matching commits')
    return {
        "source": str(source), "destination": str(destination),
        'files': file_count, 'bytes': bytes_to_copy, 'identity': identity,
        'staleTracked': sum(len(plan['stale']) for plan in plans), 'plans': plans,
    }


def _remove_tracked(destination: Path, relative: str) -> None:
    path = destination / relative
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        raise SyncRefused(f"stale tracked path is not a regular file: {relative}")


def sync(source: Path, destination: Path, *, max_bytes: int, max_files: int,
         dry_run: bool = False, timeout=600) -> dict:
    budget = Budget(timeout)
    source, destination = source.resolve(strict=True), destination.resolve(strict=True)
    with ExitStack() as locks, tempfile.TemporaryDirectory(prefix='papercup-source-sync-') as staging:
        # The inode lives in the destination Git directory and is never copied.
        # Native iPhone execution holds the shared side for its complete run.
        locks.enter_context(mobile_ci.source_custody(source))
        locks.enter_context(mobile_ci.source_custody(destination, exclusive=True))
        plan = preflight(source, destination, max_bytes=max_bytes, max_files=max_files, budget=budget)
        for entry in plan['plans'][1:]:
            locks.enter_context(mobile_ci.source_custody(entry['source']))
            locks.enter_context(mobile_ci.source_custody(entry['destination'], exclusive=True))
        bundles = []
        total_bytes = plan['bytes']
        for i, entry in enumerate(plan['plans']):
            bundle = Path(staging) / (str(i) + '.bundle')
            _git(entry['source'], 'bundle', 'create', str(bundle), 'HEAD', budget=budget)
            total_bytes += bundle.stat().st_size
            if total_bytes > max_bytes:
                raise SyncRefused(f'source plus Git metadata is {total_bytes} bytes; budget is {max_bytes}')
            bundles.append(bundle)
        report = {key: value for key, value in plan.items() if key != 'plans'}
        report['bytesIncludingGit'] = total_bytes
        if dry_run:
            return report
        if mobile_ci.source_identity(source) != plan['identity']:
            raise SyncRefused('source changed during preflight')
        for entry, bundle in zip(plan['plans'], bundles):
            destination = entry['destination']
            for relative in sorted(entry['stale']):
                budget.remaining()
                _remove_tracked(destination, relative)
            for relative in sorted(entry['paths']):
                budget.remaining()
                src, target = entry['source'] / relative, destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                if src.is_symlink():
                    if target.exists() or target.is_symlink():
                        target.unlink()
                    target.symlink_to(os.readlink(src))
                else:
                    # A unique tempfile cannot overwrite an ignored neighbour.
                    fd, name = tempfile.mkstemp(prefix='.papercup-sync-', dir=target.parent)
                    try:
                        with os.fdopen(fd, 'wb') as out, src.open('rb') as inp:
                            while chunk := inp.read(1024 * 1024):
                                budget.remaining()
                                out.write(chunk)
                        shutil.copystat(src, name)
                        os.replace(name, target)
                    finally:
                        Path(name).unlink(missing_ok=True)
            # Import only objects, then update the index/HEAD without any
            # checkout/reset operation that could delete ignored build caches.
            _git(destination, 'fetch', '--no-tags', '--no-write-fetch-head', str(bundle), 'HEAD', budget=budget)
            _git(destination, 'read-tree', entry['commit'], budget=budget)
            _git(destination, 'update-ref', 'HEAD', entry['commit'], budget=budget)
        if (mobile_ci.source_identity(source) != plan['identity']
                or mobile_ci.source_identity(Path(plan['destination'])) != plan['identity']):
            raise SyncRefused('exact native source identity mismatch after transfer; do not run acceptance')
        report['verifiedIdentity'] = plan['identity']
        return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--max-bytes", type=int, default=5 * 1024**3)
    parser.add_argument("--max-files", type=int, default=250_000)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument('--timeout', type=float, default=600,
                        help='Total transfer budget in seconds, including Git subprocesses')
    args = parser.parse_args(argv)
    try:
        mobile_ci.status(json.dumps(sync(args.source, args.destination, max_bytes=args.max_bytes,
                                        max_files=args.max_files, dry_run=args.dry_run,
                                        timeout=args.timeout), sort_keys=True))
        return 0
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"source sync refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
