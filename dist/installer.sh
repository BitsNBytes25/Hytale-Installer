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
		--uninstall) MODE_UNINSTALL=1;;
		--dir=*|--dir)
			[ "$1" == "--dir" ] && shift 1 && OVERRIDE_DIR="$1" || OVERRIDE_DIR="${1#*=}"
			[ "${OVERRIDE_DIR:0:1}" == "'" ] && [ "${OVERRIDE_DIR:0-1}" == "'" ] && OVERRIDE_DIR="${OVERRIDE_DIR:1:-1}"
			[ "${OVERRIDE_DIR:0:1}" == '"' ] && [ "${OVERRIDE_DIR:0-1}" == '"' ] && OVERRIDE_DIR="${OVERRIDE_DIR:1:-1}"
			;;
		--skip-firewall) SKIP_FIREWALL=1;;
		--non-interactive) NONINTERACTIVE=1;;
		--game-branch=*|--game-branch)
			[ "$1" == "--game-branch" ] && shift 1 && GAME_BRANCH="$1" || GAME_BRANCH="${1#*=}"
			[ "${GAME_BRANCH:0:1}" == "'" ] && [ "${GAME_BRANCH:0-1}" == "'" ] && GAME_BRANCH="${GAME_BRANCH:1:-1}"
			[ "${GAME_BRANCH:0:1}" == '"' ] && [ "${GAME_BRANCH:0-1}" == '"' ] && GAME_BRANCH="${GAME_BRANCH:1:-1}"
			;;
		--branch=*|--branch)
			[ "$1" == "--branch" ] && shift 1 && BRANCH="$1" || BRANCH="${1#*=}"
			[ "${BRANCH:0:1}" == "'" ] && [ "${BRANCH:0-1}" == "'" ] && BRANCH="${BRANCH:1:-1}"
			[ "${BRANCH:0:1}" == '"' ] && [ "${BRANCH:0-1}" == '"' ] && BRANCH="${BRANCH:1:-1}"
			;;
		-h|--help) usage;;
		*) echo "Unknown argument: $1" >&2; usage;;
	esac
	shift 1
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
# Install firewalld
#
# CHANGELOG:
#   2026.03.16 - Switch awk to use $NF for better support
#
function install_firewalld() {
	package_install firewalld

	# Auto-add the current user's remote IP to the whitelist (anti-lockout rule)
	local TTY_IP="$(who am i | awk '{print $NF}' | sed 's/[()]//g')"
	if [ -n "$TTY_IP" ]; then
		# Anti-lockout rule based on first install of firewalld
		firewall-cmd --zone=trusted --add-source=$TTY_IP --permanent
	fi
}

##
# Install the system default firewall based on the OS type
#
# For Debian/Ubuntu, this installs UFW
# For RHEL/CentOS, this installs firewalld
# For SUSE, this installs firewalld
# For other OS types, this defaults to installing UFW
#
function firewall_install() {
	local FIREWALL

	FIREWALL=$(get_available_firewall)
	if [ "$FIREWALL" != "none" ]; then
		return
	fi

	if os_like_debian -q; then
		install_ufw
	elif os_like_rhel -q; then
		install_firewalld
	elif os_like_suse -q; then
		install_firewalld
	else
		install_ufw
	fi
}
##
# Install the management script from the project's repo
#
# Expects the following variables:
#   GAME_USER    - User account to install the game under
#   GAME_DIR     - Directory to install the game into
#   WARLOCK_GUID - Warlock GUID for this game
#
# @param $1 Application Repo Name (e.g., user/repo)
# @param $2 Application Branch Name (default: main)
# @param $3 Warlock Manager Branch to use (default: release-v2)
#
# CHANGELOG:
#   20260326 - Add support for full version strings
#   20260325 - Update to install warlock-manager from PyPI if a version number is specified instead of a branch name
#   20260319 - Add third option to specify the version of Warlock Manager to use as the base
#   20260301 - Update to install warlock-manager from github (along with its dependencies) as a pip package
#
function install_warlock_manager() {
	print_header "Performing install_management"

	# Install management console and its dependencies

	# Source URL to download the application from
	local SRC=""
	# Github repository of the source application
	local REPO="$1"
	# Branch of the source application to download from (default: main)
	local BRANCH="${2:-main}"
	# Branch of Warlock Manager to install (default: release-v2)
	local MANAGER_BRANCH="${3:-release-v2}"
	local MANAGER_SOURCE
	local MANAGER_SHA

	if [[ "$MANAGER_BRANCH" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		# Support 1.2.3 version strings; indicates at least .3 of the revision.
		MANAGER_SOURCE="pip"
		MANAGER_BRANCH=">=${MANAGER_BRANCH},<=$(echo $MANAGER_BRANCH | sed 's:\.[0-9]*$:.9999:')"
	elif [[ "$MANAGER_BRANCH" =~ ^[0-9]+\.[0-9]+$ ]]; then
		# Support 1.2 version strings; indicates it just must be within this API version
        MANAGER_SOURCE="pip"
        MANAGER_BRANCH=">=${MANAGER_BRANCH}.0,<=${MANAGER_BRANCH}.9999"
    else
    	# Not a version string, probably a branch name instead.
        MANAGER_SOURCE="github"
    fi

	SRC="https://raw.githubusercontent.com/${REPO}/refs/heads/${BRANCH}/dist/manage.py"

	if ! download "$SRC" "$GAME_DIR/manage.py"; then
		echo "Could not download management script!" >&2
		exit 1
	fi

	chown $GAME_USER:$GAME_USER "$GAME_DIR/manage.py"
	chmod +x "$GAME_DIR/manage.py"

	# Record the hash of the install and branch name for display in the management UI and checking for updates.
	# We use the direct hash because installation scripts may not necessarily use tagged versions.
	MANAGER_SHA="$(curl -s "https://api.github.com/repos/${REPO}/commits/${BRANCH}" \
        | grep '"sha":' \
        | head -n 1 \
        | sed -E 's/.*"sha": *"([^"]+)".*/\1/')"

	# Record this hash along with the branch into a file accessible by the manager.
	# This will be read by the Python, so JSON is fine.
	cat > "$GAME_DIR/.manage.json" <<EOF
{
	"source": "github",
	"repo": "${REPO}",
	"branch": "${BRANCH}",
	"commit": "${MANAGER_SHA}",
	"game": "${WARLOCK_GUID}"
}
EOF
	chown $GAME_USER:$GAME_USER "$GAME_DIR/.manage.json"

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
service:
  - name: Game Branch
    section: Version
    key: game_branch
    type: str
    default: latest
    help: "The branch to use for the game server installation."
    options:
      - latest
      - pre-release
    group: Settings
  - name: Authentication Mode
    section: JarParams
    key: auth-mode
    type: str
    options:
      - authenticated
      - offline
      - insecure
    default: authenticated
    group: Settings
  - name: Bind Port
    section: JarParams
    key: bind
    type: int
    default: 5520
    group: Settings
  - name: Accept Early Plugins
    section: JarParams
    key: accept-early-plugins
    type: bool
    default: true
    group: Settings
  - name: Java Initial Heap Size
    section: JavaParams
    key: Xms
    type: str
    default: 1024M
    group: Settings
  - name: Java Maximum Heap Size
    section: JavaParams
    key: Xmx
    type: str
    default: 16G
    group: Settings
manager:
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

	# A python virtual environment is now required by Warlock-based managers.
	sudo -u $GAME_USER python3 -m venv "$GAME_DIR/.venv"
	sudo -u $GAME_USER "$GAME_DIR/.venv/bin/pip" install --upgrade pip
	if [ "$MANAGER_SOURCE" == "pip" ]; then
		# Install from PyPI with version specifier
		sudo -u $GAME_USER "$GAME_DIR/.venv/bin/pip" install "warlock-manager${MANAGER_BRANCH}"
	else
		# Install directly from GitHub
		sudo -u $GAME_USER "$GAME_DIR/.venv/bin/pip" install warlock-manager@git+https://github.com/BitsNBytes25/Warlock-Manager.git@$MANAGER_BRANCH
	fi

	# Ensure warlock lib directory exists for supplemental data
	[ -d "/var/lib/warlock" ] || mkdir -p "/var/lib/warlock"
	[ -e /var/lib/warlock/.auth ] || touch /var/lib/warlock/.auth
    # Ensure it's a valid 64-character hash
    if [ "$(cat /var/lib/warlock/.auth | wc -c)" != "64" ]; then
    	cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 64 | head -n 1 | tr -d '\n' > "/var/lib/warlock/.auth"
    fi
	[ -e "/var/lib/warlock/.email" ] || touch /var/lib/warlock/.email
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
#   2026.04.13 - Mute curl output
#   2026.03.07 - Bugfix to fix 'path-jre//bin/java'
#   2026.03.05 - Add support for update-alternatives / alternatives.
#   2026.03.03 - Bugfix, return the correct JDK directory.
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

	local DOWNLOAD_URL="$(curl -s https://api.github.com/repos/adoptium/temurin${VERSION}-binaries/releases/latest \
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
	# Remove any trailing '/'
	JDK_DIR="${JDK_DIR%/}"

	if [ ! -e "/opt/script-collection/$JDK_DIR" ]; then
		tar -x -C /opt/script-collection/ -f "/opt/script-collection/$JDK_TGZ"
	fi

	# Update distro registrations for alternative software.
	if os_like debian; then
		update-alternatives --install "/usr/bin/java" "java" "/opt/script-collection/$JDK_DIR/bin/java" 1
	elif os_like rhel; then
		alternatives --install "/usr/bin/java" "java" "/opt/script-collection/$JDK_DIR/bin/java" 1
	elif os_like suse; then
		update-alternatives --install "/usr/bin/java" "java" "/opt/script-collection/$JDK_DIR/bin/java" 1
	fi

	echo "/opt/script-collection/$JDK_DIR"
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

	# Ensure the target directory exists and is owned by the game user
	if [ ! -d "$GAME_DIR" ]; then
		mkdir -p "$GAME_DIR"
		chown $GAME_USER:$GAME_USER "$GAME_DIR"
	fi

	# Preliminary requirements
	package_install curl sudo python3-venv python3-pip unzip

	if [ "$FIREWALL" == "1" ]; then
		if [ "$(get_enabled_firewall)" == "none" ]; then
			# No firewall installed, go ahead and install UFW
			firewall_install
		fi
	fi

	[ -e "$GAME_DIR/AppFiles" ] || sudo -u $GAME_USER mkdir -p "$GAME_DIR/AppFiles"
	[ -e "$GAME_DIR/Configs" ] || sudo -u $GAME_USER mkdir -p "$GAME_DIR/Configs"
	[ -e "$GAME_DIR/Packages" ] || sudo -u $GAME_USER mkdir -p "$GAME_DIR/Packages"

	# Hytale requires Java and recommends JRE 25.x, so manually install it so we can ensure compatibility.
	install_openjdk 25
	
	# Install the management script
	install_warlock_manager "$REPO" "$BRANCH" 2.2.6

	# Install installer (this script) for uninstallation or manual work
	download "https://raw.githubusercontent.com/${REPO}/refs/heads/${BRANCH}/dist/installer.sh" "$GAME_DIR/installer.sh"
	chmod +x "$GAME_DIR/installer.sh"
	chown $GAME_USER:$GAME_USER "$GAME_DIR/installer.sh"

	if [ -n "$WARLOCK_GUID" ]; then
		# Register Warlock
		[ -d "/var/lib/warlock" ] || mkdir -p "/var/lib/warlock"
		echo -n "$GAME_DIR" > "/var/lib/warlock/${WARLOCK_GUID}.app"
	fi
}

function postinstall() {
	print_header "Performing postinstall"

	# First run setup
	$GAME_DIR/manage.py first-run
}

##
# Upgrade logic for 1.0 to 2.2 to handle migration of ENV and overrides
#
function upgrade_application_1_0() {
	local LEGACY_SERVICE="hytale-server"
	local SERVICE_PATH="/etc/systemd/system/${LEGACY_SERVICE}.service"

	# Migrate existing service to new format
	# This gets overwrote by the manager, but is needed to tell the system that the service is here.
	if [ -e "${SERVICE_PATH}" ] && [ ! -e "$GAME_DIR/Environments" ]; then
		sudo -u $GAME_USER mkdir -p "$GAME_DIR/Environments"
		# Extract out current environment variables from the systemd file into their own dedicated file
		egrep '^Environment' "${SERVICE_PATH}" | sed 's:^Environment=::' > "$GAME_DIR/Environments/${LEGACY_SERVICE}.env"
		chown $GAME_USER:$GAME_USER "$GAME_DIR/Environments/${LEGACY_SERVICE}.env"
		# Trim out those envs now that they're not longer required
		cat "${SERVICE_PATH}" | egrep -v '^Environment=' > "${SERVICE_PATH}.new"
		mv "${SERVICE_PATH}.new" "${SERVICE_PATH}"

		if [ -e "${SERVICE_PATH}.d" ] && [ -e "${SERVICE_PATH}.d/override.conf" ]; then
			# If there is an override, (used in version 1.0),
			# grab the CLI and move it to a notes document so the operator can manually review it.
			touch "$GAME_DIR/Notes.txt"
			echo "    !! IMPORTANT - Service commands are now generated dynamically, " >> "$GAME_DIR/Notes.txt"
			echo "    so please manually migrate the following CLI options to your game." >> "$GAME_DIR/Notes.txt"
			echo "" >> "$GAME_DIR/Notes.txt"
			egrep '^ExecStart=' "${SERVICE_PATH}.d/override.conf" >> "$GAME_DIR/Notes.txt"
			chown $GAME_USER:$GAME_USER "$GAME_DIR/Notes.txt"
			rm -fr "${SERVICE_PATH}.d/override.conf"
			rm -fr "${SERVICE_PATH}.d"
		fi
	fi
}

##
# Upgrade handler for 2.1 to 2.2
function upgrade_application_2_1() {
	if [ -e "$GAME_DIR/AppFiles/Server/HytaleServer.jar" ]; then

		# 2.2 introduces multi-binary support for game servers, so if the server is present in the legacy path,
		# move it to its new destination.
		[ -d "$GAME_DIR/AppFiles/hytale-server" ] || mkdir -p "$GAME_DIR/AppFiles/hytale-server"
		mv "$GAME_DIR/AppFiles/Server" "$GAME_DIR/AppFiles/hytale-server/"
		[ -d "$GAME_DIR/AppFiles/logs" ] && mv "$GAME_DIR/AppFiles/logs" "$GAME_DIR/AppFiles/hytale-server/"
		[ -d "$GAME_DIR/AppFiles/mods" ] && mv "$GAME_DIR/AppFiles/mods" "$GAME_DIR/AppFiles/hytale-server/"
		[ -d "$GAME_DIR/AppFiles/universe" ] && mv "$GAME_DIR/AppFiles/universe" "$GAME_DIR/AppFiles/hytale-server/"
		[ -e "$GAME_DIR/AppFiles/Assets.zip" ] && mv "$GAME_DIR/AppFiles/Assets.zip" "$GAME_DIR/AppFiles/hytale-server/Assets.zip"
		[ -e "$GAME_DIR/AppFiles/auth.enc" ] && [ ! -e "$GAME_DIR/Configs/auth.enc" ] && cp "$GAME_DIR/AppFiles/auth.enc" "$GAME_DIR/Configs/auth.enc"
		[ -e "$GAME_DIR/AppFiles/auth.enc" ] && mv "$GAME_DIR/AppFiles/auth.enc" "$GAME_DIR/AppFiles/hytale-server/auth.enc"
		[ -e "$GAME_DIR/AppFiles/bans.json" ] && mv "$GAME_DIR/AppFiles/bans.json" "$GAME_DIR/AppFiles/hytale-server/bans.json"
		[ -e "$GAME_DIR/AppFiles/config.json" ] && mv "$GAME_DIR/AppFiles/config.json" "$GAME_DIR/AppFiles/hytale-server/config.json"
		[ -e "$GAME_DIR/AppFiles/permissions.json" ] && mv "$GAME_DIR/AppFiles/permissions.json" "$GAME_DIR/AppFiles/hytale-server/permissions.json"
		[ -e "$GAME_DIR/AppFiles/whitelist.json" ] && mv "$GAME_DIR/AppFiles/whitelist.json" "$GAME_DIR/AppFiles/hytale-server/whitelist.json"
		[ -e "$GAME_DIR/AppFiles/universe.tgz" ] && mv "$GAME_DIR/AppFiles/universe.tgz" "$GAME_DIR/AppFiles/hytale-server/universe.tgz"

		# Move update zips to the Packages directory
		for pkg in "$GAME_DIR/AppFiles/"*.zip; do
			file="$(basename $pkg)"
			if [ "$file" != "*.zip" ]; then
				mv "$GAME_DIR/AppFiles/$file" "$GAME_DIR/Packages/$file"
			fi
		done

		# Move the updater to the Packages directory
		[ -e "$GAME_DIR/AppFiles/hytale-downloader-linux-amd64" ] && mv "$GAME_DIR/AppFiles/hytale-downloader-linux-amd64" "$GAME_DIR/Packages/hytale-downloader-linux-amd64"
		[ -e "$GAME_DIR/AppFiles/hytale-downloader-windows-amd64.exe" ] && mv "$GAME_DIR/AppFiles/hytale-downloader-windows-amd64.exe" "$GAME_DIR/Packages/hytale-downloader-windows-amd64.exe"

		# Chown everything to the appropriate user
		chown $GAME_USER:$GAME_USER "$GAME_DIR/AppFiles" -R
		chown $GAME_USER:$GAME_USER "$GAME_DIR/Packages" -R
		chown $GAME_USER:$GAME_USER "$GAME_DIR/Configs" -R
	fi
}

##
# Perform any steps necessary for upgrading an existing installation.
#
function upgrade_application() {
	print_header "Existing installation detected, performing upgrade"

	# Uncomment if you need this
	upgrade_application_1_0
	upgrade_application_2_1
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

	$GAME_DIR/manage.py remove --confirm

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
elif [ -e "$GAME_DIR/AppFiles" ]; then
	MODE="reinstall"
else
	# Default to install mode
	MODE="install"
fi


if [ -e "$GAME_DIR/Environments" ]; then
	# Check for existing service files to determine if the service is running.
	# This is important to prevent conflicts with the installer trying to modify files while the service is running.
	for envfile in "$GAME_DIR/Environments/"*.env; do
		SERVICE=$(basename "$envfile" .env)
		# If there are no services, this will just be '*.env'.
		if [ "$SERVICE" != "*" ]; then
			if systemctl -q is-active $SERVICE; then
				echo "$GAME_DESC service is currently running, please stop all instances before running this installer."
				echo "You can do this with: sudo systemctl stop $SERVICE"
				exit 1
			fi
		fi
	done
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

# Operations needed to be performed during a reinstallation / upgrade
if [ "$MODE" == "reinstall" ]; then

	FIREWALL=0

	upgrade_application

	install_application

	postinstall

	# Print some instructions and useful tips
    print_header "$GAME_DESC Installation Complete"

	# If there are notes generated during installation, print them now.
    if [ -e "$GAME_DIR/Notes.txt" ]; then
    	cat "$GAME_DIR/Notes.txt"
	fi
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
		$GAME_DIR/manage.py backup
	fi

	uninstall_application
fi

}