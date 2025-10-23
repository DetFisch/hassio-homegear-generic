# Homegear Add-on

## Installation
1. Add this repository (`https://github.com/DetFisch/hassio-homegear-generic`) to Home Assistant via **Settings → Add-ons → Add-on store → Repositories**.
2. Install the **Homegear** add-on and click **Build** so Home Assistant creates the Docker image locally.
3. Start the add-on and open the log to verify that the desired Homegear modules load correctly.

## Configuration Options
| Option          | Description                                                                                               |
|-----------------|-----------------------------------------------------------------------------------------------------------|
| `homegear_user` | Unix user Homegear runs as (defaults to `homegear`). Use `root` only when host-level SPI permissions cannot be adjusted. |

Configuration files live in `/config/homegear`, data in `/share/homegear/lib`, and logs in `/share/homegear/log`. These paths are linked into the container at runtime so upgrades keep your state.

## Runtime Behaviour
- Serial (`/dev/ttyUSB*`, `/dev/ttyAMA*`) and SPI (`/dev/spidev*`) groups are detected and assigned to the configured Homegear user automatically.
- If `/dev/spidev0.0` remains inaccessible for five retries, the MAX! family is disabled to avoid endless reconnect attempts. The module is re-enabled automatically once the device becomes writable again.
- Node-BLUE dependencies are refreshed with `npm install --omit=dev`. Upstream npm vulnerability warnings are expected and currently harmless.

## Troubleshooting
- Ensure SPI is enabled on the host (`dtparam=spi=on` on Raspberry Pi).
- On newer Raspberry Pi kernels (Bookworm / kernel 6.6+), re-enable the legacy GPIO sysfs interface with `gpio=0-27` or `dtoverlay=gpio-no-irq` in `config.txt`; otherwise the CC1101 interrupt GPIO cannot be exported.
- When running as the default `homegear` user, the host should expose the SPI device with group `spi` or a similar non-root group. Otherwise set `homegear_user` to `root` as a last resort.
- Check `/share/homegear/log/homegear.log` for module-specific errors after startup.
