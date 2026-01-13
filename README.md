# Using this boilerplate template

Clone this repo and start populating with your game.

## Directory Structure

The notable directories are:

### `src/`

Contains the scripts which will get compiled.
Refer to [Scripts Collection Builder by eVAL](https://github.com/eVAL-Agency/ScriptsCollection) for documentation
on using the compiler and what inline flags are supported.

In short, it just glues together a bunch of scripts into a single, distributable file.

To make changes to your installer, **do so in src/!**.

### `scripts/`

Not to be confused with src, this directory contains supplemental files used by scripts within src.
These do not get compiled, but are instead referenced by the scripts in src.

* configs.yaml - A YAML file containing configuration data for your game.
* systemd-template.service - A systemd service template file for running your game as a service.

### `media/`

Contains media assets for your game, such as images, audio files, etc.
It is recommended to provide at least:

* small logo, 128x128 in WEBP format
* medium size thumbnail, 640x400 in WEBP format
* full size teaser image, 1920x1080 in WEBP format

_WEBP is preferred for its balance of quality and file size, but PNG and JPG are also acceptable._

### `dist/`

This directory will contain the compiled output of your game installer.
By default this will contain `installer.sh`, `manage.py`, `community_scripts.json`, and `warlock.yaml`.

* The installer is the primary end point for installing the library.
* The manager is a utility script for managing the installed game and interfacing with [Warlock](https://github.com/BitsNBytes25/Warlock).
* community_scripts.json is a manifest file for [Tactical RMM](https://github.com/amidaware/tacticalrmm) (not generally used here)
* warlock.yaml is a configuration file for Warlock.


## Editing installer

The installer (`src/installer.sh`) is the main script that users will run to install your game.


### Metadata

In the header of the installer, ensure to update:

* `@AUTHOR` - Your name or your organization's name, optionally with your email address inside `< ... >` brackets.
* `@WARLOCK-TITLE` - Short name to display in Warlock
* `@WARLOCK-IMAGE` - Relative or absolute path to the image file to use in Warlock, ie 'media/game-1920x1080.webp'
* `@WARLOCK-ICON` - Relative or absolute path to the icon file to use in Warlock, ie 'media/game-128x128.webp'
* `@WARLOCK-THUMBNAIL` - Relative or absolute path to the thumbnail file to use in Warlock, ie 'media/game-640x480.webp'
* `Supports:` - A list of operating systems your game supports, ie: 'Debian 12, 13 (newline) Ubuntu 22.04, 24.04'
* `Syntax:` - List of command line arguments the installer supports


### Variable Declaration

Towards the top of the installer are the group of variables that define your game's properties.
These are used within the installer and optionally `scripts/` files.


### Scriptlet Includes

Many tasks of the installer are imported scriptlets from other projects,
thanks to the functionality as provided by [the compiler](https://github.com/eVAL-Agency/ScriptsCollection).

`# scriptlet:_common/package_install.sh` provides a function `package_install` used for installing system packages for example.


## Editing Manager

The manager (`src/manage.py`) is a utility script that users can run to manage the installed game.
It also serves as the interface between your game and [Warlock](https://github.com/BitsNBytes25/Warlock).

### Game Application

Just like installer.sh, the manager can also import scriptlets.

For games that rely on Steam as the installation backend, the following import
provides `SteamApp`:

```python
from scriptlets.warlock.steam_app import *

...

class GameApp(SteamApp):
```

For games that do not use Steam, the base application can be used instead for `BaseApp`:

```python
from scriptlets.warlock.base_app import *

... 

class GameApp(BaseApp):
```

For games with no backend provider, you will need to ensure to setup your own `update` and `check_update_available` methods.

```python
def check_update_available(self) -> bool:
	"""
	Check if a SteamCMD update is available for this game

	:return:
	"""
	# Do the tasks necessary to check for an update

def update(self):
	"""
	Update the game server via SteamCMD

	:return:
	"""
	# Do the necessary tasks to update the game binary
```


## Game Service

Similar to the game application, each service (instance/map) has its own type; this is based on the API 
mechanism provided by the game itself.  Common types are `BaseService`, `HTTPService`, and `RCONService`.

The main function of the service is configurations for the game instance and interfacing with the game environment
via available API for the respective game.


## Building your Installer

Once you have populated the `src/` directory with your scripts, you can build your installer by running:

```bash
./compile.py
```

This will generate:

* `dist/installer.sh` - Bundled installation script and entry point
* `dist/manage.py` - Bundled management interface and Warlock API
* `dist/community_scripts.json` - TacticalRMM package information
* `dist/warlock.yaml` - Warlock application metadata


## Deploying to Warlock

To deploy your game to Warlock, copy the contents of warlock.yaml
and add it to `Apps.yaml` in Warlock.

For local testing, just updating your local copy is sufficient,
but to publish your installer to the greater community please issue a merge request
with your metadata.


## Supplemental Projects and Shameless-self-plugs

* [Scripts Collection Builder by eVAL](https://github.com/eVAL-Agency/ScriptsCollection)
* [Warlock by BitsNBytes25](https://github.com/BitsNBytes25/Warlock)
* [Bits n Bytes Community](https://bitsnbytes.dev)
* [Donate to this project](https://ko-fi.com/bitsandbytes)
* [Join our Discord](https://discord.gg/jyFsweECPb)
* [Follow us on Mastodon](https://social.bitsnbytes.dev/@sitenews)
