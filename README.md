# gdmount

**English** · [Українська](README.uk.md)

Mount Google Drive on Linux with rclone. gdmount creates a user systemd service and supports GNOME, KDE Plasma and other desktop environments.

## Features

- rclone and fuse3 installation
- browser-based Google account authorization
- manual and automatic metadata refresh modes
- network-aware mounting
- cache refresh and upload queue status
- account switching and complete uninstall
- English and Ukrainian interface

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/PanVena/gdmount/main/gdrive-mount.sh | bash -s -- install
```

Or run the script from this repository:

```bash
./gdrive-mount.sh install
```

Set `GDMOUNT_UI_LANG=uk|en` to select the interface language. If unset, gdmount detects it from the system locale.

## Usage

```text
gdmount install [options]       install and mount
gdmount refresh [PATH] [-r]     refresh directory cache
gdmount refresh --all           refresh the whole drive
gdmount status                  service, mount and cache status
gdmount mode [manual|auto]      show or change refresh mode
gdmount start | stop            start or stop the drive
gdmount switch-account [options] switch Google account
gdmount uninstall [options]     remove gdmount-created files
gdmount --help                  show full help
```

Configuration is stored in `~/.config/rclone-gdrive-setup/config`.

## Refresh modes

- `manual`: rclone does not poll Google automatically; use `gdmount refresh`.
- `auto`: rclone polls Google every minute.

## Uninstall

```bash
gdmount uninstall
```

Use `--yes` for unattended uninstall. Existing Google Drive files are never deleted.

## License

[MIT](LICENSE)
