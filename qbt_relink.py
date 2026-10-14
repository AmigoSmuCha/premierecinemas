#!/usr/bin/env python3
# =============================================================================
# qbt_relink.py
#
# Fixes qBittorrent torrents whose files were moved/renamed outside of
# qBittorrent, and can tuck all seeding torrents into a hidden folder.
# Everything goes through the qBittorrent Web API:
#   - torrents_files         (read the expected file list for each torrent)
#   - torrents_set_location  (change the torrent's save path; qBittorrent
#                             itself moves any files that exist)
#   - torrents_rename_file   (tell qBittorrent the new relative filename)
#   - torrents_file_priority (mark missing/junk files "do not download")
#   - torrents_recheck       (verify the reassigned files hash-match)
#
# HOW MATCHING WORKS
#   Each expected file is checked at its expected path. If missing, the
#   script looks under --movies-dir for a file with the EXACT SAME BYTE SIZE.
#   - One candidate: use it.
#   - Several candidates: hash them (sha256). Byte-identical duplicates are
#     harmless, so one is picked. Different content = real ambiguity.
#   - No candidate: unresolved.
#
#   Only VIDEO files are "essential". If a video can't be matched (or is
#   truly ambiguous), the whole torrent is skipped for manual review.
#   Everything else (subtitles, cover art, .nfo, .txt, .url ...) that can't
#   be matched is marked "do not download" so qBittorrent stops expecting
#   it. That is what lets you delete subtitles/extras and still seed the
#   rest of the torrent.
#
#   Files already set to "do not download" and absent from disk are treated
#   as intentionally gone, so re-running the script is safe (idempotent).
#
#   Torrents where every wanted file is exactly where qBittorrent expects it
#   are left alone, unless --hide is used.
#
# --hide
#   Moves every healthy torrent's save path to <movies-dir>/.torrents
#   (hidden from normal directory listings). qBittorrent performs the move
#   itself, so seeding continues. NOTE: all of a torrent's files move, not
#   only the video; any subtitle still listed in the torrent goes with it.
#   Torrents that needed fixing in this run are skipped by --hide; run again
#   after their recheck finishes.
#
# SAFETY
#   - Dry-run by default. Nothing changes until you pass --apply.
#   - After fixes, a hash recheck runs, so a wrong size-coincidence match
#     shows up as an errored/incomplete torrent instead of silently working.
#   - Torrents stay PAUSED unless you pass --resume-after.
#   - The script never deletes, renames or moves files itself. File moves
#     only ever happen inside qBittorrent, via set_location / rename_file.
#
# REQUIREMENTS
#   pip install qbittorrent-api --break-system-packages
#   qBittorrent Web UI enabled (Tools/Options -> Web UI)
#
# USAGE
#   python3 qbt_relink.py --username admin                  # dry run
#   python3 qbt_relink.py --username admin --apply          # fix
#   python3 qbt_relink.py --username admin --hide           # dry run of hiding
#   python3 qbt_relink.py --username admin --hide --apply --resume-after
#
#   Password: --password, env var QBT_PASSWORD, or a hidden prompt.
# =============================================================================

import argparse
import getpass
import hashlib
import os
import sys
import time
from collections import defaultdict

try:
    import qbittorrentapi
except ImportError:
    print("Missing dependency. Install it with:")
    print("  pip install qbittorrent-api --break-system-packages")
    sys.exit(1)


# Only these block a torrent when missing/ambiguous. Everything else is
# skippable (set to "do not download").
ESSENTIAL_EXTS = {
    "mp4", "mkv", "avi", "mov", "m4v", "wmv", "flv", "webm", "ts", "m2ts", "mpeg", "mpg",
}


def human_size(n):
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if abs(n) < 1024:
            return f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}PB"


def file_ext(name):
    base = name.rsplit("/", 1)[-1]
    if "." not in base:
        return ""
    return base.rsplit(".", 1)[-1].lower()


def sha256_of(path, chunk_size=1024 * 1024):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(chunk_size), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


def wait_for_checking(client, hashes, timeout=1800):
    """Block until none of `hashes` are in a 'checking' state."""
    time.sleep(2)  # give qBittorrent a moment to start the recheck
    deadline = time.time() + timeout
    while time.time() < deadline:
        infos = client.torrents_info(torrent_hashes=hashes)
        if not any(i.state.startswith("checking") for i in infos):
            return True
        time.sleep(3)
    return False


def build_size_index(root, exclude_paths):
    """Map file size -> list of absolute paths under `root`, skipping files
    already correctly claimed by a healthy torrent."""
    index = defaultdict(list)
    for dirpath, _dirnames, filenames in os.walk(root):
        for fname in filenames:
            fpath = os.path.join(dirpath, fname)
            if fpath in exclude_paths:
                continue
            try:
                size = os.path.getsize(fpath)
            except OSError:
                continue
            index[size].append(fpath)
    return index


def resolve_candidates(candidates):
    """Collapse 2+ same-size candidates via content hash. Returns
    (chosen_path_or_None, hash_groups)."""
    groups = defaultdict(list)
    for c in sorted(candidates):
        groups[sha256_of(c)].append(c)
    if len(groups) == 1:
        return next(iter(groups.values()))[0], groups
    return None, groups


def main():
    parser = argparse.ArgumentParser(
        description="Relink qBittorrent torrents to moved/renamed files and optionally hide them."
    )
    parser.add_argument("--host", default="localhost", help="Web UI host (default: localhost)")
    parser.add_argument("--port", default=8080, type=int, help="Web UI port (default: 8080)")
    parser.add_argument("--username", default="admin", help="Web UI username (default: admin)")
    parser.add_argument("--password", default=None, help="Web UI password (omit to be prompted)")
    parser.add_argument(
        "--movies-dir",
        default=os.path.expanduser("~/Movies"),
        help="Root folder for relinking (default: ~/Movies)",
    )
    parser.add_argument("--apply", action="store_true", help="Make changes. Without it, nothing is modified.")
    parser.add_argument("--resume-after", action="store_true", help="Resume processed torrents when done.")
    parser.add_argument(
        "--hide",
        action="store_true",
        help="Move all healthy torrents into <movies-dir>/.torrents (done by qBittorrent).",
    )
    args = parser.parse_args()

    movies_dir = os.path.abspath(os.path.expanduser(args.movies_dir))
    if not os.path.isdir(movies_dir):
        print(f"ERROR: movies dir not found: {movies_dir}")
        sys.exit(1)
    hide_dir = os.path.join(movies_dir, ".torrents")

    password = args.password or os.environ.get("QBT_PASSWORD")
    if not password:
        password = getpass.getpass(f"qBittorrent Web UI password for '{args.username}': ")

    client = qbittorrentapi.Client(
        host=args.host, port=args.port, username=args.username, password=password
    )
    try:
        client.auth_log_in()
    except qbittorrentapi.LoginFailed as e:
        print(f"ERROR: login failed: {e}")
        sys.exit(1)
    except qbittorrentapi.APIConnectionError as e:
        print(f"ERROR: could not connect to {args.host}:{args.port} -- is the Web UI enabled? ({e})")
        sys.exit(1)

    print(f"=== qBittorrent relink ({'APPLY' if args.apply else 'DRY-RUN'}) ===")
    print(f"Movies dir : {movies_dir}")
    if args.hide:
        print(f"Hide into  : {hide_dir}")
    print(f"Web UI     : {args.host}:{args.port}\n")

    torrents = client.torrents_info()
    print(f"Found {len(torrents)} torrents.\n")

    # ── Pass 1: which torrents have wanted files missing? ───────────────────
    torrent_files = {}
    already_ok_paths = set()
    broken = {}

    for t in torrents:
        try:
            files = client.torrents_files(torrent_hash=t.hash)
        except Exception as e:
            print(f"  [WARN] {t.name}: could not read file list ({e}), skipping")
            continue
        torrent_files[t.hash] = files

        has_missing = False
        for f in files:
            expected_abs = os.path.join(t.save_path, f.name)
            if os.path.isfile(expected_abs):
                already_ok_paths.add(os.path.abspath(expected_abs))
            elif f.priority == 0:
                continue  # intentionally not downloaded / deleted
            else:
                has_missing = True
        if has_missing:
            broken[t.hash] = True

    healthy_count = len(torrents) - len(broken)
    print(f"Healthy (nothing missing): {healthy_count}")
    print(f"Torrents with wanted files missing: {len(broken)}\n")

    # ── Pass 2: fix broken torrents ─────────────────────────────────────────
    size_index = build_size_index(movies_dir, already_ok_paths) if broken else {}

    fixed = 0
    skipped_torrents = 0
    junk_deprioritized = 0
    to_recheck = []

    for t in torrents:
        if t.hash not in broken:
            continue

        files = torrent_files[t.hash]
        plan = {}
        skip_priority = []
        problem = False

        for f in files:
            expected_abs = os.path.join(t.save_path, f.name)
            if os.path.isfile(expected_abs):
                plan[f.name] = os.path.abspath(expected_abs)
                continue
            if f.priority == 0:
                continue

            essential = file_ext(f.name) in ESSENTIAL_EXTS
            candidates = size_index.get(f.size, [])

            if len(candidates) == 1:
                plan[f.name] = candidates[0]
                size_index[f.size] = []
                continue

            if len(candidates) > 1:
                resolved, groups = resolve_candidates(candidates)
                if resolved is not None:
                    plan[f.name] = resolved
                    size_index[f.size] = [c for c in candidates if c != resolved]
                    continue
                if essential:
                    print(f"  [AMBIGUOUS] {t.name}: '{f.name}' ({human_size(f.size)}) "
                          f"matches {len(candidates)} files with different content:")
                    for digest, paths in groups.items():
                        for p in paths:
                            print(f"      - {p}  (sha256:{(digest or 'unreadable')[:12]}...)")
                    print("    Skipping torrent -- resolve manually.")
                    problem = True
                    break
                print(f"  [SKIP] {t.name}: '{f.name}' ({human_size(f.size)}) -- ambiguous, "
                      f"non-video: will mark do-not-download.")
                skip_priority.append(f.index)
                continue

            if essential:
                print(f"  [NO MATCH] {t.name}: '{f.name}' ({human_size(f.size)}) -- "
                      f"no file of matching size found. Skipping torrent.")
                problem = True
                break
            print(f"  [SKIP] {t.name}: '{f.name}' ({human_size(f.size)}) -- not found, "
                  f"non-video: will mark do-not-download.")
            skip_priority.append(f.index)

        if problem:
            skipped_torrents += 1
            print()
            continue

        renames = []
        for old_name, new_abs in plan.items():
            new_rel = os.path.relpath(new_abs, movies_dir).replace(os.sep, "/")
            if new_rel != old_name.replace(os.sep, "/"):
                renames.append((old_name, new_rel))

        location_changed = os.path.abspath(t.save_path) != movies_dir
        if not renames and not location_changed and not skip_priority:
            continue

        print(f"  [FIX] {t.name}")
        if location_changed:
            print(f"    location: {t.save_path}  ->  {movies_dir}")
        for old_name, new_rel in renames:
            print(f"    file:     {old_name}  ->  {new_rel}")
        if skip_priority:
            print(f"    priority: {len(skip_priority)} file(s) -> do-not-download")

        if args.apply:
            try:
                client.torrents_pause(torrent_hashes=t.hash)
                for old_name, new_rel in renames:
                    client.torrents_rename_file(torrent_hash=t.hash, old_path=old_name, new_path=new_rel)
                if location_changed:
                    client.torrents_set_location(torrent_hashes=t.hash, location=movies_dir)
                if skip_priority:
                    client.torrents_file_priority(torrent_hash=t.hash, file_ids=skip_priority, priority=0)
                to_recheck.append(t.hash)
            except Exception as e:
                print(f"    [ERROR] failed to apply changes for {t.name}: {e}")
                continue

        fixed += 1
        junk_deprioritized += len(skip_priority)
        print()

    # ── Pass 3: hide healthy torrents in .torrents ──────────────────────────
    hidden = 0
    deferred = 0
    moved_to_hide = []

    if args.hide:
        for t in torrents:
            if t.hash not in torrent_files:
                continue
            if t.hash in broken:
                deferred += 1
                continue
            if os.path.abspath(t.save_path) == hide_dir:
                continue
            print(f"  [HIDE] {t.name}")
            print(f"    location: {t.save_path}  ->  {hide_dir}")
            if args.apply:
                try:
                    client.torrents_set_location(torrent_hashes=t.hash, location=hide_dir)
                    moved_to_hide.append(t.hash)
                except Exception as e:
                    print(f"    [ERROR] could not move {t.name}: {e}")
                    continue
            hidden += 1
        print()

    print("=== Summary ===")
    print(f"  Healthy before this run                  : {healthy_count}")
    print(f"  Fixed{' (applied)' if args.apply else ' (planned)'}                            : {fixed}")
    print(f"  Skipped entirely (manual review needed)  : {skipped_torrents}")
    print(f"  Files marked do-not-download             : {junk_deprioritized}")
    if args.hide:
        print(f"  Moved to .torrents{' (applied)' if args.apply else ' (planned)'}               : {hidden}")
        if deferred:
            print(f"  Hide deferred (needed fixing/review)     : {deferred}  -> run --hide again after rechecks finish")

    if not args.apply:
        print("\nDry-run complete. Nothing was changed. Re-run with --apply to make these changes.")
        return

    if to_recheck:
        print(f"\nTriggering recheck on {len(to_recheck)} torrent(s)...")
        client.torrents_recheck(torrent_hashes=to_recheck)

    to_resume = list(dict.fromkeys(to_recheck + moved_to_hide))
    if to_resume and args.resume_after:
        if to_recheck:
            print("Waiting for recheck to finish before resuming...")
            wait_for_checking(client, to_recheck)
        client.torrents_resume(torrent_hashes=to_resume)
        print("Resumed.")
    elif to_resume:
        print("Torrents are left paused. In qBittorrent: select all -> right-click -> Resume "
              "(or re-run with --resume-after).")


if __name__ == "__main__":
    main()
