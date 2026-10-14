# premierecinemas

Command-line tools for a local movie library on Linux:

- **`premierecinemas`** fuzzy-searches your movie folders and plays what it finds in VLC, with a small Star Wars–style intro.
- **`organize`** tidies your Movies folder: it renames releases to `Title (Year).ext`, sorts subtitles into `Subtitles/`, files TV episodes into their show folders and moves leftovers to `rest/`.
- **`qbt_relink.py`** points qBittorrent at the files `organize` moved or renamed, so they keep seeding.

All three share one setting: your **Movies directory**.

## Setup

```bash
git clone https://github.com/AmigoSmuCha/premierecinemas.git
cd premierecinemas
./install.sh
```

`install.sh` walks you through it:

1. checks for what the scripts need (VLC, GNU grep and find, …)
2. asks where your Movies directory is, and creates it if needed
3. saves it in `~/.config/premierecinemas/config`, where `premierecinemas` searches it and `organize` and `qbt_relink.py` work on it
4. copies `premierecinemas`, `organize` and `qbt_relink.py` into `~/.local/bin`
5. puts the intro art in `~/.local/bin/art` (files still in `~/.local/lib/art` are moved there)
6. adds `~/.local/bin` to your `PATH` (in `~/.bashrc` or `~/.zshrc`) if it isn't there yet

To skip the questions: `./install.sh --movies-dir ~/Movies --yes`

After that the commands don't need the cloned folder anymore. Keep it if you want updates: `git pull`, then `./install.sh` again. Re-running is safe; it is also how you switch to a different Movies directory, and your other settings are kept.

When `install.sh` would replace something in `~/.local/bin` that it didn't put there itself (or that you edited since), it asks first and keeps the old file as a backup: `organize.bak`, then `organize.bak01`, `organize.bak02`, and so on. Its own unchanged copies are simply updated.

### Requirements

- Linux with bash 4+, GNU grep (with `-P`) and GNU find
- [VLC](https://www.videolan.org/vlc/) for playback
- Only for `qbt_relink.py`: Python 3, `pip install qbittorrent-api --break-system-packages`, and the qBittorrent Web UI enabled

## Usage

```bash
premierecinemas interstellar             # play a movie
premierecinemas "breaking bad s02"       # queue a whole season
premierecinemas --add-directory ~/TV     # search another folder too
premierecinemas --help

organize --dry-run                       # preview what would change
organize                                 # tidy the Movies directory
organize --movies-dir /mnt/usb/Movies    # one-off run on another folder

qbt_relink.py                            # dry run
qbt_relink.py --apply                    # relink torrents
```

The first time, `qbt_relink.py` asks for your qBittorrent Web UI username and password and saves them in `~/Desktop/.QBT_LOGIN` for the next runs. The file is plain text, readable only by you; delete it to be asked again. `--username` / `--password` override it for a single run.

## Configuration

Everything lives in `~/.config/premierecinemas/config`:

| Setting | Meaning |
| --- | --- |
| `intro=true` | Show the ASCII intro (`premierecinemas --intro-off` turns it off) |
| `movies_dir=/path` | Your Movies directory, which `organize` and `qbt_relink.py` work on. Set it with `./install.sh`. |
| `dir=/path` | A folder `premierecinemas` searches, one line each. `install.sh` adds your Movies directory; manage the rest with `--add-directory` / `--remove-directory`. |

The intro art is read from `art/intro.txt` next to the `premierecinemas` command, so `~/.local/bin/art/intro.txt` once installed. Without that file, the intro is skipped.

## Uninstall

```bash
./install.sh --uninstall
```

This removes the three commands from `~/.local/bin` (any you edited after installing are left in place). Your config, the intro art, backups and the saved qBittorrent login stay; delete `~/.config/premierecinemas`, `~/.local/bin/art` and `~/Desktop/.QBT_LOGIN` to remove them too.
