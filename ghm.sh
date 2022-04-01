#!/bin/sh

# @version 0.0.1
# @author Niall Hallett <njhallett@gmail.com>
# @describe Manage github distro package release installs

config_dir="$HOME/.config/ghm"
config_file="config.json"
config="$config_dir/$config_file"

command -v argc >/dev/null 2>&1 || { echo >&2 "I require argc but it's not installed.  Aborting."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo >&2 "I require jq but it's not installed.  Aborting."; exit 1; }
command -v gh >/dev/null 2>&1 || { echo >&2 "I require gh but it's not installed.  Aborting."; exit 1; }

_ghm_arch() {
  case $(uname -m) in
    x86_64)
      _ghm_arch=amd64
      ;;
    i*86)
      _ghm_arch=386
      ;;
    armv7l)
      _ghm_arch=armv6
      ;;
    *)
      _ghm_arch=''
      ;;
  esac

  echo "$_ghm_arch"
}

_ghm_pkg() {
  . /etc/os-release

  case $ID in
    fedora)
      _ghm_pkg=rpm
      ;;
    debian|raspbian)
      _ghm_pkg=deb
      ;;
    alpine)
      _ghm_pkg=apk
      ;;
    *)
      _ghm_pkg=''
      ;;
  esac

  echo "$_ghm_pkg"
}

if [ ! -f "$config" ]; then
    if [ ! -d "$config_dir" ]; then
        mkdir -p "$config_dir"
    fi

    touch "$config"
fi

# @cmd list installed apps
# @alias l
list() {
    cat "$config" | jq -r '["Name","Version","Repo"], (.apps | .[] | [.name, .version, .repo]) | @tsv' | column -t
}

# @cmd install app
# @alias i
# @arg repo!
install() {
    gh release view --repo $argc_repo --json name,assets --jq '.assets.[].name' | grep "$(_ghm_arch)\.$(_ghm_pkg)$"
}

eval "$(argc $0 "$@")"
