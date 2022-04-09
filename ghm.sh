#!/bin/bash

# @version 0.0.7
# @author Niall Hallett <njhallett@gmail.com>
# @describe Manage github distro package release installs

config_dir="$HOME/.config/ghm"
config_file="config.json"
config="$config_dir/$config_file"

command -v argc >/dev/null 2>&1 || { echo >&2 "I require argc but it's not installed.  Aborting."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo >&2 "I require jq but it's not installed.  Aborting."; exit 1; }
command -v gh >/dev/null 2>&1 || { echo >&2 "I require gh but it's not installed.  Aborting."; exit 1; }
command -v sudo >/dev/null 2>&1 || { echo >&2 "I require sudo but it's not installed.  Aborting."; exit 1; }
command -v sponge >/dev/null 2>&1 || { echo >&2 "I require sponge but it's not installed.  Aborting."; exit 1; }

_ghm_arch() {
    local _ghm_arch=''

    case $(uname -m) in
        x86_64)
            _ghm_arch="\(amd64\|x86_64\)"
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

_ghm_pkg() {
    local _ghm_pkg=''

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
    esac

    echo "$_ghm_pkg"
}

_ghm_install() {
    local _ghm_install_repo=$1
    local _ghm_install_dryrun=$2

    readarray -t pkgs < <(gh release view --repo $_ghm_install_repo --json assets --jq '.assets.[].name' | grep "$(_ghm_arch)\.$(_ghm_pkg)$")

    case ${#pkgs[@]} in

        0)
            echo "No matches found"
            return 1
            ;;
        1)
            sel=0
            ;;
        *)
            echo; echo "Multiple matches found, please select one:"; echo

            for i in ${!pkgs[@]}; do
                echo " [$i] ${pkgs[$i]}"
            done

            sel=-1

            while [ $sel -eq -1 ]; do
                read -p " Select an option: " sel

                if ! [[ "$sel" =~ [0-${!pkgs[@]}] ]]; then
                    echo 'Invalid option'
                    sel=-1
                    continue
                fi
            done
            ;;
    esac

    echo "${pkgs[$sel]}"

    if [ ! $_ghm_install_dryrun ]; then

        if [ -f "${pkgs[$sel]}" ]; then
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
                echo "Unknown install method"
                return 1
                ;;
        esac

        return $?
    fi
}

if [ ! -f "$config" ]; then

    if [ ! -d "$config_dir" ]; then
        mkdir -p "$config_dir"
    fi

    echo '{"apps":[]}' >"$config"
fi

# @cmd list installed apps
# @alias l
list() {
    echo
    cat "$config" | jq -r '["Name","Version","Repo"], (.apps | .[] | [.name, .version, .repo]) | @tsv' | column -t
    echo
}

# @cmd install app
# @alias i
# @flag -n --dryrun    don't actually install
# @arg repo!            github <owner/repo> to download from
install() {
    _ghm_install $argc_repo $argc_dryrun

    if [ $? -ne 0 ]; then
        echo "Install failed"
        exit 1
    fi

    ver=`gh release view --repo "$argc_repo" --json name --jq '.name'`
    name=`echo "$argc_repo" | cut -d '/' -f 2`

    if [[ -z "$ver" || -z "$name" ]]; then
        echo "Name and/or version couldn't be determined"
        exit 1
    fi

    jq --arg repo $argc_repo --arg ver $ver --arg name $name '.apps[.apps | length] += {"name": $name, "repo": $repo, "version": $ver}' "$config" | sponge "$config"
}

# @cmd update installed apps
# @alias u
# @flag -n --dryrun    don't actually install
update() {
    readarray -t pkgs < <(jq -c '.apps[] | [.name,.repo,.version]' "$config" | sed 's/[]["]//g')

    update_repo=()
    update_name=()
    update_ver=()
    OIFS=$IFS
    IFS=','

    for i in ${!pkgs[@]}; do
        read -ra field <<< "${pkgs[$i]}"
        ver=`gh release view --repo "${field[1]}" --json name --jq '.name'`

        if [ ! ${field[2]} = "$ver" ]; then
            echo "${field[0]} ${field[2]} -> $ver"
            update_repo+=${field[1]}
            update_name+=${field[0]}
            update_ver+=$ver
        fi

    done

    IFS=$OIFS

    while true; do
        read -p "Do you want to continue? [y/n] " yn
        case $yn in
            [Yy]* ) break;;
            [Nn]* ) exit 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done

    for i in ${!update_repo[@]}; do
        _ghm_install ${update_repo[$i]} $argc_dryrun

        if [ $? -ne 0 ]; then
            echo "Update failed"
            continue
        fi

        jq --arg ver ${update_ver[$i]} --arg name ${update_name[$i]} '(.apps[] | select(.name == $name)).version |= $ver' "$config" | sponge "$config"
    done
}

eval "$(argc $0 "$@")"
