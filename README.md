# Home Assistant Add-on: Homegear

Homegear bridges Home Assistant with a broad range of automation ecosystems such as Homematic, MAX!, KNX, EnOcean and many more.  
This add-on ships the current Homegear 0.9 series on top of Home Assistant’s Debian Bookworm base image and everything is compiled during the Home Assistant build step – no external Docker registry required.

## Highlights
- Homegear 0.9.4 from the official Homegear APT repository for Debian Bookworm
- Supports the full Homegear module set except the legacy EASY\* components (which are no longer maintained upstream)
- Automatic SPI/serial permission handling with a safety net that disables the MAX! module after five failed access attempts (re-enabled automatically once the device becomes reachable again)
- Multi-architecture images (`aarch64`, `amd64`, `armhf`, `armv7`)

## Installation
1. In Home Assistant open **Settings → Add-ons → Add-on store**.
2. Select the menu in the top right corner and choose **Repositories**.
3. Add `https://github.com/DetFisch/hassio-homegear-generic`.
4. The add-on appears as **Homegear** in the custom repository section. Install it from there and press **Build** to create the image locally.

## Configuration
The add-on currently exposes a single option:

| Key            | Type   | Default   | Description                                                                           |
| -------------- | ------ | --------- | ------------------------------------------------------------------------------------- |
| `homegear_user` | string | `homegear` | User Homegear drops privileges to. Set this to `root` if you cannot adjust host-side SPI permissions. |

Configuration files, state and logs are stored on the persistent Home Assistant `/config` and `/share` volumes, so rebuilds/upgrades keep your Homegear setup intact.

## Runtime Notes
- SPI devices (`/dev/spidev*`) and serial ports are detected on start and matching groups are added to the configured Homegear user automatically.
- If the SPI interface is not writable after five retries, the MAX! module is disabled to avoid endless reconnect loops; once access is restored it is enabled again.
- Node-BLUE dependencies are refreshed on each boot with `npm install --omit=dev`; warnings about `npm audit` are informational and come from upstream packages.

## Contributing
Issues and pull requests are welcome. Please test changes across architectures where possible; GitHub Actions workflows are planned but not yet available for this fork.

## License
This project is released under the MIT License. See [LICENSE](LICENSE) for details.
