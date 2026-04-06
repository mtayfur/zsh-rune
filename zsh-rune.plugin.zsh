#!/usr/bin/env zsh
# zsh-rune — AI command completion via OpenRouter
# Type "# your request" and press Enter

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
: ${ZSH_RUNE_MAX_THREAD_ROUNDS:=10}
# ZSH_RUNE_PROMPT_EXTEND — optional extra rules appended to the system prompt
# ZSH_RUNE_CONTEXT_RULES_FILE — optional override for file filtering rules

typeset -ga _ZSH_RUNE_THREAD_Q=()
typeset -ga _ZSH_RUNE_THREAD_A=()
typeset -g _ZSH_RUNE_PENDING_IDX=""
typeset -g _ZSH_RUNE_PENDING_QUERY=""

# ── Helpers ───────────────────────────────────────────────────────────────────

_zsh_rune_check_deps() {
    if ! command -v jq &>/dev/null; then
        printf 'Error: jq is required (install with: apt install jq, brew install jq, etc.)' >&2
        return 1
    fi
}

_zsh_rune_make_tempfile() {
    emulate -L zsh

    local tmpdir="${TMPDIR:-/tmp}"
    tmpdir="${tmpdir%/}"

    mktemp "${tmpdir}/zsh-rune.XXXXXX" 2>/dev/null
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

_zsh_rune_trim_text() {
    emulate -L zsh
    local text="$1"
    text="${text#"${text%%[^[:space:]]*}"}"
    text="${text%"${text##*[^[:space:]]}"}"
    printf '%s' "$text"
}

_zsh_rune_sanitize() {
    emulate -L zsh
    local text="$1"
    local before after
    local fence='```'
    local think_open='<think>'
    local think_close='</think>'

    text=$(_zsh_rune_trim_text "$text")

    # Remove reasoning blocks that some models emit before the command.
    while [[ "$text" == *"${think_open}"*"${think_close}"* ]]; do
        before="${text%%"${think_open}"*}"
        after="${text#*"${think_close}"}"
        text="${before}${after}"
    done

    if [[ "$text" == *"${think_open}"* ]]; then
        text="${text%%"${think_open}"*}"
    fi

    text=$(_zsh_rune_trim_text "$text")

    # Extract the first fenced block if the model wrapped the command.
    if [[ "$text" == *${fence}* ]]; then
        local fenced="${text#*${fence}}"
        if [[ "$fenced" == *$'\n'* ]]; then
            fenced="${fenced#*$'\n'}"
            if [[ "$fenced" == *$'\n'${fence}* ]]; then
                text="${fenced%%$'\n'${fence}*}"
            fi
        fi
    fi

    text=$(_zsh_rune_trim_text "$text")

    local -a lines
    lines=("${(@f)text}")

    while (( ${#lines} )); do
        local first
        first=$(_zsh_rune_trim_text "${lines[1]}")

        if [[ -z "$first" ]]; then
            lines=("${(@)lines[2,-1]}")
            continue
        fi

        case "$first" in
            \$\ *)
                lines[1]="${first#\$ }"
                break
                ;;
            \#\ *)
                lines[1]="${first#\# }"
                break
                ;;
            Command:*|Reasoning:*|Explanation:*|Use\ this\ *|Run\ this\ *|Here\ is\ *command:*|The\ command\ *)
                lines=("${(@)lines[2,-1]}")
                continue
                ;;
        esac

        break
    done

    text="${(F)lines}"
    text=$(_zsh_rune_trim_text "$text")

    # Remove single backtick wrapping: `cmd`
    if [[ "$text" == \`*\` && "$text" != *\`*\`*\`* ]]; then
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

_zsh_rune_pending_clear() {
    emulate -L zsh
    _ZSH_RUNE_PENDING_IDX=""
    _ZSH_RUNE_PENDING_QUERY=""
}

_zsh_rune_thread_clear() {
    emulate -L zsh
    _ZSH_RUNE_THREAD_Q=()
    _ZSH_RUNE_THREAD_A=()
    _zsh_rune_pending_clear
}

_zsh_rune_thread_trim() {
    emulate -L zsh

    local max_rounds=${ZSH_RUNE_MAX_THREAD_ROUNDS:-10}
    (( max_rounds < 1 )) && max_rounds=1

    local total=${#_ZSH_RUNE_THREAD_Q}
    local extra=$(( total - max_rounds ))
    (( extra <= 0 )) && return

    local start=$(( extra + 1 ))
    local end=$total
    _ZSH_RUNE_THREAD_Q=("${(@)_ZSH_RUNE_THREAD_Q[$start,$end]}")
    _ZSH_RUNE_THREAD_A=("${(@)_ZSH_RUNE_THREAD_A[$start,$end]}")
}

_zsh_rune_thread_append() {
    emulate -L zsh
    local query="$1" cmd="$2" track_pending="${3:-1}"

    _ZSH_RUNE_THREAD_Q+=("$query")
    _ZSH_RUNE_THREAD_A+=("$cmd")
    _zsh_rune_thread_trim

    if (( track_pending )); then
        _ZSH_RUNE_PENDING_IDX=${#_ZSH_RUNE_THREAD_A}
        _ZSH_RUNE_PENDING_QUERY="$query"
    else
        _zsh_rune_pending_clear
    fi
}

_zsh_rune_thread_finalize_pending() {
    emulate -L zsh
    local executed="$1"

    [[ -z "$_ZSH_RUNE_PENDING_IDX" ]] && return

    local idx=$(( _ZSH_RUNE_PENDING_IDX ))
    if (( idx >= 1 && idx <= ${#_ZSH_RUNE_THREAD_A} )); then
        _ZSH_RUNE_THREAD_A[$idx]="$executed"
    fi

    _zsh_rune_pending_clear
}

_zsh_rune_history_messages_json() {
    emulate -L zsh

    local max_depth="$1"
    local total=${#_ZSH_RUNE_THREAD_Q}
    if (( total == 0 || max_depth < 1 )); then
        printf '[]'
        return
    fi

    (( max_depth > total )) && max_depth=$total
    local start=$(( total - max_depth + 1 ))

    local -a jq_args=()
    local i round=0
    for (( i = start; i <= total; i++ )); do
        round=$(( round + 1 ))
        jq_args+=(--arg "q${round}" "${_ZSH_RUNE_THREAD_Q[$i]}")
        jq_args+=(--arg "a${round}" "${_ZSH_RUNE_THREAD_A[$i]}")
    done

    local filter='['
    for (( i = 1; i <= round; i++ )); do
        (( i > 1 )) && filter+=','
        filter+="{role:\"user\",content:\$q${i}},{role:\"assistant\",content:\$a${i}}"
    done
    filter+=']'

    jq -c -n "${jq_args[@]}" "$filter"
}

# ── API ───────────────────────────────────────────────────────────────────────

_zsh_rune_query() {
    emulate -L zsh
    local query="$1" model="${2:-$ZSH_RUNE_MODEL}" history_json="${3:-[]}"

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
        --argjson history_messages "$history_json" \
        '{
            model: $model,
            stream: false,
            messages: (
                [
                    {
                        role: "system",
                        content: [
                            { type: "text", text: $sys_prompt, cache_control: { type: "ephemeral" } }
                        ]
                    }
                ]
                + $history_messages
                + [
                    { role: "user", content: "Context:\n\($ctx_all)\n\nRequest: \($query)" }
                ]
            ),
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
    if [[ "$BUFFER" == *$'\n'* ]]; then
        zle .accept-line
        return
    fi

    local mode="" history_depth=0 query="" saved="$BUFFER"

    if [[ "$BUFFER" == '# '* ]]; then
        mode="new"
        query="${BUFFER:2}"
    elif [[ "$BUFFER" == '## '* ]]; then
        mode="followup"
        history_depth=1
        query="${BUFFER:3}"
    elif [[ "$BUFFER" == '#'<->' '* ]]; then
        local remainder="${BUFFER#\#}"
        local depth_text="${remainder%% *}"
        history_depth=$(( 10#$depth_text ))
        if (( history_depth < 1 )); then
            zle -M 'Error: follow-up depth must be >= 1'
            zle reset-prompt
            return 1
        fi
        mode="followup"
        query="${remainder#* }"
    else
        zle .accept-line
        return
    fi

    if [[ -z "${query//[[:space:]]/}" ]]; then
        zle .accept-line
        return
    fi

    if [[ "$mode" == 'new' ]]; then
        # A fresh request should not leave the previous follow-up thread available.
        _zsh_rune_thread_clear
    else
        _zsh_rune_pending_clear
    fi

    local history_json='[]'
    if [[ "$mode" == 'followup' ]]; then
        history_json=$(_zsh_rune_history_messages_json "$history_depth")
    fi

    local -a frames=("✧" "✦" "⟡" "✦")
    local frame=0 tmpfile
    tmpfile=$(_zsh_rune_make_tempfile) || { zle -M "Error: cannot create temp file"; zle reset-prompt; return 1; }

    setopt local_options no_monitor no_notify
    (_zsh_rune_query "$query" "$ZSH_RUNE_MODEL" "$history_json" >"$tmpfile" 2>&1) &
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
        _zsh_rune_thread_append "$query" "$cmd" 1

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

        # Optionally save the original "# request" to shell history — deferred
        # to preexec so it only fires if the command is actually run.
        BUFFER="$cmd"
        CURSOR=$#BUFFER
    else
        BUFFER="$saved"
        CURSOR=$#BUFFER
        zle -M "${cmd:-Error: no response}"
    fi
    zle reset-prompt
}

_zsh_rune_preexec() {
    emulate -L zsh

    [[ -z "$_ZSH_RUNE_PENDING_IDX" ]] && return

    # Save the original "# request" to zsh history only when the command is
    # actually executed — not when it was rejected with Ctrl+C.
    (( ZSH_RUNE_HISTORY )) && [[ -n "$_ZSH_RUNE_PENDING_QUERY" ]] && \
        print -s -- "$_ZSH_RUNE_PENDING_QUERY"

    _zsh_rune_thread_finalize_pending "$1"
}

_zsh_rune_send_break() {
    emulate -L zsh

    _zsh_rune_pending_clear
    zle .send-break
}

zsh-rune() {
    print 'zsh-rune: CLI mode has been removed. Use interactive mode instead: type "# your request" and press Enter.' >&2
    return 1
}

# ── Init ──────────────────────────────────────────────────────────────────────

_zsh_rune_init() {
    zle -N accept-line _zsh_rune_accept_line
    zle -N send-break _zsh_rune_send_break
    add-zsh-hook -d preexec _zsh_rune_preexec
    add-zsh-hook preexec _zsh_rune_preexec
    add-zsh-hook -d precmd _zsh_rune_init
}
add-zsh-hook precmd _zsh_rune_init
