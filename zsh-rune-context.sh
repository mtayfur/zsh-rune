#!/usr/bin/env zsh
# zsh-rune context module — minimal context for AI command generation

[[ -n "$_zsh_rune_plugin_dir" ]] || _zsh_rune_plugin_dir="${${(%):-%N}:a:h}"

_zsh_rune_match_any() {
    emulate -L zsh
    local value="$1"
    shift

    local pattern
    for pattern in "$@"; do
        [[ "$value" == ${~pattern} ]] && return 0
    done

    return 1
}

_zsh_rune_unique_items() {
    emulate -L zsh
    typeset -A seen=()

    local item
    for item in "$@"; do
        [[ -n "$item" ]] || continue
        (( ${+seen[$item]} )) && continue
        seen[$item]=1
        print -r -- "$item"
    done
}

_zsh_rune_in_git_repo() {
    emulate -L zsh
    git rev-parse --is-inside-work-tree &>/dev/null
}

_zsh_rune_ignore_line_to_pattern() {
    emulate -L zsh
    local line
    line=$(_zsh_rune_trim_text "$1")

    [[ -n "$line" ]] || return 0

    if [[ "$line" == \\#* || "$line" == \\!* ]]; then
        line="${line#\\}"
    elif [[ "$line" == \#* || "$line" == \!* ]]; then
        return 0
    fi

    while [[ "$line" == ./* ]]; do
        line="${line#./}"
    done
    while [[ "$line" == /** ]]; do
        line="${line#/}"
    done
    while [[ "$line" == '**/'* ]]; do
        line="${line#**/}"
    done
    while [[ "$line" == *'/**' ]]; do
        line="${line%/**}"
    done
    while [[ "$line" == */ ]]; do
        line="${line%/}"
    done

    [[ -n "$line" ]] || return 0

    case "$line" in
        '*'|'.*'|'**'|'**/*') return 0 ;;
    esac

    [[ "$line" == */* ]] && return 0

    print -r -- "$line"
}

_zsh_rune_collect_ignore_files() {
    emulate -L zsh
    local -a ignore_files=() global_candidates=()
    local file global_ignore git_dir

    for file in \
        "$PWD/.gitignore" \
        "$PWD/.ignore" \
        "$PWD/.fdignore" \
        "$PWD/.rgignore"; do
        [[ -r "$file" ]] && ignore_files+=("$file")
    done

    if _zsh_rune_in_git_repo; then
        git_dir=$(git rev-parse --git-dir 2>/dev/null)
        [[ -n "$git_dir" && -r "$git_dir/info/exclude" ]] && ignore_files+=("$git_dir/info/exclude")
    fi

    global_ignore=$(git config --global --get core.excludesfile 2>/dev/null)
    if [[ -n "$global_ignore" ]]; then
        global_candidates+=("${~global_ignore}")
    fi
    global_candidates+=(
        "$HOME/.config/git/ignore"
        "$HOME/.gitignore"
        "$HOME/.gitignore_global"
    )

    for file in "${global_candidates[@]}"; do
        [[ -r "$file" ]] && ignore_files+=("$file")
    done

    _zsh_rune_unique_items "${ignore_files[@]}"
}

_zsh_rune_ignore_file_patterns() {
    emulate -L zsh
    local file line pattern

    for file in "$@"; do
        [[ -r "$file" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            pattern=$(_zsh_rune_ignore_line_to_pattern "$line")
            [[ -n "$pattern" ]] && print -r -- "$pattern"
        done < "$file"
    done
}

_zsh_rune_context_all() {
    emulate -L zsh

    # Environment
    local ctx="Shell: zsh ${ZSH_VERSION}"
    ctx+=$'\n'"OS: $(uname -sm)"
    (( EUID == 0 )) && ctx+=$'\n'"User: root" || ctx+=$'\n'"User: ${USER:-$(whoami)}"
    [[ -f /proc/version ]] && [[ "$(</proc/version)" == *[Mm]icrosoft* ]] && ctx+=$'\n'"WSL: yes"
    [[ -n "$DISPLAY" || -n "$WAYLAND_DISPLAY" ]] && ctx+=$'\n'"Display: yes"
    [[ -n "$EDITOR" ]] && ctx+=$'\n'"Editor: $EDITOR"

    # Workspace
    ctx+=$'\n'"Dir: ${PWD}"
    local -a entries=( *(DN) )
    local in_git_repo=0
    _zsh_rune_in_git_repo && in_git_repo=1
    local rules_file default_rules_file
    default_rules_file="${_zsh_rune_plugin_dir}/zsh-rune-context-rules.zsh"
    rules_file="${ZSH_RUNE_CONTEXT_RULES_FILE:-$default_rules_file}"
    if [[ -n "$ZSH_RUNE_CONTEXT_RULES_FILE" && ! -r "$rules_file" && -r "$default_rules_file" ]]; then
        rules_file="$default_rules_file"
    fi

    local -a skip_patterns=() deprioritize_patterns=() prefer_patterns=()
    if [[ -r "$rules_file" ]]; then
        setopt local_options noglob
        source "$rules_file"
    fi

    local -a ignore_files=() ignore_skip_patterns=()
    ignore_files=( "${(@f)$(_zsh_rune_collect_ignore_files)}" )
    ignore_skip_patterns=( "${(@f)$(_zsh_rune_ignore_file_patterns "${ignore_files[@]}")}" )
    skip_patterns=( "${(@f)$(_zsh_rune_unique_items "${skip_patterns[@]}" "${ignore_skip_patterns[@]}")}" )

    local -a preferred_entries=() normal_entries=() deprioritized_entries=() candidates=() shown=()
    local entry count shown_count
    for entry in "${entries[@]}"; do
        if _zsh_rune_match_any "$entry" "${(@)prefer_patterns}"; then
            preferred_entries+=("$entry")
        elif _zsh_rune_match_any "$entry" "${(@)skip_patterns}"; then
            continue
        elif _zsh_rune_match_any "$entry" "${(@)deprioritize_patterns}"; then
            deprioritized_entries+=("$entry")
        else
            normal_entries+=("$entry")
        fi
    done

    candidates=( "${(@)preferred_entries}" "${(@)normal_entries}" "${(@)deprioritized_entries}" )

    count=${#candidates}
    if (( count > 0 )); then
        shown=( "${(@)candidates[1,10]}" )
        shown_count=${#shown}
        ctx+=$'\n'"Files: ${(j:, :)shown}"
        (( count > shown_count )) && ctx+=" (+$((count - shown_count)) more)"
    fi
    if (( in_git_repo )); then
        local branch gst status_line
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        IFS= read -r status_line < <(git status --porcelain 2>/dev/null)
        [[ -n "$status_line" ]] && gst=dirty || gst=clean
        ctx+=$'\n'"Git: ${branch:-detached} ($gst)"
    fi

    # Available commands
    local -a tools=()
    local tool
    for tool in \
        git fd rg bat eza jq fzf zoxide trash docker \
        brew apt pacman curl wget systemctl \
        sd dust duf procs btop htop hyperfine xh \
        rsync tmux make python3 node \
        pip cargo go npm yarn pnpm bun \
        nvm fnm pyenv rbenv rustup mise; do
        command -v "$tool" &>/dev/null && tools+=("$tool")
    done
    (( ${#tools} )) && ctx+=$'\n'"Commands: ${(j:, :)tools}"

    printf '%s' "$ctx"
}
