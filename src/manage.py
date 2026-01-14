#!/usr/bin/env python3
import pwd
import os
import re
import random
import string
from scriptlets._common.firewall_allow import *
from scriptlets._common.firewall_remove import *
from scriptlets.bz_eval_tui.prompt_yn import *
from scriptlets.bz_eval_tui.prompt_text import *
from scriptlets.bz_eval_tui.table import *
from scriptlets.bz_eval_tui.print_header import *
from scriptlets._common.get_wan_ip import *
# import:org_python/venv_path_include.py
import yaml
# Game application source - what type of game is being installed?
from scriptlets.warlock.base_app import *
# from scriptlets.warlock.steam_app import *
# Game services are usually either an RCON, HTTP, or base type service.
# Include the necessary type and remove the rest.
from scriptlets.warlock.base_service import *
# from scriptlets.warlock.http_service import *
# from scriptlets.warlock.rcon_service import *
from scriptlets.warlock.ini_config import *
from scriptlets.warlock.properties_config import *
from scriptlets.warlock.default_run import *

# For games that use Steam, this provides a quick method for checking for updates
# from scriptlets.steam.steamcmd_check_app_update import *

here = os.path.dirname(os.path.realpath(__file__))


class GameApp(BaseApp):
	"""
	Game application manager
	"""

	def __init__(self):
		super().__init__()

		self.name = 'Hytale'
		self.desc = 'Hytale Dedicated Server'
		self.services = ('hytale-server',)

		self.configs = {
			'manager': INIConfig('manager', os.path.join(here, '.settings.ini'))
		}
		self.load()

	def get_save_files(self) -> Union[list, None]:
		"""
		Get a list of save files / directories for the game server

		:return:
		"""
		files = ['banned-ips.json', 'banned-players.json', 'ops.json', 'whitelist.json']
		for service in self.get_services():
			files.append(service.get_name())
		return files

	def get_save_directory(self) -> Union[str, None]:
		"""
		Get the save directory for the game server

		:return:
		"""
		return os.path.join(here, 'AppFiles')

	def get_latest_version(self) -> str:
		"""
		Get the latest version of the game server available from Hytale

		:return:
		"""
		cmd = os.path.join(here, 'AppFiles', 'hytale-downloader-linux-amd64')
		game_path = os.path.join(here, 'AppFiles')
		version = None
		args = [cmd, '-print-version']
		branch = self.get_option_value('Game Branch')
		if branch != 'latest':
			args += ['-patchline', branch]
		process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=game_path)
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

	def check_update_available(self) -> bool:
		"""
		Check if Hytale issued an update for this game server.

		:return:
		"""
		version = self.get_latest_version()

		if os.path.exists(os.path.join(here, 'AppFiles', version + '.zip')):
			print('Latest version (%s) is already downloaded.' % version)
			return False
		else:
			print('New version available: %s' % version)
			return True

	def update(self):
		"""
		Update the game server to the latest version.

		:return:
		"""
		# Stop any running services before updating
		services = []
		for service in self.get_services():
			if service.is_running() or service.is_starting():
				print('Stopping service %s for update...' % service.service)
				services.append(service.service)
				subprocess.Popen(['systemctl', 'stop', service.service])

		if len(services) > 0:
			# Wait for all services to stop, may take 5 minutes if players are online.
			print('Waiting up to 5 minutes for all services to stop...')
			counter = 0
			while counter < 30:
				all_stopped = True
				counter += 1
				for service in self.get_services():
					if service.is_running() or service.is_starting() or service.is_stopping():
						all_stopped = False
						break
				if all_stopped:
					break
				time.sleep(10)
		else:
			print('No running services found, proceeding with update...')


		version = self.get_latest_version()
		zip_path = os.path.join(here, 'AppFiles', version + '.zip')
		if not os.path.exists(zip_path):
			# Run the Hytale downloader to get the latest version
			cmd = os.path.join(here, 'AppFiles', 'hytale-downloader-linux-amd64')
			game_path = os.path.join(here, 'AppFiles')
			args = [cmd]
			branch = self.get_option_value('Game Branch')
			if branch != 'latest':
				args += ['-patchline', branch]
			process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=game_path)
			while True:
				output = process.stdout.readline()
				if output == b'' and process.poll() is not None:
					break
				if output:
					print(output.decode().strip())
			process.wait()

		if os.path.exists(zip_path):
			# Just use the system's unzip for extraction, as these files are rather large.
			print('Extracting game package...')
			subprocess.run(['unzip', '-o', zip_path, '-d', os.path.join(here, 'AppFiles')])
			return True
		else:
			print('ERROR: Game package %s not found after download!' % zip_path)
			return False


class GameService(BaseService):
	"""
	Service definition and handler
	"""
	def __init__(self, service: str, game: GameApp):
		"""
		Initialize and load the service definition
		:param file:
		"""
		super().__init__(service, game)
		self.service = service
		self.game = game
		self.configs = {
			'server': PropertiesConfig('server', os.path.join(here, 'AppFiles/server.properties'))
		}
		self.load()

	def _api_cmd(self, cmd):
		"""
		Send a command to the game server via its Systemd socket

		:param cmd:
		:return:
		"""
		with open('/var/run/%s.sock' % self.service, 'w') as f:
			f.write(cmd + '\n')

	def option_value_updated(self, option: str, previous_value, new_value):
		"""
		Handle any special actions needed when an option value is updated
		:param option:
		:param previous_value:
		:param new_value:
		:return:
		"""

		# Special option actions
		if option == 'Server Port':
			# Update firewall for game port change
			if previous_value:
				firewall_remove(int(previous_value), 'tcp')
			firewall_allow(int(new_value), 'tcp', 'Allow %s game port' % self.game.desc)
		elif option == 'Query Port':
			# Update firewall for game port change
			if previous_value:
				firewall_remove(int(previous_value), 'udp')
			firewall_allow(int(new_value), 'udp', 'Allow %s query port' % self.game.desc)

	def is_api_enabled(self) -> bool:
		"""
		Check if API is enabled for this service
		:return:
		"""
		return (
			self.get_option_value('Enable RCON') and
			self.get_option_value('RCON Port') != '' and
			self.get_option_value('RCON Password') != ''
		)

	def get_api_port(self) -> int:
		"""
		Get the API port from the service configuration
		:return:
		"""
		return self.get_option_value('RCON Port')

	def get_api_password(self) -> str:
		"""
		Get the API password from the service configuration
		:return:
		"""
		return self.get_option_value('RCON Password')

	def get_player_count(self) -> Union[int, None]:
		"""
		Get the current player count on the server, or None if the API is unavailable
		:return:
		"""
		try:
			ret = self._api_cmd('/list')
			# ret should contain 'There are N of a max...' where N is the player count.
			if ret is None:
				return None
			elif 'There are ' in ret:
				return int(ret[10:ret.index(' of a max')].strip())
			else:
				return None
		except:
			return None

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
		return self.get_option_value('Level Name')

	def get_port(self) -> Union[int, None]:
		"""
		Get the primary port of the service, or None if not applicable
		:return:
		"""
		return self.get_option_value('Server Port')

	def get_game_pid(self) -> int:
		"""
		Get the primary game process PID of the actual game server, or 0 if not running
		:return:
		"""

		# For services that do not have a helper wrapper, it's the same as the process PID
		return self.get_pid()

		# For services that use a wrapper script, the actual game process will be different and needs looked up.
		'''
		# There's no quick way to get the game process PID from systemd,
		# so use ps to find the process based on the map name
		processes = subprocess.run([
			'ps', 'axh', '-o', 'pid,cmd'
		], stdout=subprocess.PIPE).stdout.decode().strip()
		exe = os.path.join(here, 'AppFiles/Vein/Binaries/Linux/VeinServer-Linux-')
		for line in processes.split('\n'):
			pid, cmd = line.strip().split(' ', 1)
			if cmd.startswith(exe):
				return int(line.strip().split(' ')[0])
		return 0
		'''

	def send_message(self, message: str):
		"""
		Send a message to all players via the game API
		:param message:
		:return:
		"""
		self._api_cmd('/say %s' % message)

	def save_world(self):
		"""
		Force the game server to save the world via the game API
		:return:
		"""
		self._api_cmd('save-all flush')


def menu_first_run(game: GameApp):
	"""
	Perform first-run configuration for setting up the game server initially

	:param game:
	:return:
	"""
	print_header('First Run Configuration')

	if os.geteuid() != 0:
		print('ERROR: Please run this script with sudo to perform first-run configuration.')
		sys.exit(1)

	svc = game.get_services()[0]

	if not os.path.exists(os.path.join(here, 'AppFiles', 'auth.enc')):
		print('=================================')
		print('NOTICE: You must authenticate with Hytale during server start!')
		print('')
		print('Starting service once to allow authentication, please wait...')

		svc.start()
		counter = 0
		while counter < 60:
			counter += 1
			if svc.is_running():
				break
			time.sleep(1)

		if not svc.is_running():
			print('ERROR: Service failed to start for authentication, please check logs.')
			sys.exit(1)

		svc._api_cmd('/auth login device')
		time.sleep(1)
		svc.print_logs()

		# Wait until the user follows the prompts.
		counter = 0
		auth_successful = False
		while counter < 600:
			counter += 1
			logs = svc.get_logs()
			if 'Authentication successful' in logs:
				print('Authentication successful!')
				auth_successful = True
				break
			time.sleep(1)

		if auth_successful:
			# Authentication successful, save the token in an encrypted file so we don't have to do this BS again
			svc._api_cmd('/auth persistence Encrypted')
			time.sleep(2)
			svc._api_cmd('/auth status')
			time.sleep(2)
		svc.stop()


if __name__ == '__main__':
	game = GameApp()
	run_manager(game)
