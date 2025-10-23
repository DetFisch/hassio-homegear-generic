#!/usr/bin/env bashio
set -Eeuo pipefail

_term() {
	local pid_file
	for pid_file in \
		/var/run/homegear/homegear-management.pid \
		/var/run/homegear/homegear-influxdb.pid \
		/var/run/homegear/homegear.pid; do
		if [[ -f "${pid_file}" ]]; then
			if pid="$(cat "${pid_file}")"; then
				kill "${pid}" 2>/dev/null || true
				wait "${pid}" 2>/dev/null || true
			fi
		fi
	done
	if [[ -x /etc/homegear/homegear-stop.sh ]]; then
		/etc/homegear/homegear-stop.sh || true
	fi
	exit 0
}

trap _term SIGTERM SIGINT

USER="$(bashio::config 'homegear_user')"
if ! PRIMARY_GROUP="$(id -gn "${USER}")"; then
	bashio::log.warning "Unable to determine primary group for ${USER}, falling back to user name."
	PRIMARY_GROUP="${USER}"
fi
MAX_DEVICE="/dev/spidev0.0"
MAX_CHECKS=5
MAX_AUTOMANAGE_MARKER="/var/lib/homegear/.max-spidev-automanaged"
MAX_CONFIG="/etc/homegear/families/max.conf"
declare -a MAX_CONFIGURED_GPIOS=()
declare -i MAX_GPIO_VALIDATION_FAILED=0
declare -i MAX_GPIO_OVERLAY_HINT_PRINTED=0

write_max_module_state() {
	local desired="$1"
	[[ -f "${MAX_CONFIG}" ]] || return 1
	if grep -Eq '^[[:space:]]*moduleEnabled[[:space:]]*=' "${MAX_CONFIG}"; then
		sed -i -E "s|^[[:space:]]*moduleEnabled[[:space:]]*=.*|moduleEnabled = ${desired}|" "${MAX_CONFIG}"
	else
		printf '\nmoduleEnabled = %s\n' "${desired}" >> "${MAX_CONFIG}"
	fi
	return 0
}

current_max_module_state() {
	[[ -f "${MAX_CONFIG}" ]] || return 1
	local value
	value="$(grep -E '^[[:space:]]*moduleEnabled[[:space:]]*=' "${MAX_CONFIG}" | tail -n1 | awk -F= '{print $2}' | tr -d '[:space:]')" || true
	[[ -n "${value}" ]] || return 1
	printf '%s\n' "${value}"
	return 0
}

disable_max_module() {
	local current_state
	current_state="$(current_max_module_state || true)"
	if [[ "${current_state}" != "false" ]]; then
		if write_max_module_state false; then
			touch "${MAX_AUTOMANAGE_MARKER}"
		fi
	else
		rm -f "${MAX_AUTOMANAGE_MARKER}"
	fi
}

enable_max_module_if_managed() {
	[[ -f "${MAX_AUTOMANAGE_MARKER}" ]] || return 1
	if (( MAX_GPIO_VALIDATION_FAILED )); then
		return 1
	fi
	if write_max_module_state true; then
		rm -f "${MAX_AUTOMANAGE_MARKER}"
		return 0
	fi
	return 1
}

user_can_access_device() {
	local device="$1"
	if [[ "${USER}" == "root" ]]; then
		[[ -r "${device}" && -w "${device}" ]]
	else
		su -s /bin/bash "${USER}" -c "test -r '${device}' && test -w '${device}'"
	fi
}

log_device_listing() {
	local label="$1"
	local pattern="$2"
	local output
	output="$(ls -al ${pattern} 2> /dev/null || true)"
	if [[ -n "${output}" ]]; then
		bashio::log.info "${label}"
		printf '%s\n' "${output}"
	else
		bashio::log.info "${label} (none detected)"
	fi
}

collect_max_configured_gpios() {
	local config="$1"
	MAX_CONFIGURED_GPIOS=()
	[[ -f "${config}" ]] || return 0
	local line stripped lower key value
	local in_section=0
	while IFS= read -r line || [[ -n "${line}" ]]; do
		stripped="${line%%#*}"
		stripped="${stripped#"${stripped%%[!$' 	']*}"}"
		stripped="${stripped%"${stripped##*[!$' 	']}"}"
		[[ -n "${stripped}" ]] || continue
		lower="${stripped,,}"
		if [[ "${lower}" == \[*\] ]]; then
			if [[ "${lower}" == *"ti cc1101 module"* ]]; then
				in_section=1
			else
				in_section=0
			fi
			continue
		fi
		if (( in_section )); then
			key="${lower%%=*}"
			key="${key#"${key%%[!$' 	']*}"}"
			key="${key%"${key##*[!$' 	']}"}"
			value="${lower#*=}"
			value="${value#"${value%%[!$' 	']*}"}"
			value="${value%"${value##*[!$' 	']}"}"
			if [[ "${key}" =~ ^gpio[0-9]+$ && "${value}" =~ ^[0-9]+$ ]]; then
				MAX_CONFIGURED_GPIOS+=("${value}")
			fi
		fi
	done < "${config}"
	if ((${#MAX_CONFIGURED_GPIOS[@]} > 0)); then
		mapfile -t MAX_CONFIGURED_GPIOS < <(printf '%s\n' "${MAX_CONFIGURED_GPIOS[@]}" | sort -un)
	fi
}

try_export_gpio() {
	local gpio="$1"
	local export_path="/sys/class/gpio/export"
	local unexport_path="/sys/class/gpio/unexport"
	local err_file err_msg exported=0

	if [[ ! -w "${export_path}" || ! -w "${unexport_path}" ]]; then
		bashio::log.debug "GPIO sysfs export paths not writable; skipping check for GPIO ${gpio}."
		return 0
	fi

	if [[ -d "/sys/class/gpio/gpio${gpio}" ]]; then
		return 0
	fi

	err_file="$(mktemp)"
	if printf '%s' "${gpio}" > "${export_path}" 2>"${err_file}"; then
		exported=1
	else
		err_msg="$(<"${err_file}")"
	fi
	rm -f "${err_file}"

	if (( exported )); then
		printf '%s' "${gpio}" > "${unexport_path}" 2> /dev/null || true
		return 0
	fi

	if [[ -n "${err_msg:-}" ]]; then
		if [[ "${err_msg}" == *"Invalid argument"* ]]; then
			bashio::log.error "GPIO ${gpio} could not be exported via sysfs (Invalid argument). On recent Raspberry Pi kernels the legacy GPIO sysfs interface must be enabled manually (e.g. add \"gpio=0-27\" or \"dtoverlay=gpio-no-irq\" to config.txt)."
			if (( MAX_GPIO_OVERLAY_HINT_PRINTED == 0 )); then
				if [[ -d /proc/device-tree/overlays ]]; then
					if [[ ! -d /proc/device-tree/overlays/gpio-no-irq ]]; then
						bashio::log.warning "GPIO overlay \"gpio-no-irq\" not detected on the host. Please ensure dtoverlay=gpio-no-irq is active in config.txt."
					fi
				else
					bashio::log.debug "Device-tree overlay information not available; skipping overlay presence check."
				fi
				MAX_GPIO_OVERLAY_HINT_PRINTED=1
			fi
		else
			bashio::log.warning "Failed to export GPIO ${gpio}: ${err_msg}"
		fi
	fi
	return 1
}

validate_max_gpio_access() {
	local failure=0 gpio

	((${#MAX_CONFIGURED_GPIOS[@]} > 0)) || return 0

	for gpio in "${MAX_CONFIGURED_GPIOS[@]}"; do
		if ! try_export_gpio "${gpio}"; then
			failure=1
		fi
	done

	if (( failure )); then
		MAX_GPIO_VALIDATION_FAILED=1
		bashio::log.warning "Disabling MAX module until GPIO sysfs access is available."
		disable_max_module
	fi
}


bashio::log.info "Initializing Homegear as user ${USER}"

mkdir -p /config/homegear \
	/share/homegear/lib \
	/share/homegear/log \
	/usr/share/homegear/firmware

chown "${USER}:${PRIMARY_GROUP}" /config/homegear \
	/share/homegear/lib \
	/share/homegear/log

rm -Rf /etc/homegear \
	/var/lib/homegear \
	/var/log/homegear

ln -nfs /config/homegear     /etc/homegear
ln -nfs /share/homegear/lib /var/lib/homegear
ln -nfs /share/homegear/log /var/log/homegear

if [[ -z "$(ls -A /etc/homegear 2> /dev/null)" ]]; then
	bashio::log.info "Copying default Homegear configuration."
	cp -a /etc/homegear.config/. /etc/homegear/
else
	if compgen -G "/etc/homegear.config/devices/*" > /dev/null; then
		bashio::log.info "Refreshing default device definitions."
		cp -a /etc/homegear.config/devices/. /etc/homegear/devices/
	fi
fi

if [[ ! -e /etc/homegear/nodeBlueCredentialKey.txt ]]; then
	bashio::log.info "Generating Node-BLUE credential key."
	tr -dc A-Za-z0-9 < /dev/urandom | head -c 43 > /etc/homegear/nodeBlueCredentialKey.txt
	chmod 400 /etc/homegear/nodeBlueCredentialKey.txt
fi

if [[ -z "$(ls -A /var/lib/homegear 2> /dev/null)" ]]; then
	bashio::log.info "Initialising Homegear data directory."
	cp -a /var/lib/homegear.data/. /var/lib/homegear/
else
	bashio::log.info "Refreshing Homegear module assets."
	rm -Rf /var/lib/homegear/modules/*
	mkdir -p /var/lib/homegear.data/modules
	if compgen -G "/var/lib/homegear.data/modules/*" > /dev/null; then
		cp -a /var/lib/homegear.data/modules/. /var/lib/homegear/modules/ || bashio::log.warning 'Could not copy modules to "homegear.data/modules/". Please verify directory permissions.'
	fi

	rm -Rf /var/lib/homegear/flows/nodes/*
	mkdir -p /var/lib/homegear.data/node-blue/nodes
	if compgen -G "/var/lib/homegear.data/node-blue/nodes/*" > /dev/null; then
		cp -a /var/lib/homegear.data/node-blue/nodes/. /var/lib/homegear/node-blue/nodes/ || bashio::log.warning 'Could not copy nodes to "homegear.data/node-blue/nodes". Please verify directory permissions.'
	fi

	rm -Rf /var/lib/homegear/node-blue/www
	if [[ -d /var/lib/homegear.data/node-blue/www ]]; then
		cp -a /var/lib/homegear.data/node-blue/www /var/lib/homegear/node-blue/ || bashio::log.warning 'Could not copy Node-BLUE frontend to "homegear.data/node-blue/www". Please verify directory permissions.'
	fi

	if [[ -d /var/lib/homegear/admin-ui ]]; then
		bashio::log.info "Refreshing Admin UI static files."
		find /var/lib/homegear/admin-ui -mindepth 1 -maxdepth 1 ! -name translations -exec rm -Rf {} +
		mkdir -p /var/lib/homegear.data/admin-ui
		if compgen -G "/var/lib/homegear.data/admin-ui/*" > /dev/null; then
			cp -a /var/lib/homegear.data/admin-ui/. /var/lib/homegear/admin-ui/ || bashio::log.warning 'Could not copy admin UI to "homegear.data/admin-ui". Please verify directory permissions.'
		fi
		if [[ ! -f /var/lib/homegear/admin-ui/.env && -f /var/lib/homegear.data/admin-ui/.env ]]; then
			cp -a /var/lib/homegear.data/admin-ui/.env /var/lib/homegear/admin-ui/
		fi
		if [[ -f /var/lib/homegear.data/admin-ui/.version ]]; then
			cp -a /var/lib/homegear.data/admin-ui/.version /var/lib/homegear/admin-ui/ || bashio::log.warning 'Could not copy admin UI version to "homegear.data/admin-ui". Please verify directory permissions.'
		fi
	else
		bashio::log.warning "Directory /var/lib/homegear/admin-ui not found."
	fi
fi

rm -f /var/lib/homegear/homegear_updated

collect_max_configured_gpios "${MAX_CONFIG}"
validate_max_gpio_access

if [[ -d /var/lib/homegear/node-blue/node-red ]]; then
	bashio::log.info "Preparing Node-BLUE workspace."
	pushd /var/lib/homegear/node-blue/node-red > /dev/null || bashio::log.warning "Directory /var/lib/homegear/node-blue/node-red not found."
	if [[ "${PWD}" == "/var/lib/homegear/node-blue/node-red" ]]; then
		if ! npm install --omit=dev --no-audit --prefer-offline; then
			bashio::log.warning "npm install (--prefer-offline) failed for Node-BLUE, retrying without cache hint."
			if ! npm install --omit=dev --no-audit; then
				bashio::log.warning "npm install failed for Node-BLUE. Please inspect the logs above."
			fi
		fi
		popd > /dev/null || true
	fi
fi

if [[ ! -f /var/log/homegear/homegear.log ]]; then
	bashio::log.info "Creating initial Homegear log files."
	touch /var/log/homegear/homegear.log
	touch /var/log/homegear/homegear-flows.log
	touch /var/log/homegear/homegear-scriptengine.log
	touch /var/log/homegear/homegear-management.log
	touch /var/log/homegear/homegear-influxdb.log
fi

if [[ ! -f /etc/homegear/dh1024.pem ]]; then
	bashio::log.info "Generating Homegear certificates."
	openssl genrsa -out /etc/homegear/homegear.key 2048
	openssl req -batch -new -key /etc/homegear/homegear.key -out /etc/homegear/homegear.csr
	openssl x509 -req -in /etc/homegear/homegear.csr -signkey /etc/homegear/homegear.key -out /etc/homegear/homegear.crt
	rm /etc/homegear/homegear.csr
	chown "${USER}:${PRIMARY_GROUP}" /etc/homegear/homegear.key
	chmod 400 /etc/homegear/homegear.key
	openssl dhparam -check -text -5 -out /etc/homegear/dh1024.pem 1024
	chown "${USER}:${PRIMARY_GROUP}" /etc/homegear/dh1024.pem
	chmod 400 /etc/homegear/dh1024.pem
fi

chown -R root:root /etc/homegear
find /etc/homegear -maxdepth 1 -type f -name '*.key' -exec chown "${USER}:${PRIMARY_GROUP}" {} +
find /etc/homegear -maxdepth 1 -type f -name '*.pem' -exec chown "${USER}:${PRIMARY_GROUP}" {} +
if [[ -f /etc/homegear/nodeBlueCredentialKey.txt ]]; then
	chown "${USER}:${PRIMARY_GROUP}" /etc/homegear/nodeBlueCredentialKey.txt
fi
find /etc/homegear -type d -exec chmod 755 {} \;
chown -R "${USER}:${PRIMARY_GROUP}" /var/log/homegear /var/lib/homegear
find /var/log/homegear -type d -exec chmod 750 {} \;
find /var/log/homegear -type f -exec chmod 640 {} \;
find /var/lib/homegear -type d -exec chmod 750 {} \;
find /var/lib/homegear -type f -exec chmod 640 {} \;
find /var/lib/homegear/scripts -type f -exec chmod 550 {} \;

TZ=$(echo "$TZ" | tr -d '"') # Some users report quotes around the string - remove them
if [[ -n $TZ ]]; then
	ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && echo "$TZ" > /etc/timezone
fi

mkdir -p /var/run/homegear
chown "${USER}:${PRIMARY_GROUP}" /var/run/homegear

log_device_listing "Attached ttyUSB devices:" "/dev/ttyUSB*"
log_device_listing "Attached ttyAMA devices:" "/dev/ttyAMA*"
log_device_listing "Attached spidev devices:" "/dev/spidev*"

# Add user to the group of all /dev/ttyUSB, /dev/ttyAMA and /dev/spidev devices so that they are usable
if [[ "${USER}" != "root" ]]; then
	bashio::log.info "Ensuring ${USER} can access detected serial and SPI devices."
	DEVICE_GROUPS=$({ stat -c '%g' /dev/ttyUSB* 2> /dev/null || : ; stat -c '%g' /dev/ttyAMA* 2> /dev/null || : ; stat -c '%g' /dev/spidev* 2> /dev/null || : ; } | sort -u)
	if [[ -n "${DEVICE_GROUPS}" ]]; then
		while read -r line; do
			[[ -n "${line}" ]] || continue
			if [[ "${line}" == "0" ]]; then
				bashio::log.debug "Skipping root group (gid 0); handled separately."
				continue
			fi

			GROUP_NAME="$(getent group "${line}" | cut -d: -f1 || true)"
			if [[ -z "${GROUP_NAME}" ]]; then
				GROUP_NAME="${USER}-${line}"
				if groupadd -g "${line}" "${GROUP_NAME}" 2> /dev/null; then
					bashio::log.info "Created helper group ${GROUP_NAME} (gid ${line})."
				else
					GROUP_NAME="$(getent group "${line}" | cut -d: -f1 || true)"
					if [[ -z "${GROUP_NAME}" ]]; then
						bashio::log.warning "Failed to create helper group for gid ${line}; skipping."
						continue
					fi
				fi
			else
				bashio::log.debug "Found existing group ${GROUP_NAME} for gid ${line}."
			fi

			if usermod -a -G "${GROUP_NAME}" "${USER}"; then
				bashio::log.info "Added ${USER} to group ${GROUP_NAME}."
			else
				bashio::log.warning "Failed to add ${USER} to group ${GROUP_NAME}."
			fi
		done <<< "${DEVICE_GROUPS}"
	else
		bashio::log.info "No additional serial or SPI groups detected."
	fi

	if usermod -a -G "root" "${USER}"; then
		bashio::log.debug "Added ${USER} to group root for GPIO/USB access."
	else
		bashio::log.warning "Failed to add ${USER} to group root."
	fi
else
	bashio::log.info "Running as root; skipping supplemental group adjustments."
fi

if [[ -c "${MAX_DEVICE}" ]]; then
	bashio::log.info "Validating permissions for MAX interface ${MAX_DEVICE}."
	attempt=1
	while (( attempt <= MAX_CHECKS )); do
		if user_can_access_device "${MAX_DEVICE}"; then
			bashio::log.info "MAX interface accessible for ${USER}."
			if enable_max_module_if_managed; then
				bashio::log.info "Re-enabled MAX module after successful permission check."
			fi
			break
		fi
		bashio::log.warning "MAX interface permission denied (attempt ${attempt}/${MAX_CHECKS})."
		sleep 2
		((attempt++))
	done
	if (( attempt > MAX_CHECKS )); then
		bashio::log.warning "Disabling MAX module after ${MAX_CHECKS} failed attempts."
		disable_max_module
	fi
else
	bashio::log.debug "MAX interface ${MAX_DEVICE} not present."
fi

bashio::log.info "Starting Homegear (/usr/bin/homegear -u ${USER} -g ${USER})"

# Set permissions on interfaces and directories, export GPIOs.
if [[ "${USER}" == "root" ]]; then
	if ! /usr/bin/homegear -u "${USER}" -g "${USER}" -p /var/run/homegear/homegear.pid -pre >> /dev/null 2>&1; then
		bashio::log.warning "Homegear pre-start hook failed; GPIO setup may be incomplete."
	fi
else
	if ! /usr/bin/homegear -pre >> /dev/null 2>&1; then
		bashio::log.warning "Homegear pre-start hook failed; GPIO setup may be incomplete."
	fi
fi

/usr/bin/homegear -u "${USER}" -g "${USER}" -p /var/run/homegear/homegear.pid &
sleep 5
/usr/bin/homegear-management -p /var/run/homegear/homegear-management.pid &
/usr/bin/homegear-influxdb -u "${USER}" -g "${USER}" -p /var/run/homegear/homegear-influxdb.pid &
tail -f /var/log/homegear/homegear-flows.log &
tail -f /var/log/homegear/homegear-scriptengine.log &
tail -f /var/log/homegear/homegear-management.log &
tail -f /var/log/homegear/homegear-influxdb.log &
tail -f /var/log/homegear/homegear.log &
child=$!
wait "$child"
