#!/bin/bash
#
# Install Game Server
#
# Please ensure to run this script as root (or at least with sudo)
#
# @LICENSE AGPLv3
# @AUTHOR  Charlie Powell <cdp1337@bitsnbytes.dev>
# @CATEGORY Game Server
# @TRMM-TIMEOUT 600
# @WARLOCK-TITLE Hytale
# @WARLOCK-IMAGE media/content-upper-new-1920.jpg
# @WARLOCK-ICON media/logo-h.png
# @WARLOCK-THUMBNAIL media/logo.png
#
# Supports:
#   Debian 12, 13
#   Ubuntu 24.04
#
# Requirements:
#   None
#
# TRMM Custom Fields:
#   None
#
# Syntax:
#   --uninstall  - Perform an uninstallation
#   --dir=<src> - Use a custom installation directory instead of the default (optional)
#   --skip-firewall  - Do not install or configure a system firewall
#   --non-interactive  - Run the installer in non-interactive mode (useful for scripted installs)
#   --game-branch=<latest|pre-release> - Specify a specific branch of the game server to install DEFAULT=latest
#   --branch=<str> - Use a specific branch of the management script repository DEFAULT=main
#
# Changelog:
#   20251103 - New installer

############################################
## Parameter Configuration
############################################

# Name of the game (used to create the directory)
GAME="Hytale"
GAME_DESC="Hytale Dedicated Server"
REPO="BitsNBytes25/Hytale-Installer"
WARLOCK_GUID="f73feed8-7202-0747-b5ba-efd8e8a0b002"
GAME_USER="hytale"
GAME_DIR="/home/${GAME_USER}"
GAME_SERVICE="hytale-server"

function usage() {
  cat >&2 <<EOD
Usage: $0 [options]

Options:
    --uninstall  - Perform an uninstallation
    --dir=<src> - Use a custom installation directory instead of the default (optional)
    --skip-firewall  - Do not install or configure a system firewall
    --non-interactive  - Run the installer in non-interactive mode (useful for scripted installs)
    --game-branch=<latest|pre-release> - Specify a specific branch of the game server to install DEFAULT=latest
    --branch=<str> - Use a specific branch of the management script repository DEFAULT=main

Please ensure to run this script as root (or at least with sudo)

@LICENSE AGPLv3
EOD
  exit 1
}

# Parse arguments
MODE_UNINSTALL=0
OVERRIDE_DIR=""
SKIP_FIREWALL=0
NONINTERACTIVE=0
GAME_BRANCH="latest"
BRANCH="main"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--uninstall) MODE_UNINSTALL=1; shift 1;;
		--dir=*)
			OVERRIDE_DIR="${1#*=}";
			[ "${OVERRIDE_DIR:0:1}" == "'" ] && [ "${OVERRIDE_DIR:0-1}" == "'" ] && OVERRIDE_DIR="${OVERRIDE_DIR:1:-1}"
			[ "${OVERRIDE_DIR:0:1}" == '"' ] && [ "${OVERRIDE_DIR:0-1}" == '"' ] && OVERRIDE_DIR="${OVERRIDE_DIR:1:-1}"
			shift 1;;
		--skip-firewall) SKIP_FIREWALL=1; shift 1;;
		--non-interactive) NONINTERACTIVE=1; shift 1;;
		--game-branch=*)
			GAME_BRANCH="${1#*=}";
			[ "${GAME_BRANCH:0:1}" == "'" ] && [ "${GAME_BRANCH:0-1}" == "'" ] && GAME_BRANCH="${GAME_BRANCH:1:-1}"
			[ "${GAME_BRANCH:0:1}" == '"' ] && [ "${GAME_BRANCH:0-1}" == '"' ] && GAME_BRANCH="${GAME_BRANCH:1:-1}"
			shift 1;;
		--branch=*)
			BRANCH="${1#*=}";
			[ "${BRANCH:0:1}" == "'" ] && [ "${BRANCH:0-1}" == "'" ] && BRANCH="${BRANCH:1:-1}"
			[ "${BRANCH:0:1}" == '"' ] && [ "${BRANCH:0-1}" == '"' ] && BRANCH="${BRANCH:1:-1}"
			shift 1;;
		-h|--help) usage;;
	esac
done

##
# Simple check to enforce the script to be run as root
if [ $(id -u) -ne 0 ]; then
	echo "This script must be run as root or with sudo!" >&2
	exit 1
fi
##
# Simple wrapper to emulate `which -s`
#
# The -s flag is not available on all systems, so this function
# provides a consistent way to check for command existence
# without having to include '&>/dev/null' everywhere.
#
# Returns 0 on success, 1 on failure
#
# Arguments:
#   $1 - Command to check
#
# CHANGELOG:
#   2025.12.15 - Initial version (for a regression fix)
#
function cmd_exists() {
	local CMD="$1"
	which "$CMD" &>/dev/null
	return $?
}

##
# Get which firewall is enabled,
# or "none" if none located
function get_enabled_firewall() {
	if [ "$(systemctl is-active firewalld)" == "active" ]; then
		echo "firewalld"
	elif [ "$(systemctl is-active ufw)" == "active" ]; then
		echo "ufw"
	elif [ "$(systemctl is-active iptables)" == "active" ]; then
		echo "iptables"
	else
		echo "none"
	fi
}

##
# Get which firewall is available on the local system,
# or "none" if none located
#
# CHANGELOG:
#   2025.12.15 - Use cmd_exists to fix regression bug
#   2025.04.10 - Switch from "systemctl list-unit-files" to "which" to support older systems
function get_available_firewall() {
	if cmd_exists firewall-cmd; then
		echo "firewalld"
	elif cmd_exists ufw; then
		echo "ufw"
	elif systemctl list-unit-files iptables.service &>/dev/null; then
		echo "iptables"
	else
		echo "none"
	fi
}
##
# Check if the OS is "like" a certain type
#
# Returns 0 if true, 1 if false
#
# Usage:
#   if os_like debian; then ... ; fi
#
function os_like() {
	local OS="$1"

	if [ -f '/etc/os-release' ]; then
		ID="$(egrep '^ID=' /etc/os-release | sed 's:ID=::')"
		LIKE="$(egrep '^ID_LIKE=' /etc/os-release | sed 's:ID_LIKE=::')"

		if [[ "$LIKE" =~ "$OS" ]] || [ "$ID" == "$OS" ]; then
			return 0;
		fi
	fi
	return 1
}

##
# Check if the OS is "like" a certain type
#
# ie: "ubuntu" will be like "debian"
#
# Returns 0 if true, 1 if false
# Prints 1 if true, 0 if false
#
# Usage:
#   if [ "$(os_like_debian)" -eq 1 ]; then ... ; fi
#   if os_like_debian -q; then ... ; fi
#
function os_like_debian() {
	local QUIET=0
	while [ $# -ge 1 ]; do
		case $1 in
			-q)
				QUIET=1;;
		esac
		shift
	done

	if os_like debian || os_like ubuntu; then
		if [ $QUIET -eq 0 ]; then echo 1; fi
		return 0;
	fi

	if [ $QUIET -eq 0 ]; then echo 0; fi
	return 1
}

##
# Check if the OS is "like" a certain type
#
# ie: "ubuntu" will be like "debian"
#
# Returns 0 if true, 1 if false
# Prints 1 if true, 0 if false
#
# Usage:
#   if [ "$(os_like_ubuntu)" -eq 1 ]; then ... ; fi
#   if os_like_ubuntu -q; then ... ; fi
#
function os_like_ubuntu() {
	local QUIET=0
	while [ $# -ge 1 ]; do
		case $1 in
			-q)
				QUIET=1;;
		esac
		shift
	done

	if os_like ubuntu; then
		if [ $QUIET -eq 0 ]; then echo 1; fi
		return 0;
	fi

	if [ $QUIET -eq 0 ]; then echo 0; fi
	return 1
}

##
# Check if the OS is "like" a certain type
#
# ie: "ubuntu" will be like "debian"
#
# Returns 0 if true, 1 if false
# Prints 1 if true, 0 if false
#
# Usage:
#   if [ "$(os_like_rhel)" -eq 1 ]; then ... ; fi
#   if os_like_rhel -q; then ... ; fi
#
function os_like_rhel() {
	local QUIET=0
	while [ $# -ge 1 ]; do
		case $1 in
			-q)
				QUIET=1;;
		esac
		shift
	done

	if os_like rhel || os_like fedora || os_like rocky || os_like centos; then
		if [ $QUIET -eq 0 ]; then echo 1; fi
		return 0;
	fi

	if [ $QUIET -eq 0 ]; then echo 0; fi
	return 1
}

##
# Check if the OS is "like" a certain type
#
# ie: "ubuntu" will be like "debian"
#
# Returns 0 if true, 1 if false
# Prints 1 if true, 0 if false
#
# Usage:
#   if [ "$(os_like_suse)" -eq 1 ]; then ... ; fi
#   if os_like_suse -q; then ... ; fi
#
function os_like_suse() {
	local QUIET=0
	while [ $# -ge 1 ]; do
		case $1 in
			-q)
				QUIET=1;;
		esac
		shift
	done

	if os_like suse; then
		if [ $QUIET -eq 0 ]; then echo 1; fi
		return 0;
	fi

	if [ $QUIET -eq 0 ]; then echo 0; fi
	return 1
}

##
# Check if the OS is "like" a certain type
#
# ie: "ubuntu" will be like "debian"
#
# Returns 0 if true, 1 if false
# Prints 1 if true, 0 if false
#
# Usage:
#   if [ "$(os_like_arch)" -eq 1 ]; then ... ; fi
#   if os_like_arch -q; then ... ; fi
#
function os_like_arch() {
	local QUIET=0
	while [ $# -ge 1 ]; do
		case $1 in
			-q)
				QUIET=1;;
		esac
		shift
	done

	if os_like arch; then
		if [ $QUIET -eq 0 ]; then echo 1; fi
		return 0;
	fi

	if [ $QUIET -eq 0 ]; then echo 0; fi
	return 1
}

##
# Check if the OS is "like" a certain type
#
# ie: "ubuntu" will be like "debian"
#
# Returns 0 if true, 1 if false
# Prints 1 if true, 0 if false
#
# Usage:
#   if [ "$(os_like_bsd)" -eq 1 ]; then ... ; fi
#   if os_like_bsd -q; then ... ; fi
#
function os_like_bsd() {
	local QUIET=0
	while [ $# -ge 1 ]; do
		case $1 in
			-q)
				QUIET=1;;
		esac
		shift
	done

	if [ "$(uname -s)" == 'FreeBSD' ]; then
		if [ $QUIET -eq 0 ]; then echo 1; fi
		return 0;
	else
		if [ $QUIET -eq 0 ]; then echo 0; fi
		return 1
	fi
}

##
# Check if the OS is "like" a certain type
#
# ie: "ubuntu" will be like "debian"
#
# Returns 0 if true, 1 if false
# Prints 1 if true, 0 if false
#
# Usage:
#   if [ "$(os_like_macos)" -eq 1 ]; then ... ; fi
#   if os_like_macos -q; then ... ; fi
#
function os_like_macos() {
	local QUIET=0
	while [ $# -ge 1 ]; do
		case $1 in
			-q)
				QUIET=1;;
		esac
		shift
	done

	if [ "$(uname -s)" == 'Darwin' ]; then
		if [ $QUIET -eq 0 ]; then echo 1; fi
		return 0;
	else
		if [ $QUIET -eq 0 ]; then echo 0; fi
		return 1
	fi
}
##
# Get the operating system version
#
# Just the major version number is returned
#
function os_version() {
	if [ "$(uname -s)" == 'FreeBSD' ]; then
		local _V="$(uname -K)"
		if [ ${#_V} -eq 6 ]; then
			echo "${_V:0:1}"
		elif [ ${#_V} -eq 7 ]; then
			echo "${_V:0:2}"
		fi

	elif [ -f '/etc/os-release' ]; then
		local VERS="$(egrep '^VERSION_ID=' /etc/os-release | sed 's:VERSION_ID=::')"

		if [[ "$VERS" =~ '"' ]]; then
			# Strip quotes around the OS name
			VERS="$(echo "$VERS" | sed 's:"::g')"
		fi

		if [[ "$VERS" =~ \. ]]; then
			# Remove the decimal point and everything after
			# Trims "24.04" down to "24"
			VERS="${VERS/\.*/}"
		fi

		if [[ "$VERS" =~ "v" ]]; then
			# Remove the "v" from the version
			# Trims "v24" down to "24"
			VERS="${VERS/v/}"
		fi

		echo "$VERS"

	else
		echo 0
	fi
}

##
# Install a package with the system's package manager.
#
# Uses Redhat's yum, Debian's apt-get, and SuSE's zypper.
#
# Usage:
#
# ```syntax-shell
# package_install apache2 php7.0 mariadb-server
# ```
#
# @param $1..$N string
#        Package, (or packages), to install.  Accepts multiple packages at once.
#
#
# CHANGELOG:
#   2026.01.09 - Cleanup os_like a bit and add support for RHEL 9's dnf
#   2025.04.10 - Set Debian frontend to noninteractive
#
function package_install (){
	echo "package_install: Installing $*..."

	if os_like_bsd -q; then
		pkg install -y $*
	elif os_like_debian -q; then
		DEBIAN_FRONTEND="noninteractive" apt-get -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" install -y $*
	elif os_like_rhel -q; then
		if [ "$(os_version)" -ge 9 ]; then
			dnf install -y $*
		else
			yum install -y $*
		fi
	elif os_like_arch -q; then
		pacman -Syu --noconfirm $*
	elif os_like_suse -q; then
		zypper install -y $*
	else
		echo 'package_install: Unsupported or unknown OS' >&2
		echo 'Please report this at https://github.com/eVAL-Agency/ScriptsCollection/issues' >&2
		exit 1
	fi
}

##
# Simple download utility function
#
# Uses either cURL or wget based on which is available
#
# Downloads the file to a temp location initially, then moves it to the final destination
# upon a successful download to avoid partial files.
#
# Returns 0 on success, 1 on failure
#
# Arguments:
#   --no-overwrite       Skip download if destination file already exists
#
# CHANGELOG:
#   2025.12.15 - Use cmd_exists to fix regression bug
#   2025.12.04 - Add --no-overwrite option to allow skipping download if the destination file exists
#   2025.11.23 - Download to a temp location to verify download was successful
#              - use which -s for cleaner checks
#   2025.11.09 - Initial version
#
function download() {
	# Argument parsing
	local SOURCE="$1"
	local DESTINATION="$2"
	local OVERWRITE=1
	local TMP=$(mktemp)
	shift 2

	while [ $# -ge 1 ]; do
    		case $1 in
    			--no-overwrite)
    				OVERWRITE=0
    				;;
    		esac
    		shift
    	done

	if [ -z "$SOURCE" ] || [ -z "$DESTINATION" ]; then
		echo "download: Missing required parameters!" >&2
		return 1
	fi

	if [ -f "$DESTINATION" ] && [ $OVERWRITE -eq 0 ]; then
		echo "download: Destination file $DESTINATION already exists, skipping download." >&2
		return 0
	fi

	if cmd_exists curl; then
		if curl -fsL "$SOURCE" -o "$TMP"; then
			mv $TMP "$DESTINATION"
			return 0
		else
			echo "download: curl failed to download $SOURCE" >&2
			return 1
		fi
	elif cmd_exists wget; then
		if wget -q "$SOURCE" -O "$TMP"; then
			mv $TMP "$DESTINATION"
			return 0
		else
			echo "download: wget failed to download $SOURCE" >&2
			return 1
		fi
	else
		echo "download: Neither curl nor wget is installed, cannot download!" >&2
		return 1
	fi
}
##
# Determine if the current shell session is non-interactive.
#
# Checks NONINTERACTIVE, CI, DEBIAN_FRONTEND, and TERM.
#
# Returns 0 (true) if non-interactive, 1 (false) if interactive.
#
# CHANGELOG:
#   2025.12.16 - Remove TTY checks to avoid false positives in some environments
#   2025.11.23 - Initial version
#
function is_noninteractive() {
	# explicit flags
	case "${NONINTERACTIVE:-}${CI:-}" in
		1*|true*|TRUE*|True*|*CI* ) return 0 ;;
	esac

	# debian frontend
	if [ "${DEBIAN_FRONTEND:-}" = "noninteractive" ]; then
		return 0
	fi

	# dumb terminal
	if [ "${TERM:-}" = "dumb" ]; then
		return 0
	fi

	return 1
}

##
# Prompt user for a text response
#
# Arguments:
#   --default="..."   Default text to use if no response is given
#
# Returns:
#   text as entered by user
#
# CHANGELOG:
#   2025.11.23 - Use is_noninteractive to handle non-interactive mode
#   2025.01.01 - Initial version
#
function prompt_text() {
	local DEFAULT=""
	local PROMPT="Enter some text"
	local RESPONSE=""

	while [ $# -ge 1 ]; do
		case $1 in
			--default=*) DEFAULT="${1#*=}";;
			*) PROMPT="$1";;
		esac
		shift
	done

	echo "$PROMPT" >&2
	echo -n '> : ' >&2

	if is_noninteractive; then
		# In non-interactive mode, return the default value
		echo $DEFAULT
		return
	fi

	read RESPONSE
	if [ "$RESPONSE" == "" ]; then
		echo "$DEFAULT"
	else
		echo "$RESPONSE"
	fi
}

##
# Prompt user for a yes or no response
#
# Arguments:
#   --invert            Invert the response (yes becomes 0, no becomes 1)
#   --default-yes       Default to yes if no response is given
#   --default-no        Default to no if no response is given
#   -q                  Quiet mode (no output text after response)
#
# Returns:
#   1 for yes, 0 for no (or inverted if --invert is set)
#
# CHANGELOG:
#   2025.12.16 - Add text output for non-interactive and empty responses
#   2025.11.23 - Use is_noninteractive to handle non-interactive mode
#   2025.11.09 - Add -q (quiet) option to suppress output after prompt (and use return value)
#   2025.01.01 - Initial version
#
function prompt_yn() {
	local TRUE=0 # Bash convention: 0 is success/true
	local YES=1
	local FALSE=1 # Bash convention: non-zero is failure/false
	local NO=0
	local DEFAULT="n"
	local DEFAULT_CODE=1
	local PROMPT="Yes or no?"
	local RESPONSE=""
	local QUIET=0

	while [ $# -ge 1 ]; do
		case $1 in
			--invert) YES=0; NO=1 TRUE=1; FALSE=0;;
			--default-yes) DEFAULT="y";;
			--default-no) DEFAULT="n";;
			-q) QUIET=1;;
			*) PROMPT="$1";;
		esac
		shift
	done

	echo "$PROMPT" >&2
	if [ "$DEFAULT" == "y" ]; then
		DEFAULT_TEXT="yes"
		DEFAULT="$YES"
		DEFAULT_CODE=$TRUE
		echo -n "> (Y/n): " >&2
	else
		DEFAULT_TEXT="no"
		DEFAULT="$NO"
		DEFAULT_CODE=$FALSE
		echo -n "> (y/N): " >&2
	fi

	if is_noninteractive; then
		# In non-interactive mode, return the default value
		echo "$DEFAULT_TEXT (default non-interactive)" >&2
		if [ $QUIET -eq 0 ]; then
			echo $DEFAULT
		fi
		return $DEFAULT_CODE
	fi

	read RESPONSE
	case "$RESPONSE" in
		[yY]*)
			if [ $QUIET -eq 0 ]; then
				echo $YES
			fi
			return $TRUE;;
		[nN]*)
			if [ $QUIET -eq 0 ]; then
				echo $NO
			fi
			return $FALSE;;
		"")
			echo "$DEFAULT_TEXT (default choice)" >&2
			if [ $QUIET -eq 0 ]; then
				echo $DEFAULT
			fi
			return $DEFAULT_CODE;;
		*)
			if [ $QUIET -eq 0 ]; then
				echo $DEFAULT
			fi
			return $DEFAULT_CODE;;
	esac
}
##
# Print a header message
#
# CHANGELOG:
#   2025.11.09 - Port from _common to bz_eval_tui
#   2024.12.25 - Initial version
#
function print_header() {
	local header="$1"
	echo "================================================================================"
	printf "%*s\n" $(((${#header}+80)/2)) "$header"
    echo ""
}

##
# Install UFW
#
function install_ufw() {
	if [ "$(os_like_rhel)" == 1 ]; then
		# RHEL/CentOS requires EPEL to be installed first
		package_install epel-release
	fi

	package_install ufw

	# Auto-enable a newly installed firewall
	ufw --force enable
	systemctl enable ufw
	systemctl start ufw

	# Auto-add the current user's remote IP to the whitelist (anti-lockout rule)
	local TTY_IP="$(who am i | awk '{print $NF}' | sed 's/[()]//g')"
	if [ -n "$TTY_IP" ]; then
		ufw allow from $TTY_IP comment 'Anti-lockout rule based on first install of UFW'
	fi
}
##
# Install the management script from the project's repo
#
# Expects the following variables:
#   GAME_USER    - User account to install the game under
#   GAME_DIR     - Directory to install the game into
#
# @param $1 Repo Name (e.g., user/repo)
# @param $2 Branch Name (default: main)
#
function install_warlock_manager() {
	print_header "Performing install_management"

	# Install management console and its dependencies
	local SRC=""
	local REPO="$1"
	local BRANCH="${2:-main}"

	SRC="https://raw.githubusercontent.com/${REPO}/refs/heads/${BRANCH}/dist/manage.py"

	if ! download "$SRC" "$GAME_DIR/manage.py"; then
		echo "Could not download management script!" >&2
		exit 1
	fi

	chown $GAME_USER:$GAME_USER "$GAME_DIR/manage.py"
	chmod +x "$GAME_DIR/manage.py"

	# Install configuration definitions
	cat > "$GAME_DIR/configs.yaml" <<EOF
config:
  - name: Server Name
    key: /ServerName
    default: "Hytale Server"
    type: str
    help: "Server name as displayed in server browsers."
  - name: Message of the Day
    key: /MOTD
    default: ""
    type: text
    help: "Message of the day displayed to players when they join the server."
  - name: Password
    key: /Password
    default: ""
    type: str
    help: "Password required to join the server. Leave blank for no password."
  - name: Max Players
    key: /MaxPlayers
    default: 100
    type: int
    help: "Maximum number of players allowed on the server."
  - name: Max View Radius
    key: /MaxViewRadius
    default: 32
    type: int
    help: "Maximum view radius for players in chunks."
  - name: World Name
    key: /Defaults/World
    default: "default"
    type: str
    help: "Name of the world to load or create."
  - name: Game Mode
    key: /Defaults/GameMode
    default: "Adventure"
    type: str
    help: "Default game mode for players."
    options:
      - Adventure
      - Creative
      - Survival
manager:
  - name: Game Branch
    section: Version
    key: game_branch
    type: str
    default: latest
    help: "The branch to use for the game server installation."
    options:
      - latest
      - pre-release
  - name: Delayed Shutdown Warning
    section: Messages
    key: shutdown_delayed
    type: str
    default: Server is shutting down in {time} minutes
    help: "Custom message broadcasted to players every 5 minutes before a delayed server shutdown.  Use '{time}' to replace with number of minutes remaining"
  - name: Delayed Restart Warning
    section: Messages
    key: restart_delayed
    type: str
    default: Server is restarting in {time} minutes
    help: "Custom message broadcasted to players every 5 minutes before a delayed server restart.  Use '{time}' to replace with number of minutes remaining"
  - name: Delayed Update Warning
    section: Messages
    key: update_delayed
    type: str
    default: Server is updating in {time} minutes
    help: "Custom message broadcasted to players every 5 minutes before a delayed server update.  Use '{time}' to replace with number of minutes remaining"
  - name: Shutdown Warning 5 Minutes
    section: Messages
    key: shutdown_5min
    type: str
    default: Server is shutting down in 5 minutes
    help: "Custom message broadcasted to players 5 minutes before server shutdown."
  - name: Shutdown Warning 4 Minutes
    section: Messages
    key: shutdown_4min
    type: str
    default: Server is shutting down in 4 minutes
    help: "Custom message broadcasted to players 4 minutes before server shutdown."
  - name: Shutdown Warning 3 Minutes
    section: Messages
    key: shutdown_3min
    type: str
    default: Server is shutting down in 3 minutes
    help: "Custom message broadcasted to players 3 minutes before server shutdown."
  - name: Shutdown Warning 2 Minutes
    section: Messages
    key: shutdown_2min
    type: str
    default: Server is shutting down in 2 minutes
    help: "Custom message broadcasted to players 2 minutes before server shutdown."
  - name: Shutdown Warning 1 Minute
    section: Messages
    key: shutdown_1min
    type: str
    default: Server is shutting down in 1 minute
    help: "Custom message broadcasted to players 1 minute before server shutdown."
  - name: Shutdown Warning 30 Seconds
    section: Messages
    key: shutdown_30sec
    type: str
    default: Server is shutting down in 30 seconds!
    help: "Custom message broadcasted to players 30 seconds before server shutdown."
  - name: Shutdown Warning NOW
    section: Messages
    key: shutdown_now
    type: str
    default: Server is shutting down NOW!
    help: "Custom message broadcasted to players immediately before server shutdown."
  - name: Instance Started (Discord)
    section: Discord
    key: instance_started
    type: str
    default: "{instance} has started! :rocket:"
    help: "Custom message sent to Discord when the server starts, use '{instance}' to insert the map name"
  - name: Instance Stopping (Discord)
    section: Discord
    key: instance_stopping
    type: str
    default: ":small_red_triangle_down: {instance} is shutting down"
    help: "Custom message sent to Discord when the server stops, use '{instance}' to insert the map name"
  - name: Discord Enabled
    section: Discord
    key: enabled
    type: bool
    default: false
    help: "Enables or disables Discord integration for server status updates."
  - name: Discord Webhook URL
    section: Discord
    key: webhook
    type: str
    help: "The webhook URL for sending server status updates to a Discord channel."
EOF
	chown $GAME_USER:$GAME_USER "$GAME_DIR/configs.yaml"

	# Most games use .settings.ini for manager settings
	touch "$GAME_DIR/.settings.ini"
	chown $GAME_USER:$GAME_USER "$GAME_DIR/.settings.ini"

	# If a pyenv is required:
	sudo -u $GAME_USER python3 -m venv "$GAME_DIR/.venv"
	sudo -u $GAME_USER "$GAME_DIR/.venv/bin/pip" install --upgrade pip
	sudo -u $GAME_USER "$GAME_DIR/.venv/bin/pip" install pyyaml
}


##
# Install OpenJDK from Eclipse Adoptium
#
# https://github.com/adoptium
#
# @arg $1 string OpenJDK version to install
#
# Will print the directory where OpenJDK was installed.
#
# CHANGELOG:
#   2026.01.13 - Initial version
#
function install_openjdk() {
	local VERSION="${1:-25}"

	# Validate version input
	if ! echo "$VERSION" | grep -E -q '^(8|11|16|17|18|19|20|21|22|23|24|25|26|27)$'; then
		echo "install_openjdk: Invalid OpenJDK version specified: $VERSION" >&2
		echo "Supported versions are: 8, 11, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27" >&2
		return 1
	fi

	if ! cmd_exists curl; then
		package_install curl
	fi

	# We will use this directory as a working directory for source files that need downloaded.
	[ -d /opt/script-collection ] || mkdir -p /opt/script-collection

	local DOWNLOAD_URL="$(curl https://api.github.com/repos/adoptium/temurin${VERSION}-binaries/releases/latest \
	  | grep browser_download_url \
	  | grep jre_x64_linux \
	  | grep 'tar\.gz"' \
	  | cut -d : -f 2,3 \
	  | tr -d \"\
	  | sed 's:\s*::')"

	local JDK_TGZ="$(basename "$DOWNLOAD_URL")"

	if ! download "$DOWNLOAD_URL" "/opt/script-collection/$JDK_TGZ" --no-overwrite; then
		echo "install_openjdk: Cannot download OpenJDK from ${DOWNLOAD_URL}!" >&2
		return 1
	fi

	local JDK_DIR="$(tar -zf "/opt/script-collection/$JDK_TGZ" --list | head -1)"

	if [ ! -e "/opt/script-collection/$JDK_DIR" ]; then
		tar -x -C /opt/script-collection/ -f "/opt/script-collection/$JDK_TGZ"
	fi

	echo "/opt/script-collection/$JDK_DIR"
}
##
# Add an "allow" rule to the firewall in the INPUT chain
#
# Arguments:
#   --port <port>       Port(s) to allow
#   --source <source>   Source IP to allow (default: any)
#   --zone <zone>       Zone to allow (default: public)
#   --tcp|--udp         Protocol to allow (default: tcp)
#   --proto <tcp|udp>   Protocol to allow (alternative method)
#   --comment <comment> (only UFW) Comment for the rule
#
# Specify multiple ports with `--port '#,#,#'` or a range `--port '#:#'`
#
# CHANGELOG:
#   2025.11.23 - Use return codes instead of exit to allow the caller to handle errors
#   2025.04.10 - Add "--proto" argument as alternative to "--tcp|--udp"
#
function firewall_allow() {
	# Defaults and argument processing
	local PORT=""
	local PROTO="tcp"
	local SOURCE="any"
	local FIREWALL=$(get_available_firewall)
	local ZONE="public"
	local COMMENT=""
	while [ $# -ge 1 ]; do
		case $1 in
			--port)
				shift
				PORT=$1
				;;
			--tcp|--udp)
				PROTO=${1:2}
				;;
			--proto)
				shift
				PROTO=$1
				;;
			--source|--from)
				shift
				SOURCE=$1
				;;
			--zone)
				shift
				ZONE=$1
				;;
			--comment)
				shift
				COMMENT=$1
				;;
			*)
				PORT=$1
				;;
		esac
		shift
	done

	if [ "$PORT" == "" -a "$ZONE" != "trusted" ]; then
		echo "firewall_allow: No port specified!" >&2
		return 2
	fi

	if [ "$PORT" != "" -a "$ZONE" == "trusted" ]; then
		echo "firewall_allow: Trusted zones do not use ports!" >&2
		return 2
	fi

	if [ "$ZONE" == "trusted" -a "$SOURCE" == "any" ]; then
		echo "firewall_allow: Trusted zones require a source!" >&2
		return 2
	fi

	if [ "$FIREWALL" == "ufw" ]; then
		if [ "$SOURCE" == "any" ]; then
			echo "firewall_allow/UFW: Allowing $PORT/$PROTO from any..."
			ufw allow proto $PROTO to any port $PORT comment "$COMMENT"
		elif [ "$ZONE" == "trusted" ]; then
			echo "firewall_allow/UFW: Allowing all connections from $SOURCE..."
			ufw allow from $SOURCE comment "$COMMENT"
		else
			echo "firewall_allow/UFW: Allowing $PORT/$PROTO from $SOURCE..."
			ufw allow from $SOURCE proto $PROTO to any port $PORT comment "$COMMENT"
		fi
		return 0
	elif [ "$FIREWALL" == "firewalld" ]; then
		if [ "$SOURCE" != "any" ]; then
			# Firewalld uses Zones to specify sources
			echo "firewall_allow/firewalld: Adding $SOURCE to $ZONE zone..."
			firewall-cmd --zone=$ZONE --add-source=$SOURCE --permanent
		fi

		if [ "$PORT" != "" ]; then
			echo "firewall_allow/firewalld: Allowing $PORT/$PROTO in $ZONE zone..."
			if [[ "$PORT" =~ ":" ]]; then
				# firewalld expects port ranges to be in the format of "#-#" vs "#:#"
				local DPORTS="${PORT/:/-}"
				firewall-cmd --zone=$ZONE --add-port=$DPORTS/$PROTO --permanent
			elif [[ "$PORT" =~ "," ]]; then
				# Firewalld cannot handle multiple ports all that well, so split them by the comma
				# and run the add command separately for each port
				local DPORTS="$(echo $PORT | sed 's:,: :g')"
				for P in $DPORTS; do
					firewall-cmd --zone=$ZONE --add-port=$P/$PROTO --permanent
				done
			else
				firewall-cmd --zone=$ZONE --add-port=$PORT/$PROTO --permanent
			fi
		fi

		firewall-cmd --reload
		return 0
	elif [ "$FIREWALL" == "iptables" ]; then
		echo "firewall_allow/iptables: WARNING - iptables is untested"
		# iptables doesn't natively support multiple ports, so we have to get creative
		if [[ "$PORT" =~ ":" ]]; then
			local DPORTS="-m multiport --dports $PORT"
		elif [[ "$PORT" =~ "," ]]; then
			local DPORTS="-m multiport --dports $PORT"
		else
			local DPORTS="--dport $PORT"
		fi

		if [ "$SOURCE" == "any" ]; then
			echo "firewall_allow/iptables: Allowing $PORT/$PROTO from any..."
			iptables -A INPUT -p $PROTO $DPORTS -j ACCEPT
		else
			echo "firewall_allow/iptables: Allowing $PORT/$PROTO from $SOURCE..."
			iptables -A INPUT -p $PROTO $DPORTS -s $SOURCE -j ACCEPT
		fi
		iptables-save > /etc/iptables/rules.v4
		return 0
	elif [ "$FIREWALL" == "none" ]; then
		echo "firewall_allow: No firewall detected" >&2
		return 1
	else
		echo "firewall_allow: Unsupported or unknown firewall" >&2
		echo 'Please report this at https://github.com/cdp1337/ScriptsCollection/issues' >&2
		return 1
	fi
}

print_header "$GAME_DESC *unofficial* Installer"

############################################
## Installer Actions
############################################

##
# Install the game server
#
# Expects the following variables:
#   GAME_USER    - User account to install the game under
#   GAME_DIR     - Directory to install the game into
#   STEAM_ID     - Steam App ID of the game
#   GAME_DESC    - Description of the game (for logging purposes)
#   GAME_SERVICE - Service name to install with Systemd
#   SAVE_DIR     - Directory to store game save files
#
function install_application() {
	print_header "Performing install_application"

	# Create the game user account
	# This will create the account with no password, so if you need to log in with this user,
	# run `sudo passwd $GAME_USER` to set a password.
	if [ -z "$(getent passwd $GAME_USER)" ]; then
		useradd -m -U $GAME_USER
	fi

	# Preliminary requirements
	package_install curl sudo python3-venv python3-pip unzip

	if [ "$FIREWALL" == "1" ]; then
		if [ "$(get_enabled_firewall)" == "none" ]; then
			# No firewall installed, go ahead and install UFW
			install_ufw
		fi
	fi

	[ -e "$GAME_DIR/AppFiles" ] || sudo -u $GAME_USER mkdir -p "$GAME_DIR/AppFiles"

	# Hytale requires Java and recommends JRE 25.x, so manually install it so we can ensure compatibility.
	local JAVA_PATH="$(install_openjdk 25)"

	# They also ship their own downloader, so grab that too
	download https://downloader.hytale.com/hytale-downloader.zip "$GAME_DIR/AppFiles/hytale-downloader.zip"
	unzip -o "$GAME_DIR/AppFiles/hytale-downloader.zip" -d "$GAME_DIR/AppFiles/"

	# At the moment Hytale requires authentication to download the server files,
	# so we must install the game binary here vs inside the management console.
	cd "$GAME_DIR/AppFiles/"
	echo ""
	echo ""
	echo "====================================================="
	echo ""
	echo " IMPORTANT: Hytale Server Requires Authentication! "
	echo ""
	echo "====================================================="
	echo ""
	echo "You may be prompted to open a URL in your web browser to"
	echo "authenticate your server."
	echo ""
	echo "Please open the link and authenticate if prompted."
	./hytale-downloader-linux-amd64 -print-version
	cd -
	chown -R $GAME_USER:$GAME_USER "$GAME_DIR/AppFiles/"

	
	# Install the management script
	install_warlock_manager "$REPO" "$BRANCH"

	# If other PIP packages are required for your management interface,
	# add them here as necessary, for example for RCON support:
	#  sudo -u $GAME_USER $GAME_DIR/.venv/bin/pip install rcon

	# Set the requested game branch for the manager to use
	sudo -u $GAME_USER $GAME_DIR/manage.py --set-config "Game Branch" "$GAME_BRANCH"

	# Install installer (this script) for uninstallation or manual work
	download "https://raw.githubusercontent.com/${REPO}/refs/heads/${BRANCH}/dist/installer.sh" "$GAME_DIR/installer.sh"
	chmod +x "$GAME_DIR/installer.sh"
	chown $GAME_USER:$GAME_USER "$GAME_DIR/installer.sh"
	
	# Use the management script to install the game server
	if ! $GAME_DIR/manage.py --update; then
		echo "Could not install $GAME_DESC, exiting" >&2
		exit 1
	fi

	firewall_allow --port 5520 --udp --comment "${GAME_DESC} Game Port"

	# Install system service file to be loaded by systemd
    cat > /etc/systemd/system/${GAME_SERVICE}.service <<EOF
[Unit]
# DYNAMICALLY GENERATED FILE! Edit at your own risk
Description=$GAME_DESC
After=network.target

[Service]
Type=simple
LimitNOFILE=10000
User=$GAME_USER
Group=$GAME_USER
Sockets=$GAME_SERVICE.socket
StandardInput=socket
StandardOutput=journal
StandardError=journal
WorkingDirectory=$GAME_DIR/AppFiles
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u $GAME_USER)
ExecStart=${JAVA_PATH}bin/java -server -Xms1024M -Xmx16G -XX:MaxMetaspaceSize=512M -XX:+UnlockExperimentalVMOptions -XX:+UseShenandoahGC -XX:ShenandoahGCHeuristics=compact -XX:ShenandoahUncommitDelay=30000 -XX:ShenandoahAllocationThreshold=15 -XX:ShenandoahGuaranteedGCInterval=30000 -XX:+PerfDisableSharedMem -XX:+DisableExplicitGC -XX:+ParallelRefProcEnabled -XX:ParallelGCThreads=4 -XX:ConcGCThreads=2 -XX:+AlwaysPreTouch -jar $GAME_DIR/AppFiles/Server/HytaleServer.jar --assets $GAME_DIR/AppFiles/Assets.zip --accept-early-plugins
ExecStop=$GAME_DIR/manage.py --pre-stop --service ${GAME_SERVICE}
ExecStartPost=$GAME_DIR/manage.py --post-start --service ${GAME_SERVICE}
Restart=on-failure
RestartSec=1800s
TimeoutStartSec=600s

[Install]
WantedBy=multi-user.target
EOF
	cat > /etc/systemd/system/${GAME_SERVICE}.socket <<EOF
[Unit]
# DYNAMICALLY GENERATED FILE! Edit at your own risk
BindsTo=$GAME_SERVICE.service

[Socket]
ListenFIFO=/var/run/$GAME_SERVICE.socket
Service=$GAME_SERVICE.service
RemoveOnStop=true
SocketMode=0660
SocketUser=$GAME_USER
User=$GAME_USER
Group=$GAME_USER
EOF
    systemctl daemon-reload

	if [ -n "$WARLOCK_GUID" ]; then
		# Register Warlock
		[ -d "/var/lib/warlock" ] || mkdir -p "/var/lib/warlock"
		echo -n "$GAME_DIR" > "/var/lib/warlock/${WARLOCK_GUID}.app"
	fi
}

function postinstall() {
	print_header "Performing postinstall"

	# First run setup
	$GAME_DIR/manage.py --first-run
}

##
# Uninstall the game server
#
# Expects the following variables:
#   GAME_DIR     - Directory where the game is installed
#   GAME_SERVICE - Service name used with Systemd
#   SAVE_DIR     - Directory where game save files are stored
#
function uninstall_application() {
	print_header "Performing uninstall_application"

	systemctl disable $GAME_SERVICE
	systemctl stop $GAME_SERVICE

	# Service files
	[ -e "/etc/systemd/system/${GAME_SERVICE}.service" ] && rm "/etc/systemd/system/${GAME_SERVICE}.service"

	# Game files
	[ -d "$GAME_DIR" ] && rm -rf "$GAME_DIR/AppFiles"

	# Management scripts
	[ -e "$GAME_DIR/manage.py" ] && rm "$GAME_DIR/manage.py"
	[ -e "$GAME_DIR/configs.yaml" ] && rm "$GAME_DIR/configs.yaml"
	[ -d "$GAME_DIR/.venv" ] && rm -rf "$GAME_DIR/.venv"

	if [ -n "$WARLOCK_GUID" ]; then
		# unregister Warlock
		[ -e "/var/lib/warlock/${WARLOCK_GUID}.app" ] && rm "/var/lib/warlock/${WARLOCK_GUID}.app"
	fi
}

############################################
## Pre-exec Checks
############################################

if [ $MODE_UNINSTALL -eq 1 ]; then
	MODE="uninstall"
else
	# Default to install mode
	MODE="install"
fi


if systemctl -q is-active $GAME_SERVICE; then
	echo "$GAME_DESC service is currently running, please stop it before running this installer."
	echo "You can do this with: sudo systemctl stop $GAME_SERVICE"
	exit 1
fi

if [ -n "$OVERRIDE_DIR" ]; then
	# User requested to change the install dir!
	# This changes the GAME_DIR from the default location to wherever the user requested.
	if [ -e "/var/lib/warlock/${WARLOCK_GUID}.app" ] ; then
		# Check for existing installation directory based on Warlock registration
		GAME_DIR="$(cat "/var/lib/warlock/${WARLOCK_GUID}.app")"
		if [ "$GAME_DIR" != "$OVERRIDE_DIR" ]; then
			echo "ERROR: $GAME_DESC already installed in $GAME_DIR, cannot override to $OVERRIDE_DIR" >&2
			echo "If you want to move the installation, please uninstall first and then re-install to the new location." >&2
			exit 1
		fi
	fi

	GAME_DIR="$OVERRIDE_DIR"
	echo "Using ${GAME_DIR} as the installation directory based on explicit argument"
elif [ -e "/var/lib/warlock/${WARLOCK_GUID}.app" ]; then
	# Check for existing installation directory based on service file
	GAME_DIR="$(cat "/var/lib/warlock/${WARLOCK_GUID}.app")"
	echo "Detected installation directory of ${GAME_DIR} based on service registration"
else
	echo "Using default installation directory of ${GAME_DIR}"
fi

if [ -e "/etc/systemd/system/${GAME_SERVICE}.service" ]; then
	EXISTING=1
else
	EXISTING=0
fi

############################################
## Installer
############################################


if [ "$MODE" == "install" ]; then

	if [ $SKIP_FIREWALL -eq 1 ]; then
		FIREWALL=0
	elif [ $EXISTING -eq 0 ] && prompt_yn -q --default-yes "Install system firewall?"; then
		FIREWALL=1
	else
		FIREWALL=0
	fi

	install_application

	postinstall

	# Print some instructions and useful tips
    print_header "$GAME_DESC Installation Complete"
fi

if [ "$MODE" == "uninstall" ]; then
	if [ $NONINTERACTIVE -eq 0 ]; then
		if prompt_yn -q --invert --default-no "This will remove all game binary content"; then
			exit 1
		fi
		if prompt_yn -q --invert --default-no "This will remove all player and map data"; then
			exit 1
		fi
	fi

	if prompt_yn -q --default-yes "Perform a backup before everything is wiped?"; then
		$GAME_DIR/manage.py --backup
	fi

	uninstall_application
fi
