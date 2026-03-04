#!/usr/bin/env zsh
# zsh-rune context module — minimal context for AI command generation

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
    local -a entries=( *(N) )
    local count=${#entries}
    if (( count > 0 && count <= 20 )); then
        local -a shown=( "${(@)entries[1,10]}" )
        ctx+=$'\n'"Files: ${(j:, :)shown}"
        (( count > 10 )) && ctx+=" (+$((count - 10)) more)"
    elif (( count > 20 )); then
        ctx+=$'\n'"Files: $count total"
    fi
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        local branch gst
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        [[ -n $(git status --porcelain 2>/dev/null | head -1) ]] && gst=dirty || gst=clean
        ctx+=$'\n'"Git: ${branch:-detached} ($gst)"
    fi

    # Available tools
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
    (( ${#tools} )) && ctx+=$'\n'"Tools: ${(j:, :)tools}"

    printf '%s' "$ctx"
}
