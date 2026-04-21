#!/usr/bin/env python3
import os
import sys
# Include the virtual environment site-packages in sys.path
here = os.path.dirname(os.path.realpath(__file__))
if not os.path.exists(os.path.join(here, '.venv')):
	print('Python environment not setup')
	exit(1)
sys.path.insert(
	0,
	os.path.join(
		here,
		'.venv',
		'lib',
		'python' + '.'.join(sys.version.split('.')[:2]), 'site-packages'
	)
)
import logging
import re
import shutil
import time
import json
import zipfile
from warlock_manager.apps.base_app import BaseApp
from warlock_manager.libs.java import find_java_version
from warlock_manager.services.socket_service import SocketService
from warlock_manager.config.ini_config import INIConfig
from warlock_manager.config.json_config import JSONConfig
from warlock_manager.config.properties_config import PropertiesConfig
from warlock_manager.libs.app_runner import app_runner
from warlock_manager.libs.firewall import Firewall
from warlock_manager.libs import utils
from warlock_manager.libs.download import download_file
from warlock_manager.libs.cmd import Cmd, PipeCmd
from warlock_manager.formatters.cli_formatter import cli_formatter
from warlock_manager.mods.warlock_nexus_mod import WarlockNexusMod
# To allow running as a standalone script without installing the package, include the venv path for imports.
# This will set the include path for this path to .venv to allow packages installed therein to be utilized.
#
# IMPORTANT - any imports that are needed for the script to run must be after this,
# otherwise the imports will fail when running as a standalone script.


# Import the appropriate type of handler for the game installer.
# Common options are:
# from warlock_manager.apps.steam_app import SteamApp

# Import the appropriate type of handler for the game services.
# Common options are:
# from warlock_manager.services.base_service import BaseService
# from warlock_manager.services.rcon_service import RCONService
# from warlock_manager.services.http_service import HTTPService

# Import the various configuration handlers used by this game.
# Common options are:
# from warlock_manager.config.cli_config import CLIConfig
# from warlock_manager.config.unreal_config import UnrealConfig

# Load the application runner responsible for interfacing with CLI arguments
# and providing default functionality for running the manager.

# If your script manages the firewall, (recommended), import the Firewall library

# Utilities provided by Warlock that are common to many applications

# This game requires manually download assets

# Useful in some games

# Select the baseline for mod support
# from warlock_manager.mods.base_mod import BaseMod


class GameMod(WarlockNexusMod):
	pass


class GameApp(BaseApp):
	"""
	Game application manager
	"""

	def __init__(self):
		super().__init__()

		self.name = 'Hytale'
		self.desc = 'Hytale Dedicated Server'
		self.multi_binary = True
		self.service_handler = GameService
		self.mod_handler = GameMod
		self.service_prefix = 'hytale-'

		# Use this to mark certain features as disabled in this game manager
		# self.disabled_features = {'api'}

		self.configs = {
			'manager': INIConfig('manager', os.path.join(utils.get_base_directory(), '.settings.ini'))
		}
		self.load()

	def first_run(self) -> bool:
		if os.geteuid() != 0:
			print('ERROR: Please run this script with sudo to perform first-run configuration.')
			return False

		super().first_run()
		utils.makedirs(os.path.join(utils.get_app_directory(), 'Configs'))

		services = self.get_services()
		if len(services) == 0:
			# No services configured, create the first one
			logging.info('No services detected, creating one...')
			self.create_service('hytale-server')

			svc = self.get_services()[0]
			print('=================================')
			print('NOTICE: You must authenticate with Hytale during server start!')
			print('')
			print('Starting service once to allow authentication, please wait...')
			svc.start()
			auth_requested = False

			def watcher(line):
				nonlocal auth_requested
				if 'Authentication successful' in line:
					print('Authentication successful!')
					# Save the token to an encrypted file so we don't have to do this BS again
					svc.write_socket('/auth persistence Encrypted')
					return True
				elif 'No server tokens configured. Use /auth login to authenticate.' in line:
					svc.write_socket('/auth login device')
					auth_requested = True
				elif auth_requested:
					print(line)
			svc.watch(watcher)
			time.sleep(2)
			svc.stop()

			# If the auth token is set after game creation, (probable if performed during installation),
			# Copy that token to the application so it can be re-used.
			service_token = os.path.join(svc.get_app_directory(), 'auth.enc')
			app_token = os.path.join(utils.get_base_directory(), 'Configs', 'auth.enc')
			if os.path.exists(service_token):
				shutil.copy2(service_token, app_token)
				utils.ensure_file_ownership(app_token)
		else:
			for svc in services:
				# Ensure the services are ready to run.
				service_token = os.path.join(svc.get_app_directory(), 'auth.enc')
				app_token = os.path.join(utils.get_base_directory(), 'Configs', 'auth.enc')
				if os.path.exists(app_token) and not os.path.exists(service_token):
					shutil.copy2(app_token, service_token)
					utils.ensure_file_ownership(service_token)
				svc.build_systemd_config()
				svc.build_systemd_socket()

		return True


class GameService(SocketService):
	"""
	Service definition and handler
	"""
	def __init__(self, service: str, game: GameApp):
		"""
		Initialize and load the service definition
		:param file:
		"""
		super().__init__(service, game)
		self.configs = {
			'config': JSONConfig('config', os.path.join(self.get_app_directory(), 'config.json')),
			'service': INIConfig('service', os.path.join(utils.get_base_directory(), 'Configs', 'service.%s.ini' % self.service)),
		}
		self.load()

	def create_service(self):
		"""
		Create the systemd service for this game, including the service file and environment file
		:return:
		"""
		super().create_service()

		# If there is a token from the application, copy that over to this service too.
		service_token = os.path.join(self.get_app_directory(), 'auth.enc')
		app_token = os.path.join(utils.get_base_directory(), 'Configs', 'auth.enc')
		if os.path.exists(app_token) and not os.path.exists(service_token):
			shutil.copy2(app_token, service_token)
			utils.ensure_file_ownership(service_token)

		# When a new service is created, ensure the binaries are installed immediately.
		self.update()

	def update(self) -> bool:
		"""
		Update the game server

		:return:
		"""
		# Hytale provides their own downloader, download that first if necessary
		downloader_zip = os.path.join(utils.get_base_directory(), 'Packages', 'hytale-downloader.zip')
		if not os.path.exists(downloader_zip):
			download_file('https://downloader.hytale.com/hytale-downloader.zip', downloader_zip)

		if not os.path.exists(downloader_zip):
			logging.error('ERROR: Unable to download Hytale downloader, please check your internet connection.')
			return False

		# Extract the executable if necessary
		download_exe = os.path.join(utils.get_base_directory(), 'Packages', 'hytale-downloader-linux-amd64')
		if not os.path.exists(download_exe):
			print('''

=====================================================

IMPORTANT: Hytale Downloader Requires Authentication!

=====================================================

You may be prompted to open a URL in your web browser to
authenticate your server.

Please open the link and authenticate if prompted.
''')
			try:
				with zipfile.ZipFile(downloader_zip, 'r') as zip_ref:
					# Extract everything into that directory
					zip_ref.extractall(os.path.dirname(download_exe))
			except Exception as e:
				logging.error('ERROR: Unable to extract Hytale downloader: %s' % e)
				return False

		# Ensure it is executable
		if not os.access(download_exe, os.X_OK):
			os.chmod(download_exe, 0o755)

		utils.ensure_file_ownership(os.path.dirname(download_exe))
		version = self.get_latest_version()

		zip_path = os.path.join(utils.get_base_directory(), 'Packages', '%s.zip' % version)
		if not os.path.exists(zip_path):
			# Run the Hytale downloader to get the latest version
			self.download_latest_version()

		if os.path.exists(zip_path):
			# Check if the game is already installed and up to date.
			game_version = self.get_version()
			if game_version is None:
				logging.info('Hytale not installed yet, continuing with update')
			elif game_version != version:
				logging.info('Hytale needs updated, continuing with update')
			else:
				logging.info('Hytale is up to date, no update required')
				return True

			# Just use the system's unzip for extraction, as these files are rather large.
			logging.info('Extracting game package...')
			try:
				with zipfile.ZipFile(zip_path, 'r') as zip_ref:
					# Extract everything into the game directory
					zip_ref.extractall(self.get_app_directory())
			except Exception as e:
				logging.error('ERROR: Unable to extract Hytale downloader: %s' % e)
				return False

			# Save the version installed
			with open(os.path.join(self.get_app_directory(), '.version'), 'w') as f:
				f.write(version)

			# Ensure file permissions
			utils.ensure_file_ownership(self.get_app_directory())
			return True
		else:
			logging.error('ERROR: Game package %s not found after download!' % zip_path)
			return False

	def get_version(self) -> str | None:
		"""
		Get the version of the game binary

		:return:
		"""
		version_file = os.path.join(self.get_app_directory(), '.version')
		if os.path.exists(version_file):
			with open(version_file, 'r') as f:
				return f.read().strip()
		return None

	def get_latest_version(self) -> str:
		"""
		Get the latest version of the game server available from Hytale

		:return:
		"""
		download_exe = os.path.join(utils.get_base_directory(), 'Packages', 'hytale-downloader-linux-amd64')
		cmd = PipeCmd([download_exe, '-print-version'])
		# Run this command as the game user
		cmd.sudo(utils.get_app_uid())
		# Run within the packages directory
		cmd.cwd(os.path.dirname(download_exe))
		# Request specific branch if requested
		branch = self.get_option_value('Game Branch')
		if branch != 'latest':
			cmd.extend(['-patchline', branch])

		version = None
		process = cmd.run()
		while True:
			output = process.stdout.readline()
			if output == b'' and process.poll() is not None:
				break
			if output:
				line = output.decode().strip()
				# Versions should simply be the version string, e.g. "1.0.0-tag"
				# The output can also be a message to the user to authenticate though,
				# which those should be skipped and simply printed to stdout.
				if re.match(r'^\d+\.\d+\.\d+(-\w+)?$', line):
					version = line
					break
				else:
					print(line)
		process.wait()

		if version is None:
			return ''
		else:
			return version

	def download_latest_version(self) -> bool:
		"""
		Download the requested version of the game server

		:return:
		"""
		download_exe = os.path.join(utils.get_base_directory(), 'Packages', 'hytale-downloader-linux-amd64')
		cmd = Cmd([download_exe])
		# Stream the output to stdout/stderr directly
		cmd.stream_output()
		# Run this command as the game user
		cmd.sudo(utils.get_app_uid())
		# Run within the packages directory
		cmd.cwd(os.path.dirname(download_exe))
		# Request specific branch if requested
		branch = self.get_option_value('Game Branch')
		if branch != 'latest':
			cmd.extend(['-patchline', branch])

		# Return the success result of the command; will auto-execute.
		return cmd.success

	def check_update_available(self) -> bool:
		"""
		Check if there's an update available for this game

		:return:
		"""
		game_version = self.get_version()

		if game_version is None:
			# If the game is not installed yet, then YES, there's an update available!
			return True

		latest_version = self.get_latest_version()
		return game_version != latest_version

	def get_executable(self) -> str:
		"""
		Get the full executable for this game service
		:return:
		"""

		java_path = find_java_version(25)

		# --allow-early-plugins --bind 1234
		jar_params = cli_formatter(self.configs['service'], section='JarParams', prefix='--', true_value=True, false_value=False, sep=' ')

		# -Xms1024M -Xmx16G
		java_params = cli_formatter(self.configs['service'], section='JavaParams', prefix='-', true_value=True, false_value=False, sep='')

		game_path = os.path.join(self.get_app_directory(), 'Server/HytaleServer.jar')

		return ' '.join([
			java_path,
			java_params,
			'-XX:MaxMetaspaceSize=512M',
			'-XX:+UnlockExperimentalVMOptions',
			'-XX:+UseShenandoahGC',
			'-XX:ShenandoahGCHeuristics=compact',
			'-XX:ShenandoahUncommitDelay=30000',
			'-XX:ShenandoahAllocationThreshold=15',
			'-XX:ShenandoahGuaranteedGCInterval=30000',
			'-XX:+PerfDisableSharedMem',
			'-XX:+DisableExplicitGC',
			'-XX:+ParallelRefProcEnabled',
			'-XX:ParallelGCThreads=4',
			'-XX:ConcGCThreads=2',
			'-XX:+AlwaysPreTouch',
			'-jar',
			game_path,
			jar_params,
			'--assets',
			'"%s"' % os.path.join(self.get_app_directory(), 'Assets.zip'),
		])

	def get_save_files(self) -> list | None:
		"""
		Get a list of save files / directories for the game server

		:return:
		"""
		return ['banned-ips.json', 'banned-players.json', 'ops.json', 'whitelist.json', 'universe']

	def get_save_directory(self) -> str | None:
		"""
		Get the save directory for the game server

		:return:
		"""
		return self.get_app_directory()

	def option_value_updated(self, option: str, previous_value, new_value) -> bool | None:
		"""
		Handle any special actions needed when an option value is updated
		:param option:
		:param previous_value:
		:param new_value:
		:return:
		"""
		success = None
		rebuild = False

		# Special option actions
		if option == 'Bind Port':
			# Update firewall for game port change
			if previous_value:
				Firewall.remove(int(previous_value), 'udp')
			Firewall.allow(int(new_value), 'udp', '%s game port' % self.game.name)
			success = True
			rebuild = True

		if rebuild:
			# For games that need to regenerate systemd to apply changes
			self.build_systemd_config()
			self.reload()
		return success

	def get_players(self) -> list | None:
		"""
		Get a list of current players on the server, or None if the API is unavailable
		:return:
		"""
		# This currently does not work because the API only returns the last connected player...
		# over, and over, and over....
		# If there are 10 players connected, it's just the last player 10 times.
		return None

	def get_player_count(self) -> int | None:
		"""
		Get the current player count on the server, or None if the API is unavailable
		:return:
		"""
		ret = self.cmd('/who')
		if ret is None:
			return None

		players = 0
		def watch(line):
			nonlocal players
			world_name = 'default'
			# Trim timestamp, (anything before the first ':')
			if ': ' in line:
				line = line.split(': ', 1)[1].strip()
				if line.startswith('%s (' % world_name):
					players = int(line.split('(')[1].split(')')[0])
					return True
		self.watch(watch)
		return players

	def get_port_definitions(self) -> list:
		"""
		Get a list of port definitions for this service
		:return:
		"""
		return [
			('Bind Port', 'udp', '%s game port' % self.game.name)
		]

	def get_player_max(self) -> int:
		"""
		Get the maximum player count allowed on the server
		:return:
		"""
		return self.get_option_value('Max Players')

	def get_name(self) -> str:
		"""
		Get the name of this game server instance
		:return:
		"""
		return self.get_option_value('Server Name')

	def get_port(self) -> int | None:
		"""
		Get the primary port of the service, or None if not applicable
		:return:
		"""
		return self.get_option_value('Bind Port')

	def get_game_pid(self) -> int:
		"""
		Get the primary game process PID of the actual game server, or 0 if not running
		:return:
		"""

		# For services that do not have a helper wrapper, it's the same as the process PID
		return self.get_pid()

	def send_message(self, message: str):
		"""
		Send a message to all players via the game API
		:param message:
		:return:
		"""
		self.cmd('/say %s' % message)

	def save_world(self):
		"""
		Force the game server to save the world via the game API
		:return:
		"""
		self.cmd('/world save')

	def get_commands(self) -> None | list[str]:
		"""
		Get a list of available commands for this service, or an empty list if the API is unavailable
		:return:
		"""
		ret = self.cmd('/commands dump')
		if ret is None:
			# API is not available, return an empty list to avoid showing any commands.
			print('Unable to retrieve commands, API is not available.', file=sys.stderr)
			return None

		# Hytale dumps all commands to a JSON file in (here)/AppFiles/dumps/commands.dump.json
		# The format contains an object with 'modern' which contains an array of commands.
		# each command is an object with 'name' (among other fields, but we only care about name).
		# Give the game a moment to write the file, then read and parse it.
		time.sleep(1)
		dump_path = os.path.join(self.get_app_directory(), 'dumps', 'commands.dump.json')
		if not os.path.exists(dump_path):
			print('Commands dump file not found at %s' % dump_path, file=sys.stderr)
			return None

		data = json.load(open(dump_path, 'r'))
		commands = []
		if 'modern' in data and isinstance(data['modern'], list):
			for cmd in data['modern']:
				if 'name' in cmd:
					commands.append(cmd['name'])
		return commands


if __name__ == '__main__':
	app = app_runner(GameApp())
	app()
