# AnimePahe Downloader (`animepahe-dl.sh`)

[![Shell](https://img.shields.io/badge/Shell-Bash-8caaee?style=flat-square&logoColor=white&labelColor=292c3c&scale=2)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/License-WTFPL-e5c890?style=flat-square&logoColor=white&labelColor=292c3c&scale=2)](http://www.wtfpl.net/)
[![Stars](https://img.shields.io/github/stars/ruxartic/animepahe-dl?style=flat-square&logo=github&color=babbf1&logoColor=white&labelColor=292c3c&scale=2)](https://github.com/ruxartic/animepahe-dl)
[![Forks](https://img.shields.io/github/forks/ruxartic/animepahe-dl?style=flat-square&logo=github&color=a6d189&logoColor=white&labelColor=292c3c&scale=2)](https://github.com/ruxartic/animepahe-dl)
[![Source](https://img.shields.io/badge/Source-AnimePahe-ca9ee6?style=flat-square&logoColor=white&labelColor=292c3c&scale=2)](https://animepahe.pw/)

`animepahe-dl.sh` is a single Bash script that downloads anime from [animepahe](https://animepahe.pw) right from the terminal. It searches for a title or takes its slug, parses an episode selection like `1-5,!3` or `L2`, downloads the HLS stream in parallel, decrypts it if needed and merges everything into one `.mp4` per episode. Downloads resume after an interruption, and the progress output is meant to be readable.

```
▌ Episode 1  (1/1)
  ✔ Stream       1080p · jpn
  ✔ Playlist     145 segments
  ✔ Downloaded   145 segments in 1m 43s
  ✔ Decrypted    145 segments in 2s
  ✔ Merged       1.mp4 · 184M

──────────────────────────────────────────────
Summary
  ✔ Downloaded   1  (1)
  • Location     ~/Videos/Black Clover
  • Time         2m 19s
```

## ✨ Features

* **Anime Discovery:**
  * Search for anime by name using AnimePahe's API.
  * Pick from the search results with `fzf`, or from a numbered menu if `fzf` isn't installed.
  * Specify an anime directly by its slug/uuid, or browse the cached list of all titles.
  * If the search API is down, the query is matched against the cached list instead.
* **Flexible Episode Selection:**
  * Download single episodes, several specific episodes, or ranges.
  * Download everything with `*`, and exclude episodes or ranges (e.g. `*,!5` means all except episode 5).
  * Select the latest 'N', the first 'N', from 'N' onwards, or up to 'N' episodes.
  * Combine criteria freely (e.g. `1-10,!5,L2` is episodes 1-10 except 5, plus the latest 2).
  * Interactive prompt for the selection if it isn't given on the command line.
* **Download Customization:**
  * Preferred video resolution (`-r 1080`, `-r 720`). Without it, the best available is used.
  * Preferred audio language (`-o eng`, `-o jpn`). By default the script prefers English when the episode offers it — even at a lower resolution — and otherwise takes the best available stream. `-r` wins over that soft default, and an explicit `-o` only accepts that language.
* **Efficient Downloading:**
  * Built-in parallel downloader (4 threads by default) with retries and a progress bar.
  * The first segment is fetched on its own, so access problems fail in seconds instead of after hundreds of retries.
  * Configurable thread count (`-t <num>`) and per-segment timeout (`-T <secs>`, default 300).
  * **Resume:** per-episode work directories (`.work-ep<N>/`) keep partial segments across runs — re-run the same command to pick up where it stopped (`--no-resume` to start over, `--keep-workdir` to keep the work files after success).
  * `yt-dlp` is used instead of the built-in downloader with `--ytdlp`, and automatically as a fallback when the video host refuses the built-in one.
* **Cloudflare-friendly:**
  * `--login` opens a temporary Chrome/Chromium/Brave/Edge window, waits for the site's browser check to pass and saves the cookie and User-Agent.
  * If the site accepts the browser but not curl, requests to the site are routed through the browser for the rest of the run.
  * `curl-impersonate` (`curl_chromeNN` wrappers) is picked up automatically for the video host.
* **User Experience:**
  * Colourised, informative terminal output, and the terminal title follows the current step.
  * Debug mode (`-d`) with verbose logging that also saves the play page for inspection.
  * Option to list the m3u8 playlist URLs without downloading (`-l`); stdout stays pipe-safe.
  * Downloads are organised into `~/Videos/<Anime Title>/` by default (configurable via `ANIMEPAHE_VIDEO_DIR`).
  * Optional desktop notification when a run finishes (requires `notify-send` and `ANIMEPAHE_DOWNLOAD_NOTIFICATION=true`).

## ⚙️ Requirements

**Required:**

* **`bash`**: 4.4 or newer (on macOS: `brew install bash`; the system bash is too old).
* **`curl`**: for making HTTP requests.
* **`jq`**: for parsing JSON responses.
* **`ffmpeg`**: for joining the HLS segments into one file.
* **`openssl`**: for decrypting encrypted HLS segments.
* **`xargs`**, **`mktemp`** and standard coreutils/findutils: usually part of any base system.
* **A JavaScript runtime**: `node` (default), `bun` or `deno`. It unpacks the obfuscated script on the stream page. Override with `--js-runtime`, `ANIMEPAHE_JS_RUNTIME` or `ANIMEPAHE_DL_NODE`.

**Optional:**

* **`fzf`**: for the interactive picker (without it a numbered menu is used; in headless mode the first result is auto-selected).
* **`curl-impersonate`**: for requests that plain curl gets refused (the `curl_chromeNN` wrapper scripts are detected automatically).
* **`yt-dlp`** with the `curl_cffi` Python package: used as a fallback or with `--ytdlp`.
* **Chrome, Chromium, Brave or Edge** plus Node 22+, Bun or Deno: needed for `--login`.
* **`notify-send`**: for the desktop notification.

<br/>

> [!TIP]
> You can usually install these dependencies using your system's package manager.

<details>
<summary>Installing Dependencies (Examples)</summary>

### Ubuntu/Debian

```bash
sudo apt update
sudo apt install -y bash curl jq ffmpeg openssl nodejs fzf
```
*(Note: the `nodejs` package might provide an older version. Consider NodeSource for a newer Node.js if needed.)*

### Fedora

```bash
sudo dnf install -y bash curl jq ffmpeg openssl nodejs fzf
```

### Arch Linux

```bash
sudo pacman -Syu bash curl jq ffmpeg openssl nodejs fzf
```

### macOS (using Homebrew)

```bash
brew install bash curl jq ffmpeg openssl node fzf coreutils
```

> For Windows users, consider using WSL (Windows Subsystem for Linux) and installing the dependencies inside your WSL environment.

</details>

## 🚀 Installation

**Option 1 — install script (recommended):**

```bash
curl -fsSL https://raw.githubusercontent.com/ruxartic/animepahe-dl/master/install.sh | bash
```

Downloads `animepahe-dl.sh` to a temp file, checks that it is a valid script, copies it to `~/.local/bin/anime` and creates a sample config file (Linux and macOS; only `curl` needed). An existing copy is backed up as `anime.bak` instead of being overwritten silently.

**Option 2 — clone the repo and run the installer:**

```bash
git clone https://github.com/ruxartic/animepahe-dl.git
cd animepahe-dl
./install.sh
```

**Option 3 — install from a checkout, without a download:**

```bash
git clone https://github.com/ruxartic/animepahe-dl.git
cd animepahe-dl
./install.sh ./animepahe-dl.sh
```

**Installer usage** — `./install.sh [url] [destination]` (defaults: raw GitHub `master` → `~/.local/bin/anime`).

| Option | Description |
|---|---|
| `-u`, `--url <url>` | script to install (https only) |
| `-d`, `--dest <path>` | install path, default `~/.local/bin/anime` |
| `--sha256 <hash>` | verify the download against this checksum |
| `--no-config` | don't create a sample config file |
| `--force` | overwrite the destination without keeping a backup |
| `--uninstall` | remove an installed copy (the config file is kept) |

**Option 4 — manual:**

1. **Download the script:**
   Save the script content as `animepahe-dl.sh` (or your preferred name).

   ```bash
   # clone the repository:
   git clone https://github.com/ruxartic/animepahe-dl.git
   cd animepahe-dl
   ```

2. **Place it in your `PATH`:**
   For easy access, move or symlink `animepahe-dl.sh` to a directory in your `PATH`, such as `~/.local/bin/`:

   ```bash
   # Example:
   mkdir -p ~/.local/bin
   install -m 755 animepahe-dl.sh ~/.local/bin/animepahe-dl
   # or symlink it:
   ln -s "$(pwd)/animepahe-dl.sh" ~/.local/bin/animepahe-dl
   ```

   Ensure `~/.local/bin` is in your `PATH` (add `export PATH="$HOME/.local/bin:$PATH"` to your `~/.bashrc` or `~/.zshrc` if not).

## 🏃 Quick start

```sh
# pick a title from the full list, then type the episodes you want
anime

# search by name, download episodes 1 to 3
anime -a "black clover" -e 1-3

# by slug, the latest two episodes at 720p
anime -s 07193a7f-27c0-430f-bf3d-f1d9c61669a5 -e L2 -r 720
```

Files are written to `~/Videos/<Title>/<episode>.mp4`. Episodes that already exist are skipped.

If you get an HTTP 403 on the first run, run `anime --login` once.

## 📖 Usage

```
anime           [-a <name>] [-s <slug>] [-e <selection>] [-r <res>] [-o <lang>]
                [-t <n>] [-T <secs>] [-l] [-y] [-d] [--login] [--refresh]
                [--no-resume] [--keep-workdir] [--ytdlp] [--js-runtime <name>]
                [--no-color] [-h] [--version]
```

> [!TIP]
> After installing with `install.sh`, the same command is available as `anime`, e.g. `anime -a "Jujutsu Kaisen" -e 5`.
>
> `anime --help` prints the full list of options and environment variables.

### Selecting episodes

`-e` takes a comma-separated list of any of these:

| Pattern | Meaning |
|---|---|
| `1` | one episode |
| `1,3,5` | several episodes |
| `1-5` | a range |
| `*` | everything |
| `L3` | the latest 3 |
| `F5` | the first 5 |
| `10-` | episode 10 and everything after |
| `-5` | everything up to 5 |
| `!4` or `!10-12` | exclude, e.g. `*,!1,!10-12` |

Patterns combine: `1-10,!5,L2` is episodes 1 to 10 without 5, plus the latest two. A selection made only of exclusions starts from everything. Fractional episode numbers such as `10.5` work in ranges.

### Resolution and audio

Without options the script takes English audio if the episode offers it, at the best resolution that track has. If there is no English track it takes the best available stream. `-r 1080` picks that resolution, and it wins over the English preference. `-o jpn` (or any other language) accepts only that language. If the language you ask for isn't offered, you get a warning and the best available stream.

### Options

| Option | Description |
|---|---|
| `-a <name>` | search by name |
| `-s <slug>` | anime slug or uuid |
| `-e <selection>` | episodes, see above |
| `-r <res>` | resolution, e.g. `1080`, `720` |
| `-o <lang>` | audio language, e.g. `eng`, `jpn` |
| `-t <n>` | download threads, default 4 |
| `-T <secs>` | per-segment timeout, default 300 |
| `-l` | print playlist URLs, don't download |
| `-y`, `--headless` | never prompt, take the first search result |
| `--login` | get a cookie through a temporary browser window |
| `--refresh` | ignore cached lists |
| `--no-resume` | don't reuse partial downloads |
| `--keep-workdir` | keep the per-episode work files after success |
| `--ytdlp` | download with yt-dlp instead of the built-in downloader |
| `--js-runtime <name>` | `node`, `bun`, `deno`, or a path |
| `--no-color` | plain output (`NO_COLOR` also works) |
| `-d` | debug output |
| `-h`, `--help` | full help |
| `--version` | print the version |

### Examples

* **Interactively select an anime and episodes:**

  ```bash
  anime
  ```

  Follow the `fzf` prompts and then the episode selection prompt.

* **Search for "Jujutsu Kaisen" and download episode 5, preferring 720p:**

  ```bash
  anime -a "Jujutsu Kaisen" -e 5 -r 720
  ```

* **Headless: search, auto-select the first result, download episode 5:**

  ```bash
  anime -y -a "Jujutsu Kaisen" -e 5 -r 720
  # or: ANIMEPAHE_HEADLESS=true anime -a "Jujutsu Kaisen" -e 5
  ```

* **Headless list-only (pipe-safe — stdout is URLs only):**

  ```bash
  anime -y -a "Spy x Family" -e 1 -o eng -l > urls.txt
  ```

* **Download episodes 1-3 and the latest 2 of an anime with slug `abcdef123`, English audio, using 8 threads:**

  ```bash
  anime -s abcdef123 -e "1-3,L2" -o eng -t 8
  ```

* **Download all episodes of "Attack on Titan" except episodes 10 and 11:**

  ```bash
  anime -a "Attack on Titan" -e "*,!10,!11"
  ```

* **List the m3u8 link for episode 1 of "Spy x Family" (dubbed):**

  ```bash
  anime -a "Spy x Family" -e 1 -o eng -l
  # (Note: AnimePahe typically uses 'jpn' for subbed, 'eng' for dubbed if available)
  ```

### Scripting

`-y` makes the script fail instead of prompting when something is missing, so it needs `-a` or `-s`, and an episode selection from `-e` or `ANIMEPAHE_EPISODES`. It also turns on by itself when `-a` or `-s` and `-e` are given and stdin isn't a terminal. The exit status is 1 if any episode failed, otherwise 0. A failed run prints the command that retries only the failed episodes.

## 🛡️ When the site blocks you

animepahe runs a browser check, and requests without the right cookie get HTTP 403. At startup the script makes one test request. If it is blocked, it asks whether to open a browser window (in a non-interactive run it stops and tells you to use `--login`). You can also run it directly:

```sh
anime --login
```

This starts Chrome, Chromium, Brave or Edge (whichever it finds first, or `ANIMEPAHE_BROWSER`) with a dedicated profile in `~/.cache/animepahe-dl/profile` and the site's home page open. The script only watches while the check runs. It doesn't attach to the page until the check is over. When the page has loaded, it reads the cookie and User-Agent, saves them to `~/.config/animepahe-dl/config.env` (mode 600), closes the window, and tests the cookie with curl.

Sometimes the site accepts the browser but not curl, even with the same cookie and User-Agent. In that case the script keeps the window open for the rest of the run and sends requests to the site through it. It also sets `ANIMEPAHE_USE_BROWSER=1` in the config, so later runs open the browser by themselves. Video data is still downloaded with curl. If the window stays open, you can minimize it.

If the checkbox never completes:

1. Open the site in your normal browser. If it loops there too, the cause is your network (a VPN, a proxy, or the IP address), not the script.
2. Try real Google Chrome: `ANIMEPAHE_BROWSER=google-chrome anime --login`.
3. Running as root or in a container? Add `ANIMEPAHE_BROWSER_ARGS=--no-sandbox`.
4. To do it by hand, pass the check in your own browser and put the `cf_clearance` cookie and your User-Agent in the config file as `ANIMEPAHE_CF` and `ANIMEPAHE_UA`.

Chromium shows an infobar about an unsupported command-line flag during `--login`. It's the `--disable-blink-features=AutomationControlled` flag the script uses, and it's harmless.

The video host is a separate site and can reject plain curl too. The script uses the newest `curl_chromeNN` wrapper from curl-impersonate when one is installed, and `ANIMEPAHE_CURL` overrides the choice. The startup line shows which curl is in use. If the video host still refuses the built-in downloader, yt-dlp is tried when it's installed.

## 🗂️ Caching

| File | Trusted for | Override |
|---|---|---|
| `<video dir>/anime.list` | 7 days | `ANIMEPAHE_LIST_CACHE_DAYS` |
| `<video dir>/<Title>/.source.json` (episodes) | 6 hours | `ANIMEPAHE_EPISODE_CACHE_HOURS` |

Age comes from the file's modification time. A stale list is refreshed, and if the refresh fails the old one is used with a warning. If you pass a slug that isn't in the list, the list is refreshed once, at most once an hour. If you ask for an episode that the cached episode list doesn't have, the episode list is refreshed and checked again. `--refresh` refreshes both. When site search is down, `-a` falls back to matching your words against the cached list.

## 🛠️ Configuration

Settings come from the environment or from `~/.config/animepahe-dl/config.env`, which is read first. The file has one `KEY=VALUE` per line, `#` comments, and optional quotes. Only `ANIMEPAHE_*` keys are accepted, and a variable already set in the environment wins.

```sh
# ~/.config/animepahe-dl/config.env
ANIMEPAHE_VIDEO_DIR=/mnt/media/anime
ANIMEPAHE_RESOLUTION=1080
ANIMEPAHE_THREADS=8
ANIMEPAHE_DOWNLOAD_NOTIFICATION=true
```

| Variable | Purpose |
|---|---|
| `ANIMEPAHE_CF` | site cookie (written by `--login`) |
| `ANIMEPAHE_UA` | User-Agent that goes with the cookie (written by `--login`) |
| `ANIMEPAHE_HOST` | site URL, default `https://animepahe.pw` |
| `ANIMEPAHE_VIDEO_DIR` | download directory, default `~/Videos` |
| `ANIMEPAHE_LIST_FILE` | location of the cached anime list |
| `ANIMEPAHE_LIST_CACHE_DAYS` | anime list lifetime, default 7 |
| `ANIMEPAHE_EPISODE_CACHE_HOURS` | episode list lifetime, default 6, `0` to always fetch |
| `ANIMEPAHE_EPISODES` | default for `-e` |
| `ANIMEPAHE_RESOLUTION`, `ANIMEPAHE_AUDIO`, `ANIMEPAHE_THREADS`, `ANIMEPAHE_SEGMENT_TIMEOUT` | defaults for `-r`, `-o`, `-t`, `-T` |
| `ANIMEPAHE_JS_RUNTIME` (or `ANIMEPAHE_DL_NODE`) | default for `--js-runtime` |
| `ANIMEPAHE_HEADLESS=true` | default for `--headless` |
| `ANIMEPAHE_AUTO_SELECT=1` | implied by `--headless`, kept for compatibility |
| `ANIMEPAHE_NO_RESUME=1` | default for `--no-resume` |
| `ANIMEPAHE_KEEP_WORKDIR=1` | default for `--keep-workdir` |
| `ANIMEPAHE_DOWNLOAD_NOTIFICATION=true` | desktop notification when a run finishes |
| `ANIMEPAHE_CURL` | curl binary to use |
| `ANIMEPAHE_BROWSER` | browser binary for `--login` |
| `ANIMEPAHE_BROWSER_ARGS` | extra browser flags for `--login` |
| `ANIMEPAHE_LOGIN_TIMEOUT` | seconds to wait for the check, default 180 |
| `ANIMEPAHE_TEMP_PROFILE=1` | use a throwaway browser profile for `--login` |
| `ANIMEPAHE_AUTO_LOGIN=1` | open the browser without asking when blocked |
| `ANIMEPAHE_USE_BROWSER=1` | send site requests through a temporary browser |
| `ANIMEPAHE_HLS_SEQ_IV=1` | use the media-sequence IV when a playlist has no IV |
| `ANIMEPAHE_CONFIG` | path to a different config file |

## 🔍 How it works

1. **Anime identification**: the title is picked from a site search, from the cached list, or given directly as a slug.
2. **Episode list**: the session IDs are fetched from the site's API (with pagination) and cached as `.source.json`.
3. **Episode selection**: the `-e` string is parsed, or the user is prompted.
4. **Stream details**: the play page is parsed for stream options (AV1 ones are skipped) and one is chosen by audio and resolution.
5. **Playlist discovery**: the stream page contains packed JavaScript. It is run with node, bun or deno — inside the runtime's permission sandbox when it has one, with a 15 second limit and a minimal environment — to find the `.m3u8` URL.
6. **Downloading (HLS)**: the playlist is downloaded and parsed. The first segment is fetched alone, then the rest in parallel. Video requests use the stream page's origin as the referer.
7. **Decryption**: if the playlist has an AES-128 key, the segments are decrypted with openssl. When the playlist has no IV, an all-zero IV is used (see `ANIMEPAHE_HLS_SEQ_IV`).
8. **Assembly (HLS)**: `ffmpeg` concatenates the decrypted segments into `<episode>.mp4` without re-encoding. The file is written under a temporary name and renamed when ffmpeg succeeds.
9. **File organisation**: files are saved to `ANIMEPAHE_VIDEO_DIR/<Anime Title>/<Episode Number>.mp4`.
10. **Cleanup**: the per-episode work directory is removed after success, unless `--keep-workdir` is given. It is kept after a failure so the next run can resume.

Segments are written to a `.part` file that is renamed on success, so a crash never leaves a truncated segment that looks complete. If the server's playlist changes between runs, the work directory is discarded and the episode is downloaded again.

## 📂 Files

```
~/Videos/
├── anime.list              cached list of all titles
└── Black Clover/
    ├── .source.json        cached episode list
    ├── 1.mp4
    └── .work-ep2/          partial download, removed after success
```

`-d` also saves each play page as `play_page_ep<N>.html` in the title's folder. `--login` keeps its browser profile in `~/.cache/animepahe-dl/`.

## 🩺 Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| HTTP 403 from the site | Run `--login`. |
| "the host answered: HTTP 403" for the stream page or the first segment | The video host rejects plain curl. Install curl-impersonate, set `ANIMEPAHE_CURL`, or use `--ytdlp`. |
| `yt-dlp ... failed` | `--impersonate` needs `pip install curl_cffi`. |
| `bash 4.4 or newer` error | On macOS, `brew install bash`. |
| "no usable (non-AV1) stream options" | The play page had no non-AV1 streams, or its layout changed. Run with `-d` and look at the saved page. |
| "packed JavaScript not found" | The stream page layout changed, or the host served a challenge page. |
| Decrypted video looks corrupt | Try `ANIMEPAHE_HLS_SEQ_IV=1`. |
| An episode keeps failing | Re-run the same command to resume, or `--no-resume` to start that episode over. |

## 📜 Disclaimer

> [!WARNING]
> The purpose of this script is to download anime episodes for personal, offline viewing, especially when internet access is unavailable.
> *   Please **DO NOT** copy or distribute downloaded anime episodes to any third party.
> *   It is recommended to watch them and delete them afterwards.
> *   Use this script at your own responsibility and respect copyright laws.
> *   The AnimePahe website, its API, and stream providers may change their structure at any time, which could break this script.

This is an unofficial tool. The site and its video hosts change without notice, and the parsing here will break when they do. You are responsible for how you use it and for following the laws and terms that apply to you.

## 🤝 Contributing

Contributions, bug reports, and feature requests are welcome! Please feel free to open an issue or submit a pull request on the [GitHub repository](https://github.com/ruxartic/animepahe-dl).

## 🗂️ Other similar projects

* [original animepahe-dl](https://github.com/KevCui/animepahe-dl)
* [zen-api downloader](https://github.com/ruxartic/zen-anime-dl)
* [twistmoe-dl](https://github.com/KevCui/twistmoe-dl)

## 📜 License

This project is licensed under the [WTFPL PUBLIC LICENSE](./LICENSE).
