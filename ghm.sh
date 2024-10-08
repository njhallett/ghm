#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
IFS=$'\n\t'

# @version 0.0.19
# @author Niall Hallett <njhallett@gmail.com>
# @describe Manage github distro package release installs

PROGRAM_NAME="ghm"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$PROGRAM_NAME"
CONFIG_FILE="config.json"
CONFIG="$CONFIG_DIR/$CONFIG_FILE"

command -v argc >/dev/null 2>&1 || {
    echo >&2 "I require argc but it's not installed.  Aborting."
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    echo >&2 "I require jq but it's not installed.  Aborting."
    exit 1
}
command -v gh >/dev/null 2>&1 || {
    echo >&2 "I require gh but it's not installed.  Aborting."
    exit 1
}
command -v sudo >/dev/null 2>&1 || {
    echo >&2 "I require sudo but it's not installed.  Aborting."
    exit 1
}
command -v sponge >/dev/null 2>&1 || {
    echo >&2 "I require sponge but it's not installed.  Aborting."
    exit 1
}

function _ghm_arch {
    local _ghm_arch=''

    case $(uname -m) in
    x86_64)
        _ghm_arch="\(amd64\|x86_64\|64bit\)"
        ;;
    i*86)
        _ghm_arch=386
        ;;
    armv7l)
        _ghm_arch=armv6
        ;;
    esac

    echo "$_ghm_arch"
}

function _ghm_pkg {
    local _ghm_pkg=''

    # shellcheck disable=SC1091
    source /etc/os-release

    case $ID in
    fedora)
        _ghm_pkg=rpm
        ;;
    debian | raspbian)
        _ghm_pkg=deb
        ;;
    alpine)
        _ghm_pkg=apk
        ;;
    esac

    echo "$_ghm_pkg"
}

function _ghm_install {
    local _ghm_install_repo=$1
    local _ghm_install_dryrun=$2
    local _ghm_install_all=$3
    local _ghm_install_keep=$4

    if [[ -z "$_ghm_install_all" ]]; then
        readarray -t pkgs < <(gh release view --repo "$_ghm_install_repo" --json assets --jq '.assets.[].name' | grep "$(_ghm_arch)\.$(_ghm_pkg)$")

        if [[ ${#pkgs[@]} -eq 0 ]]; then
            readarray -t pkgs < <(gh release view --repo "$_ghm_install_repo" --json assets --jq '.assets.[].name' | grep "\.$(_ghm_pkg)$")
        fi

    fi

    if [[ -n "$_ghm_install_all" || ${#pkgs[@]} -eq 0 ]]; then
        readarray -t pkgs < <(gh release view --repo "$_ghm_install_repo" --json assets --jq '.assets.[].name')
    fi

    case ${#pkgs[@]} in

    0)
        echo "No matches found"
        return 1
        ;;
    1)
        sel=0
        ;;
    *)
        echo
        echo "Multiple matches found, please select one:"
        echo
        declare -i i

        for i in "${!pkgs[@]}"; do
            echo " [$i] ${pkgs[$i]}"
        done

        sel=-1

        while [[ $sel -eq -1 ]]; do
            read -rp " Select an option: " sel

            if ! [[ "$sel" =~ [${!pkgs[*]}] ]]; then
                echo 'Invalid option'
                sel=-1
                continue
            fi

        done
        ;;
    esac

    echo "${pkgs[$sel]}"

    if [[ -z "$_ghm_install_dryrun" ]]; then

        if [[ -f "${pkgs[$sel]}" ]]; then
            echo "file already downloaded"
        else
            gh release download --repo "$_ghm_install_repo" --pattern "${pkgs[$sel]}"
        fi

        case $(_ghm_pkg) in

        rpm)
            sudo dnf -y install "./${pkgs[$sel]}"
            ;;
        deb)
            sudo apt install "./${pkgs[$sel]}"
            ;;
        apk)
            sudo apk add --allow-untrusted "./${pkgs[$sel]}"
            ;;
        *)
            echo "Unknown package manager"
            return 1
            ;;
        esac

        if [[ -z "$_ghm_install_keep" ]]; then
            rm "./${pkgs[$sel]}"
        fi

        return $?
    fi
}

if [[ ! -f "$CONFIG" ]]; then

    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR"
    fi

    echo '{"apps":[]}' >"$CONFIG"
fi

# @cmd list installed apps
# @alias l
function list {
    echo
    jq -r '["Name","Version","Repo"], (.apps | .[] | [.name, .version, .repo]) | @tsv' "$CONFIG" | column -t
    echo
}

# @cmd install app
# @alias i
# @flag -n --dryrun    don't actually install
# @flag -a --all       show all download options
# @flag -k --keep      keep downloaded package
# @arg repo!           github <owner/repo> to download from
function install {

    # shellcheck disable=SC2154
    if [[ $(expr "$argc_repo" : '^[[:alnum:]\._-]\+/[[:alnum:]\._-]\+$') -eq 0 ]]; then
        echo "Invalid repo"
        exit 1
    fi

    # shellcheck disable=SC2154
    if ! _ghm_install "$argc_repo" "$argc_dryrun" "$argc_all" "$argc_keep"; then
        echo "Install failed"
        exit 1
    fi

    ver=$(gh release list --repo "$argc_repo" --exclude-drafts | grep "Latest" | rev | cut -f 2 | rev)
    name=$(echo "$argc_repo" | cut -d '/' -f 2)

    if [[ -z "$ver" || -z "$name" ]]; then
        echo "Name and/or version couldn't be determined"
        exit 1
    fi

    [[ -n "$argc_dryrun" ]] && exit 0

    jq --arg repo "$argc_repo" --arg ver "$ver" --arg name "$name" '.apps[.apps | length] += {"name": $name, "repo": $repo, "version": $ver}' "$CONFIG" | sponge "$CONFIG"
}

# @cmd update installed apps
# @alias u
# @flag -n --dryrun    don't actually install
# @flag -a --all       show all download options
# @flag -k --keep      keep downloaded package(s)
# @arg name            specific package to update
function update {
    declare -a update_repo=()
    declare -a update_name=()
    declare -a update_ver=()
    OIFS=$IFS
    IFS=','

    if [[ -z "$argc_name" ]]; then
        readarray -t pkgs < <(jq -c '.apps[] | [.name,.repo,.version]' "$CONFIG" | sed 's/[]["]//g')

        for i in "${!pkgs[@]}"; do
            read -ra field <<<"${pkgs[$i]}"
            local _update_ver
            _update_ver=$(gh release list --repo "${field[1]}" --exclude-drafts | grep "Latest" | rev | cut -f 2 | rev)

            if [[ ${field[2]} != "$_update_ver" ]]; then
                echo "${field[0]} ${field[2]} -> $_update_ver"
                update_repo+=("${field[1]}")
                update_name+=("${field[0]}")
                update_ver+=("$_update_ver")
            fi

        done

    else
        local _pkg_repo
        local _pkg_ver
        _pkg_repo=$(jq --arg name "$argc_name" '.apps[] | select(.name == $name).repo' "$CONFIG" | sed 's/"//g')
        _pkg_ver=$(jq --arg name "$argc_name" '.apps[] | select(.name == $name).version' "$CONFIG" | sed 's/"//g')

        if [[ -n "$_pkg_repo" ]]; then
            local _update_ver
            _update_ver=$(gh release list --repo "${field[1]}" --exclude-drafts | grep "Latest" | rev | cut -f 2 | rev)

            if [[ "$_pkg_ver" != "$_update_ver" ]]; then
                echo "$argc_name $_pkg_ver -> $_update_ver"
                update_repo+=("$_pkg_repo")
                update_name+=("$argc_name")
                update_ver+=("$_update_ver")
            fi
        fi

    fi

    IFS=$OIFS

    if [ ${#update_repo[@]} -eq 0 ]; then
        exit 0
    fi

    while true; do
        read -rp "Do you want to continue? [y/n] " yn
        case $yn in
        [Yy]*) break ;;
        [Nn]*) exit 1 ;;
        *) echo "Please answer yes or no." ;;
        esac
    done

    declare -i i

    for i in "${!update_repo[@]}"; do

        if ! _ghm_install "${update_repo[$i]}" "$argc_dryrun" "$argc_all" "$argc_keep"; then
            echo "Update failed"
            continue
        fi

        [[ -n "$argc_dryrun" ]] && continue

        jq --arg ver "${update_ver[$i]}" --arg name "${update_name[$i]}" '(.apps[] | select(.name == $name)).version |= $ver' "$CONFIG" | sponge "$CONFIG"
    done
}

# @cmd remove app
# @alias r
# @arg name!           package to remove
function remove {
    local _pkg_repo

    _pkg_repo=$(jq --arg name "$argc_name" '.apps[] | select(.name == $name).repo' "$CONFIG" | sed 's/"//g')

    if [[ -z "$_pkg_repo" ]]; then
        echo "package not configured"
        exit 1
    fi

    case $(_ghm_pkg) in

    rpm)
        sudo dnf remove "$argc_name"
        ;;
    deb)
        sudo apt remove "$argc_name"
        ;;
    apk)
        sudo apk del "$argc_name"
        ;;
    *)
        echo "Unknown package manager"
        exit 1
        ;;
    esac

    # shellcheck disable=SC2181
    if [[ $? -ne 0 ]]; then
        echo "Remove failed"
        exit 1
    fi

    jq --arg name "$argc_name" 'del(.apps[] | select(.name == $name))' "$CONFIG" | sponge "$CONFIG"
}

declare argc_name=""
declare argc_dryrun=""
declare argc_all=""
declare argc_keep=""

eval "$(argc --argc-eval "$0" "$@")"
