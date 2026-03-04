#!/usr/bin/env zsh
# zsh-rune — AI command completion via OpenRouter
# Type "# your request" and press Enter, or: zsh-rune "your request"

# Prevent double-sourcing
(( ${+_ZSH_RUNE_LOADED} )) && return
_ZSH_RUNE_LOADED=1

autoload -Uz add-zsh-hook

# Load context module
_zsh_rune_plugin_dir="${${(%):-%x}:a:h}"
source "$_zsh_rune_plugin_dir/zsh-rune-context.sh"

# ── Config ────────────────────────────────────────────────────────────────────

: ${ZSH_RUNE_MODEL:="qwen/qwen3.5-35b-a3b"}
: ${ZSH_RUNE_TIMEOUT:=30}
: ${ZSH_RUNE_ANIM:=1}
: ${ZSH_RUNE_HISTORY:=1}
# ZSH_RUNE_PROMPT_EXTEND — optional extra rules appended to the system prompt

# ── Helpers ───────────────────────────────────────────────────────────────────

_zsh_rune_check_deps() {
    if ! command -v jq &>/dev/null; then
        printf 'Error: jq is required (install with: apt install jq, brew install jq, etc.)' >&2
        return 1
    fi
}

_zsh_rune_system_prompt() {
    emulate -L zsh
    local prompt_file="${ZSH_RUNE_SYSTEM_PROMPT_FILE:-${_zsh_rune_plugin_dir}/zsh-rune-prompt.txt}"
    if [[ ! -r "$prompt_file" ]]; then
        printf 'Error: system prompt file not found: %s' "$prompt_file"
        return 1
    fi
    local p
    p=$(<"$prompt_file")
    [[ -n "$ZSH_RUNE_PROMPT_EXTEND" ]] && p+=$'\n\n'"$ZSH_RUNE_PROMPT_EXTEND"
    printf '%s' "$p"
}

_zsh_rune_sanitize() {
    emulate -L zsh
    local text="$1"

    # Strip leading/trailing whitespace
    text="${text#"${text%%[^[:space:]]*}"}"
    text="${text%"${text##*[^[:space:]]}"}"

    # Remove markdown code fences: ```lang\n...\n```
    if [[ "$text" == '```'* ]]; then
        text="${text#\`\`\`*$'\n'}"  # strip opening fence + language tag
        text="${text%$'\n'\`\`\`}"   # strip closing fence
        # Re-trim
        text="${text#"${text%%[^[:space:]]*}"}"
        text="${text%"${text##*[^[:space:]]}"}"
    fi

    # Remove single backtick wrapping: `cmd`
    if [[ "$text" == '`'*'`' && "$text" != *'`'*'`'*'`'* ]]; then
        text="${text#\`}"
        text="${text%\`}"
    fi

    # Remove leading $ or # prompt markers
    text="${text#\$ }"
    text="${text#\# }"

    # Strip leading/trailing blank lines
    while [[ "$text" == $'\n'* ]]; do text="${text#$'\n'}"; done
    while [[ "$text" == *$'\n' ]]; do text="${text%$'\n'}"; done

    printf '%s' "$text"
}

# ── API ───────────────────────────────────────────────────────────────────────

_zsh_rune_query() {
    emulate -L zsh
    local query="$1" model="${2:-$ZSH_RUNE_MODEL}"

    _zsh_rune_check_deps || return 1

    if [[ -z "$ZSH_RUNE_API_KEY" ]]; then
        printf 'Error: ZSH_RUNE_API_KEY not set'
        return 1
    fi

    # Compute expensive values once
    local sys_prompt ctx_all
    sys_prompt=$(_zsh_rune_system_prompt) || { printf '%s' "$sys_prompt"; return 1; }
    ctx_all=$(_zsh_rune_context_all)

    local payload
    payload=$(jq -c -n \
        --arg model "$model" \
        --arg sys_prompt "$sys_prompt" \
        --arg ctx_all "$ctx_all" \
        --arg query "$query" \
        '{
            model: $model,
            stream: false,
            messages: [
                {
                    role: "system",
                    content: [
                        { type: "text", text: $sys_prompt, cache_control: { type: "ephemeral" } }
                    ]
                },
                { role: "user", content: "Context:\n\($ctx_all)\n\nRequest: \($query)" }
            ],
            max_tokens: 1024,
            temperature: 0.2
        }')

    local response curl_exit
    response=$(curl -sS \
        --connect-timeout 5 \
        --max-time "${ZSH_RUNE_TIMEOUT}" \
        -H "Authorization: Bearer ${ZSH_RUNE_API_KEY}" \
        -H "Content-Type: application/json" \
        -H "HTTP-Referer: https://github.com/zsh-rune" \
        -H "X-Title: zsh-rune" \
        -d "$payload" \
        "https://openrouter.ai/api/v1/chat/completions" 2>&1)
    curl_exit=$?

    if (( curl_exit != 0 )); then
        case $curl_exit in
            6)  printf 'Error: cannot resolve openrouter.ai — check DNS' ;;
            7)  printf 'Error: connection refused — check network' ;;
            28) printf 'Error: request timed out (%ss)' "$ZSH_RUNE_TIMEOUT" ;;
            35) printf 'Error: SSL/TLS handshake failed' ;;
            *)  printf 'Error: curl failed (exit %d)' "$curl_exit" ;;
        esac
        return 1
    fi

    local result
    result=$(printf '%s' "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    if [[ -z "$result" ]]; then
        local err
        err=$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)
        printf 'Error: %s' "${err:-empty response}"
        return 1
    fi

    _zsh_rune_sanitize "$result"
}

# ── Widget ────────────────────────────────────────────────────────────────────

_zsh_rune_accept_line() {
    # Only intercept single-line buffers starting with "# "
    if [[ "$BUFFER" == *$'\n'* || "$BUFFER" != '# '* ]]; then
        zle .accept-line
        return
    fi

    local query="${BUFFER:2}" saved="$BUFFER"

    if [[ -z "${query// /}" ]]; then
        zle .accept-line
        return
    fi

    local -a frames=("✧" "✦" "⟡" "✦")
    local frame=0 tmpfile
    tmpfile=$(mktemp) || { zle -M "Error: cannot create temp file"; return 1; }

    setopt local_options no_monitor no_notify
    (_zsh_rune_query "$query" >"$tmpfile" 2>&1) &
    local pid=$!

    while kill -0 $pid 2>/dev/null; do
        BUFFER="${saved} ${frames[$(( (frame % 4) + 1 ))]}"
        frame=$((frame + 1))
        zle -R
        sleep 0.15
    done
    wait $pid

    local cmd
    cmd=$(<"$tmpfile")
    rm -f "$tmpfile"

    if [[ -n "$cmd" && "$cmd" != Error:* ]]; then
        if (( ZSH_RUNE_ANIM )); then
            BUFFER="${saved}"$'\n'
            CURSOR=$#BUFFER
            zle -R
            local i
            for (( i = 1; i <= ${#cmd}; i++ )); do
                BUFFER+="${cmd[$i]}"
                CURSOR=$#BUFFER
                zle -R
                sleep 0.01
            done
        else
            BUFFER="${saved}"$'\n'"${cmd}"
        fi

        # Optionally save the original "# request" to shell history
        (( ZSH_RUNE_HISTORY )) && print -s -- "$saved"
        BUFFER="$cmd"
        CURSOR=$#BUFFER
    else
        BUFFER="$saved"
        CURSOR=$#BUFFER
        zle -M "${cmd:-Error: no response}"
    fi
    zle reset-prompt
}

# ── CLI ───────────────────────────────────────────────────────────────────────

zsh-rune() {
    emulate -L zsh

    _zsh_rune_check_deps || return 1

    local model="$ZSH_RUNE_MODEL"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                cat <<'HELP'
zsh-rune — AI command completion via OpenRouter

Usage:
  zsh-rune "your request"        Generate a command from natural language
  zsh-rune -m MODEL "request"    Use a specific model for this query
  # your request [Enter]          Interactive mode (in terminal)

Options:
  -m, --model MODEL    Override ZSH_RUNE_MODEL for this query
  -h, --help           Show this help

Config (set in ~/.zshrc):
  ZSH_RUNE_API_KEY        Required. Your OpenRouter API key
  ZSH_RUNE_MODEL          Model to use (default: qwen/qwen3.5-35b-a3b)
  ZSH_RUNE_TIMEOUT        API timeout in seconds (default: 30)
  ZSH_RUNE_ANIM           Typewriter animation 0/1 (default: 1)
  ZSH_RUNE_HISTORY        Save queries to shell history 0/1 (default: 1)
  ZSH_RUNE_PROMPT_EXTEND  Extra rules for the system prompt

https://github.com/zsh-rune
HELP
                return 0
                ;;
            -m|--model)
                shift
                model="$1"
                [[ -z "$model" ]] && { print "zsh-rune: -m requires a model name" >&2; return 1; }
                ;;
            --)
                shift; break ;;
            -*)
                print "zsh-rune: unknown option: $1 (try --help)" >&2; return 1 ;;
            *)
                break ;;
        esac
        shift
    done

    local query="$*"
    if [[ -z "$query" ]]; then
        print "Usage: zsh-rune \"your request\" (try --help)" >&2
        return 1
    fi

    local cmd
    cmd=$(_zsh_rune_query "$query" "$model")
    if (( $? != 0 )) || [[ -z "$cmd" || "$cmd" == Error:* ]]; then
        print "${cmd:-Error: no response}" >&2
        return 1
    fi

    print -r -- "$cmd"
}

# ── Init ──────────────────────────────────────────────────────────────────────

_zsh_rune_init() {
    zle -N accept-line _zsh_rune_accept_line
    add-zsh-hook -d precmd _zsh_rune_init
}
add-zsh-hook precmd _zsh_rune_init
