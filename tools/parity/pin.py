"""Where the upstream pin lives, and how to tell when it has moved.

The pin is recorded in three places on purpose, and they have to agree:

  - the `AutoEq` gitlink in this repo's index, which is the machine-readable
    one and the only one `git` itself enforces,
  - `meta.autoeq_commit` in `fixtures/manifest.json`, recorded by whatever
    checkout produced the fixtures,
  - the prose in `CLAUDE.md`, for a reader.

A checkout whose HEAD has drifted from the gitlink regenerates fixtures
against an upstream nobody asked for, and the result looks like a port bug.
These helpers exist so both scripts can say so out loud instead.
"""
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
AUTOEQ = os.path.join(REPO, 'AutoEq')


def _git(*args):
    try:
        return subprocess.check_output(
            args, stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return None


def head_commit():
    """The commit the submodule is actually checked out at, or None when it
    is not checked out. Everything but fixture regeneration runs without it."""
    if not os.path.isdir(os.path.join(AUTOEQ, 'autoeq')):
        return None
    return _git('git', '-C', AUTOEQ, 'rev-parse', 'HEAD')


def gitlink_commit():
    """The commit this repo pins the submodule to. Read from the index rather
    than from HEAD, so a pin bump staged but not yet committed still counts.
    None when the superproject is not a git checkout, as in a source tarball."""
    out = _git('git', '-C', REPO, 'ls-files', '-s', 'AutoEq')
    if not out:
        return None
    parts = out.split()
    return parts[1] if len(parts) >= 2 else None


def check(recorded=None):
    """Return a list of warning lines. Empty means everything agrees, or that
    there is nothing checked out to disagree."""
    head = head_commit()
    if head is None:
        return []
    out = []
    link = gitlink_commit()
    if link and link != head:
        out.append(
            'AutoEq/ is at {}, the submodule is pinned to {}. Run '
            '`git submodule update --init AutoEq` before regenerating.'
            .format(head[:12], link[:12]))
    if recorded and recorded != head:
        out.append(
            'AutoEq/ is at {}, the fixtures were built at {}. Regenerating '
            'now would move the contract.'.format(head[:12], recorded[:12]))
    return out
