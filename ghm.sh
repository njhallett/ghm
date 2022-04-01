#!/bin/sh

config_dir="$HOME/.config/ghm"
config_file="config.json"
config="$config_dir/$config_file"

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

eval "$(argc $0 "$@")"
