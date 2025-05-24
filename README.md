
# AnimePahe Downloader (`animepahe-dl.sh`)


[![Shell](https://img.shields.io/badge/Shell-Bash-8caaee?style=flat-square&logoColor=white&labelColor=292c3c&scale=2)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/License-WTFPL-e5c890?style=flat-square&logoColor=white&labelColor=292c3c&scale=2)](http://www.wtfpl.net/)
[![Stars](https://img.shields.io/github/stars/ruxartic/animepahe-dl?style=flat-square&logo=github&color=babbf1&logoColor=white&labelColor=292c3c&scale=2)](https://github.com/ruxartic/animepahe-dl)
[![Forks](https://img.shields.io/github/forks/ruxartic/animepahe-dl?style=flat-square&logo=github&color=a6d189&logoColor=white&labelColor=292c3c&scale=2)](https://github.com/ruxartic/animepahe-dl)
[![Source](https://img.shields.io/badge/Source-AnimePahe-ca9ee6?style=flat-square&logoColor=white&labelColor=292c3c&scale=2)](https://animepahe.ru/)


`animepahe-dl.sh` is a command-line tool written in Bash to download anime videos from [animepahe.ru](https://animepahe.ru/). It offers features like anime searching, flexible episode selection, resolution and audio language preferences, and parallel downloads.

> This script is a fork of [original animepahe-dl](https://github.com/KevCui/animepahe-dl) with added features and improvements.

## ✨ Features

* **Anime Discovery:**
  * Search for anime by name using AnimePahe's API.
  * Interactively select from search results or the local anime list using `fzf`.
  * Alternatively, specify anime directly by its AnimePahe slug/session ID.
* **Flexible Episode Selection:**
  * Download single episodes, multiple specific episodes, or ranges.
  * Download all available episodes using `*`.
  * Exclude specific episodes or ranges (e.g., `*,!5` means all except episode 5).
  * Select the latest 'N', first 'N', from 'N' onwards, or up to 'N' episodes.
  * Combine selection criteria (e.g., "1-10,!5,L2" for episodes 1-10 except 5, plus the latest 2).
  * Interactive prompt for episode selection if not provided via command-line.
* **Download Customization:**
  * Specify preferred video resolution (e.g., "1080", "720"). If not available or specified, the script attempts to pick the best available.
  * Choose preferred audio language (e.g., "eng", "jpn").
* **Efficient Downloading:**
  * Parallel segment downloads using GNU Parallel for faster HLS stream processing.
  * Configurable number of download threads (`-t <num>`, default: 4).
  * Optional timeout for individual segment download jobs (`-T <secs>`).
* **User Experience:**
  * Colorized and informative terminal output.
  * Terminal title updates to reflect current download progress.
  * Debug mode (`-d`) for verbose logging and to preserve temporary files.
  * Option to list m3u8 stream links without downloading (`-l`).
  * Organized video downloads into `~/Videos/<Anime Title>/` by default (configurable via `ANIMEPAHE_VIDEO_DIR`).
  * Optional desktop notifications on download completion (requires `notify-send` and `ANIMEPAHE_DOWNLOAD_NOTIFICATION=true`).

## ⚙️ Prerequisites

Before you can use `animepahe-dl.sh`, ensure the following command-line tools are installed:

* **`bash`**: Version 4.0 or higher is recommended.
* **`curl`**: For making HTTP requests.
* **`jq`**: For parsing JSON responses.
* **`fzf`**: For interactive selection menus.
* **`node` (Node.js)**: For executing JavaScript to deobfuscate stream links.
* **`ffmpeg`**: For concatenating downloaded HLS video segments.
* **`openssl`**: For decrypting HLS segments if encrypted.
* **`GNU Parallel`**: For parallel downloading of HLS segments.
* **`mktemp`**: For creating temporary directories (usually part of coreutils).
* **(Optional) `notify-send`**: For desktop notifications.

<br/>

> [!TIP]
> You can usually install these dependencies using your system's package manager.

<details>
<summary>Installing Dependencies (Examples)</summary>

### Ubuntu/Debian

```bash
sudo apt update
sudo apt install -y bash curl jq fzf nodejs ffmpeg openssl parallel 
```
*(Note: `nodejs` package might provide an older version. Consider using NodeSource for newer Node.js versions if needed.)*

### Fedora

```bash
sudo dnf install -y bash curl jq fzf nodejs ffmpeg openssl parallel
```

### Arch Linux

```bash
sudo pacman -Syu bash curl jq fzf nodejs ffmpeg openssl parallel 
```

### macOS (using Homebrew)

```bash
brew install bash curl jq fzf node ffmpeg openssl gnu-parallel coreutils
```

> For Windows users, consider using WSL (Windows Subsystem for Linux) and install dependencies within your WSL environment.

</details>

## 🚀 Installation

1. **Download the script:**
   Save the script content as `animepahe-dl.sh` (or your preferred name).

   ```bash
   # clone the repository:
   git clone https://github.com/ruxartic/animepahe-dl.git
   cd animepahe-dl
   ```


2. **(Optional) Place it in your PATH:**
   For easy access, move or symlink `animepahe-dl.sh` to a directory in your `PATH`, such as `~/.local/bin/`:

   ```bash
   # Example:
   # mkdir -p ~/.local/bin
   # ln -s "$(pwd)/animepahe-dl.sh" ~/.local/bin/animepahe-dl
   ```

   Ensure `~/.local/bin` is in your `PATH` (add `export PATH="$HOME/.local/bin:$PATH"` to your `~/.bashrc` or `~/.zshrc` if not).

## 🛠️ Configuration

The script uses environment variables for some optional configurations:

*   **`ANIMEPAHE_VIDEO_DIR`**: Sets the root directory for downloaded anime.
    *   Default: `"$HOME/Videos"` (anime will be saved in `"$HOME/Videos/<Anime Title>/"`)
    *   Example: `export ANIMEPAHE_VIDEO_DIR="$HOME/MyAnime"`
*   **`ANIMEPAHE_LIST_FILE`**: Specifies the path for the master anime list file.
    *   Default: `"$ANIMEPAHE_VIDEO_DIR/anime.list"`
    *   Example: `export ANIMEPAHE_LIST_FILE="$HOME/.cache/animepahe.list"`
*   **`ANIMEPAHE_DL_NODE`**: Specifies a custom path to the `node` executable.
*   **`ANIMEPAHE_DOWNLOAD_NOTIFICATION`**: Set to `true` to enable desktop notifications upon completion.
    *   Example: `export ANIMEPAHE_DOWNLOAD_NOTIFICATION=true`

## 📖 Usage

The script will display its usage information if run with `-h` or `--help`.

```
./animepahe-dl.sh [-a <anime name>] [-s <anime_slug>] [-e <episode_selection>] [-r <resolution>] [-o <language>] [-t <num>] [-T <secs>] [-l] [-d] [-h]
```

**Key Options (refer to script's `--help` for full details):**

*   `-a <name>`: Search anime by name.
*   `-s <slug>`: Use a specific anime slug/session ID.
*   `-e <selection>`: Episode selection string (e.g., "1,3-5", "*", "L3", "*,!6"). See script help for more examples.
*   `-r <resolution>`: Preferred video resolution (e.g., "1080", "720").
*   `-o <language>`: Preferred audio language (e.g., "eng", "jpn").
*   `-t <num>`: Number of parallel download threads (default: 4).
*   `-T <secs>`: Timeout for individual segment downloads.
*   `-l`: List m3u8 links only, do not download.
*   `-d`: Enable debug mode.
*   `-h | --help`: Display help message.

### Examples

*   **Interactively select an anime and episodes:**
    ```bash
    ./animepahe-dl.sh
    ```
    Follow the `fzf` prompts and then the episode selection prompt.

*   **Search for "Jujutsu Kaisen" and download episode 5, preferring 720p:**
    ```bash
    ./animepahe-dl.sh -a "Jujutsu Kaisen" -e 5 -r 720
    ```

*   **Download episodes 1-3 and latest 2 of anime with slug `abcdef123`, English audio, using 8 threads:**
    ```bash
    ./animepahe-dl.sh -s abcdef123 -e "1-3,L2" -o eng -t 8
    ```

*   **Download all episodes of "Attack on Titan" except episodes 10 and 11:**
    ```bash
    ./animepahe-dl.sh -a "Attack on Titan" -e "*,!10,!11"
    ```

*   **List the m3u8 link for episode 1 of "Spy x Family" (dubbed):**
    ```bash
    ./animepahe-dl.sh -a "Spy x Family" -e 1 -o eng -l
    # (Note: AnimePahe typically uses 'jpn' for subbed, 'eng' for dubbed if available)
    ```

## 🛠️ How It Works (Simplified)

1.  **Initialization**: Checks dependencies, sets up variables.
2.  **Anime Identification**:
    *   Uses `-a <name>` to search via AnimePahe's API, then `fzf` for selection.
    *   Uses `-s <slug>` directly with the local anime list or API details.
3.  **Episode List Retrieval**: Fetches episode details (session IDs) from AnimePahe API, handling pagination.
4.  **Episode Selection Parsing**: Parses the `-e <selection>` string or prompts user.
5.  **Stream Details Acquisition (for each selected episode):**
    *   Fetches the AnimePahe play page for the episode's session ID.
    *   Parses the play page to find available stream sources (filtering out AV1).
    *   Selects a stream based on user preferences (`-r`, `-o`) or picks the best available.
    *   Deobfuscates JavaScript on the stream provider's page (e.g., Kwik) to get the M3U8 playlist URL.
6.  **Downloading (HLS):**
    *   Downloads the M3U8 playlist.
    *   HLS video segments are downloaded in parallel using GNU Parallel.
    *   Segments are decrypted using OpenSSL if necessary.
7.  **Assembly (HLS)**: `ffmpeg` concatenates decrypted segments into a single `.mp4` file.
8.  **File Organization**: Saves video files to `ANIMEPAHE_VIDEO_DIR/<Anime Title>/<Episode Number>.mp4`.
9.  **Cleanup**: Temporary files and directories are removed (unless in debug mode).

## 📜 Disclaimer

> [!WARNING]
> The purpose of this script is to download anime episodes for personal, offline viewing, especially when internet access is unavailable.
> *   Please **DO NOT** copy or distribute downloaded anime episodes to any third party.
> *   It is recommended to watch them and delete them afterwards.
> *   Use this script at your own responsibility and respect copyright laws.
> *   The AnimePahe website, its API, and stream providers may change their structure at any time, which could break this script.

## 🤝 Contributing

Contributions, bug reports, and feature requests are welcome! Please feel free to open an issue or submit a pull request on the [GitHub repository](https://github.com/ruxartic/animepahe-dl).

## 🗂️ Other similar projects
 - [original animepahe-dl](https://github.com/KevCui/animepahe-dl)
 - [zen-api downloader](https://github.com/ruxartic/zen-anime-dl)
 - [twistmoe-dl](https://github.com/KevCui/twistmoe-dl)

## 📜 License

This project is licensed under the [WTFPL PUBLIC LICENSE](./LICENSE).

