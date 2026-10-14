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
4. links `premierecinemas` and `organize` into `~/.local/bin`
5. adds `~/.local/bin` to your `PATH` (in `~/.bashrc` or `~/.zshrc`) if it isn't there yet

To skip the questions: `./install.sh --movies-dir ~/Movies --yes`

Re-run it any time, for example to switch to a different Movies directory. Your other settings are kept. If `~/.local/bin` already has a different `premierecinemas` or `organize`, the script asks before replacing it and keeps the old one as `<name>.bak`.

The installed commands are symlinks into this folder, so `git pull` here updates them. If you move the folder, run `./install.sh` again.

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

python3 qbt_relink.py --username admin            # dry run
python3 qbt_relink.py --username admin --apply    # relink torrents
```

## Configuration

Everything lives in `~/.config/premierecinemas/config`:

| Setting | Meaning |
| --- | --- |
| `intro=true` | Show the ASCII intro (`premierecinemas --intro-off` turns it off) |
| `movies_dir=/path` | Your Movies directory, which `organize` and `qbt_relink.py` work on. Set it with `./install.sh`. |
| `dir=/path` | A folder `premierecinemas` searches, one line each. `install.sh` adds your Movies directory; manage the rest with `--add-directory` / `--remove-directory`. |

The intro art is read from `art/intro.txt` next to the `premierecinemas` script. Without that file, the intro is skipped.

## Uninstall

```bash
./install.sh --uninstall
```

This removes the two commands from `~/.local/bin`. Your config stays; delete `~/.config/premierecinemas` to remove it too.
