#!/usr/bin/env zsh
# zsh-rune — AI command completion via OpenRouter
# Type "# your request" and press Enter, or: zsh-rune "your request"

# Prevent double-sourcing
(( ${+_ZSH_RUNE_LOADED} )) && return
_ZSH_RUNE_LOADED=1

autoload -Uz add-zsh-hook

# ── Config ────────────────────────────────────────────────────────────────────

: ${ZSH_RUNE_MODEL:="qwen/qwen3.5-35b-a3b"}
: ${ZSH_RUNE_TIMEOUT:=30}
: ${ZSH_RUNE_ANIM:=1}
: ${ZSH_RUNE_HISTORY:=1}
# ZSH_RUNE_PROMPT_EXTEND — optional extra rules appended to the system prompt

# ── Helpers ───────────────────────────────────────────────────────────────────

_zsh_rune_escape_json() {
    emulate -L zsh
    printf '%s' "$1" | perl -0777 -pe \
        's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g; s/\f/\\f/g; s/\x08/\\b/g; s/[\x00-\x07\x0B\x0E-\x1F]//g'
}

_zsh_rune_context() {
    emulate -L zsh
    local ctx="Shell: zsh ${ZSH_VERSION}"
    ctx+=$'\n'"Dir: ${PWD}"

    # Directory contents
    local count
    count=$(ls -1 2>/dev/null | wc -l | tr -d ' ')
    if (( count <= 20 )); then
        local files
        files=$(ls -1 2>/dev/null | head -10 | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
        [[ -n "$files" ]] && ctx+=$'\n'"Files: $files"
        (( count > 10 )) && ctx+=" (+$((count - 10)) more)"
    else
        ctx+=$'\n'"Files: $count total"
    fi

    # Git info
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        local branch gst
        branch=$(git branch --show-current 2>/dev/null)
        [[ -n $(git status --porcelain 2>/dev/null) ]] && gst=dirty || gst=clean
        ctx+=$'\n'"Git: $branch ($gst)"
    fi

    # Project type
    local ptype=
    [[ -f package.json   ]] && ptype=node
    [[ -f Cargo.toml     ]] && ptype=rust
    [[ -f go.mod         ]] && ptype=go
    [[ -f requirements.txt || -f pyproject.toml || -f setup.py ]] && ptype=python
    [[ -f Gemfile        ]] && ptype=ruby
    [[ -f composer.json  ]] && ptype=php
    [[ -f pom.xml || -f build.gradle ]] && ptype=java
    [[ -n "$ptype" ]] && ctx+=$'\n'"Project: $ptype"

    ctx+=$'\n'"OS: $(uname -s) $(uname -m)"

    # Recent commands (last 3, deduped)
    if (( $+commands[fc] )) || whence -w fc &>/dev/null; then
        local -a recent
        recent=("${(@f)$(fc -ln -3 -1 2>/dev/null)}")
        if (( ${#recent} > 0 )); then
            local hist_str=""
            local prev=""
            for cmd in "${recent[@]}"; do
                cmd="${cmd## }"  # strip leading space
                [[ -n "$cmd" && "$cmd" != "$prev" ]] && {
                    [[ -n "$hist_str" ]] && hist_str+="; "
                    hist_str+="$cmd"
                    prev="$cmd"
                }
            done
            [[ -n "$hist_str" ]] && ctx+=$'\n'"Recent: $hist_str"
        fi
    fi

    # Available tools
    local -a tools=()
    command -v docker    &>/dev/null && tools+=(docker)
    command -v kubectl   &>/dev/null && tools+=(kubectl)
    command -v npm       &>/dev/null && tools+=(npm)
    command -v yarn      &>/dev/null && tools+=(yarn)
    command -v pnpm      &>/dev/null && tools+=(pnpm)
    command -v bun       &>/dev/null && tools+=(bun)
    command -v cargo     &>/dev/null && tools+=(cargo)
    command -v pip       &>/dev/null && tools+=(pip)
    command -v conda     &>/dev/null && tools+=(conda)
    command -v brew      &>/dev/null && tools+=(brew)
    command -v systemctl &>/dev/null && tools+=(systemctl)
    command -v journalctl &>/dev/null && tools+=(journalctl)
    (( ${#tools} > 0 )) && ctx+=$'\n'"Tools: ${(j:, :)tools}"

    printf '%s' "$ctx"
}

_zsh_rune_system_prompt() {
    emulate -L zsh
    local p='You are a zsh command generator. Convert natural language into a single executable zsh command.

Rules:
- Output ONLY the raw command — no explanations, no markdown, no code fences, no backticks
- Never wrap output in ```bash```, ```zsh```, ```sh```, or ``` blocks
- Never prefix with $ or #
- Do not add comments after the command
- Piping (|) and chaining (&&, ||, ;) are acceptable when needed
- Use single quotes for literal strings; double quotes when expansion is needed
- Escape special characters properly
- If the request is ambiguous, prefer the safer non-destructive option
- If the request is impossible or nonsensical, output: echo "Error: <brief reason>"'

    [[ -n "$ZSH_RUNE_PROMPT_EXTEND" ]] && p+=$'\n\n'"$ZSH_RUNE_PROMPT_EXTEND"
    printf '%s' "$p"
}

_zsh_rune_sanitize() {
    emulate -L zsh
    local text="$1"

    # Strip leading/trailing whitespace
    text="${text## }"
    text="${text%% }"

    # Remove markdown code fences: ```lang\n...\n```
    if [[ "$text" == '```'* ]]; then
        text=$(printf '%s' "$text" | perl -0777 -pe 's/^```[a-z]*\n?(.*?)\n?```$/\1/s')
    fi

    # Remove single backtick wrapping: `cmd`
    if [[ "$text" == '`'* && "$text" == *'`' && "$text" != *'`'*'`'*'`'* ]]; then
        text="${text#\`}"
        text="${text%\`}"
    fi

    # Remove leading $ or # prompt
    text="${text#\$ }"
    text="${text#\# }"

    # If multi-line, take the last non-empty line (LLMs sometimes add explanation first)
    if [[ "$text" == *$'\n'* ]]; then
        local last_line=""
        local line
        while IFS= read -r line; do
            [[ -n "${line// /}" ]] && last_line="$line"
        done <<< "$text"
        [[ -n "$last_line" ]] && text="$last_line"
    fi

    # Final trim
    text="${text## }"
    text="${text%% }"

    printf '%s' "$text"
}

# ── API ───────────────────────────────────────────────────────────────────────

_zsh_rune_query() {
    emulate -L zsh
    local query="$1" model="${2:-$ZSH_RUNE_MODEL}"

    if [[ -z "$ZSH_RUNE_API_KEY" ]]; then
        printf 'Error: ZSH_RUNE_API_KEY not set'; return 1
    fi

    local escaped_sys escaped_ctx escaped_q
    escaped_sys=$(_zsh_rune_escape_json "$(_zsh_rune_system_prompt)")
    escaped_ctx=$(_zsh_rune_escape_json "$(_zsh_rune_context)")
    escaped_q=$(_zsh_rune_escape_json "$query")

    local payload
    payload=$(cat <<EOF
{"model":"${model}","stream":false,"messages":[{"role":"system","content":[{"type":"text","text":"${escaped_sys}","cache_control":{"type":"ephemeral"}}]},{"role":"user","content":"Context:\n${escaped_ctx}\n\nCommand: ${escaped_q}"}],"max_tokens":256,"temperature":0.2}
EOF
)

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
    if command -v jq &>/dev/null; then
        result=$(printf '%s' "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        if [[ -z "$result" ]]; then
            local err
            err=$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)
            printf 'Error: %s' "${err:-empty response}"; return 1
        fi
    else
        result=$(printf '%s' "$response" | \
            perl -0777 -ne 'print $1 if /"content":"((?:[^"\\]|\\.)*)"/' 2>/dev/null)
        if [[ -z "$result" ]]; then
            printf 'Error: failed to parse response (install jq for better handling)'; return 1
        fi
        result=$(printf '%s' "$result" | sed 's/\\n/\n/g; s/\\t/\t/g; s/\\r//g; s/\\"/"/g; s/\\\\/\\/g')
    fi

    _zsh_rune_sanitize "$result"
}

# ── Widget ────────────────────────────────────────────────────────────────────

_zsh_rune_accept_line() {
    if [[ "$BUFFER" != '# '* ]] || [[ "$BUFFER" == *$'\n'* ]]; then
        zle .accept-line; return
    fi

    local query="${BUFFER:2}" saved="$BUFFER"

    # Don't send empty queries
    if [[ -z "${query// /}" ]]; then
        zle .accept-line; return
    fi

    local -a dots=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local frame=0 tmpfile
    tmpfile=$(mktemp)

    setopt local_options no_monitor no_notify
    (_zsh_rune_query "$query" >"$tmpfile" 2>&1) &
    local pid=$!

    # Spinner while waiting
    while kill -0 $pid 2>/dev/null; do
        BUFFER="${saved} ${dots[$((frame % 10))]}"
        frame=$((frame + 1))
        zle -R
        sleep 0.1
    done

    local cmd
    cmd=$(<"$tmpfile")
    rm -f "$tmpfile"

    if [[ -n "$cmd" && "$cmd" != Error:* ]]; then
        # Save original query to history
        (( ZSH_RUNE_HISTORY )) && print -s -- "$saved"

        # Typewriter animation
        if (( ZSH_RUNE_ANIM )); then
            BUFFER=""
            zle -R
            local i
            for (( i=1; i<=${#cmd}; i++ )); do
                BUFFER+="${cmd[$i]}"
                CURSOR=$#BUFFER
                zle -R
                sleep 0.01
            done
        else
            BUFFER="$cmd"
        fi
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

    # Parse flags
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
  ZSH_RUNE_MODEL            Model to use (default: qwen/qwen3.5-35b-a3b)
  ZSH_RUNE_TIMEOUT          API timeout in seconds (default: 30)
  ZSH_RUNE_ANIM             Typewriter animation 0/1 (default: 1)
  ZSH_RUNE_HISTORY          Save queries to shell history 0/1 (default: 1)
  ZSH_RUNE_PROMPT_EXTEND    Extra rules for the system prompt

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
        print "Usage: zsh-rune \"your request\" (try --help)" >&2; return 1
    fi

    local cmd
    cmd=$(_zsh_rune_query "$query" "$model")
    if [[ $? -ne 0 || -z "$cmd" || "$cmd" == Error:* ]]; then
        print "${cmd:-Error: no response}" >&2; return 1
    fi

    # If in ZLE context, set BUFFER; otherwise print
    if zle 2>/dev/null; then
        BUFFER="$cmd"
        CURSOR=$#BUFFER
    else
        print -r -- "$cmd"
    fi
}

# ── Init ──────────────────────────────────────────────────────────────────────

[[ -z "$ZSH_RUNE_API_KEY" ]] && \
    print "zsh-rune: ZSH_RUNE_API_KEY not set — get yours at https://openrouter.ai/keys" >&2

_zsh_rune_init() {
    zle -N accept-line _zsh_rune_accept_line
    add-zsh-hook -d precmd _zsh_rune_init
}
add-zsh-hook precmd _zsh_rune_init
