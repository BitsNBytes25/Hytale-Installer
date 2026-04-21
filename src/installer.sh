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
#   MODE_UNINSTALL=--uninstall - Perform an uninstallation
#   OVERRIDE_DIR=--dir=<src> - Use a custom installation directory instead of the default (optional)
#   SKIP_FIREWALL=--skip-firewall - Do not install or configure a system firewall
#   NONINTERACTIVE=--non-interactive - Run the installer in non-interactive mode (useful for scripted installs)
#   GAME_BRANCH=--game-branch=<latest|pre-release> - Specify a specific branch of the game server to install DEFAULT=latest
#   BRANCH=--branch=<str> - Use a specific branch of the management script repository DEFAULT=main
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

# compile:usage
# compile:argparse
# scriptlet:_common/require_root.sh
# scriptlet:_common/get_firewall.sh
# scriptlet:_common/package_install.sh
# scriptlet:_common/download.sh
# scriptlet:bz_eval_tui/prompt_text.sh
# scriptlet:bz_eval_tui/prompt_yn.sh
# scriptlet:bz_eval_tui/print_header.sh
# scriptlet:_common/firewall_install.sh
# scriptlet:warlock/install_warlock_manager.sh
# scriptlet:openjdk/install.sh

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

		[ -e "$GAME_DIR/Configs" ] || sudo -u $GAME_USER mkdir -p "$GAME_DIR/Configs"
		[ -e "$GAME_DIR/Packages" ] || sudo -u $GAME_USER mkdir -p "$GAME_DIR/Packages"

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