# gdmount

**English** · [Українська](README.uk.md)

Mount Google Drive on Linux with rclone. gdmount creates a user systemd service and supports GNOME, KDE Plasma and other desktop environments.

## Features

- rclone and fuse3 installation
- browser-based Google account authorization
- manual or automatic two-way sync
- configurable automatic sync frequency
- local, offline Google Drive device
- pending two-way sync status
- account switching and complete uninstall
- English and Ukrainian interface

## Installation

```bash
curl -fsSL https://github.com/PanVena/gdmount/raw/refs/heads/main/install.sh | bash
```

Or run the script from this repository:

```bash
./install.sh
```

Interactive installation asks for the interface language, sync mode, and folders to keep local. Selected folders are downloaded to the computer and shown at their usual paths inside `~/Google Drive`; there is no separate folder to open. The view uses `mergerfs`, which the installer installs with rclone. Set `GDMOUNT_UI_LANG=uk|en` to select the language without a prompt.

During Google sign-in, rclone uses local port `53682`. If a previous sign-in is still using it, the installer shows the process and offers to close a stuck rclone process before retrying.

If the `gdrive` remote already exists but its token has expired, the installer offers to sign in again in the browser. When running rclone manually, include the colon after the remote name: `rclone config reconnect gdrive:`.

## Usage

```text
gdmount install [options]       install and mount
gdmount local list              list local-first folders
gdmount local add [PATH]        add folders by number or by path
gdmount local remove PATH       remove a folder from the local view
gdmount sync                    sync local folders with Google Drive
gdmount sync-mode               show or change sync method and frequency
gdmount status                  mount, pending sync changes and disk space
gdmount mode [all|selected]     show or change the local scope
gdmount start | stop            start or stop the drive
gdmount switch-account [options] switch Google account
gdmount uninstall [options]     remove gdmount-created files
gdmount --help                  show full help
```

Configuration is stored in `~/.config/rclone-gdrive-setup/config`.

In selected-folder mode, use `gdmount local add` to add folders from a numbered list or `gdmount local add PATH` to add one by path. At the numbered prompt, you can enter a range such as `1-3` or combine ranges and individual numbers, such as `1,3-5`. Use `gdmount mode selected` to replace the list or switch from the whole drive to selected folders.

## Local folders

Selected folders are kept locally in gdmount's app data and appear at the same paths inside `~/Google Drive`. Only selected folders are available in this local device. Files in them open from local storage and remain available offline.

Check the selection with `gdmount local list`. Adding folders starts their initial download and sync. `gdmount local remove PATH` removes that selection and archives any data that falls outside the remaining selections. A folder stays available while one of its parent folders is selected.

- `manual`: local changes stay on this computer until you run `gdmount sync`; no background timer is installed.
- `auto`: gdmount syncs selected folders both ways at the configured interval.

`gdmount sync` sends local changes to Google Drive and downloads remote changes. `gdmount status` checks pending changes with a dry run; it does not transfer files and lists the local files waiting to upload.

Change the method and frequency without downloading the files again:

```bash
gdmount sync-mode manual
gdmount sync-mode auto --sync-interval 30m
```

New interactive installations ask for these settings. Non-interactive
installations default to the energy-saving `manual` mode; `--sync-interval 0`
and the legacy `--poll-interval 0` also select manual mode.

Sync is bidirectional: deletions propagate to the other side, and simultaneous edits to the same file are saved as conflict copies. The first run reconciles existing local and cloud versions by modification time; gdmount keeps a local version replaced by a newer cloud version in its recovery archive. Both `gdmount switch-account` and installing with a different `--remote` archive the previous local copy. Choose which folders to download for the new connection.

## Uninstall

```bash
gdmount uninstall
```

Use `--yes` for unattended uninstall. gdmount removes an rclone remote automatically only when its exact name was recorded at creation. Existing Google Drive files are never deleted.

## License

[MIT](LICENSE)
