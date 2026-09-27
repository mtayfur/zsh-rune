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
# ZSH_RUNE_PROMPT_EXTEND — optional extra rules for command generation
# ZSH_RUNE_CONTEXT_RULES_FILE — optional override for file filtering rules

typeset -ga _ZSH_RUNE_THREAD_Q=()
typeset -ga _ZSH_RUNE_THREAD_A=()
typeset -g _ZSH_RUNE_PENDING_IDX=""

# ── Helpers ───────────────────────────────────────────────────────────────────

_zsh_rune_check_deps() {
    if ! command -v jq &>/dev/null; then
        printf 'Error: jq is required (install with: apt install jq, brew install jq, etc.)' >&2
        return 1
    fi
    if ! command -v curl &>/dev/null; then
        printf 'Error: curl is required' >&2
        return 1
    fi
}

_zsh_rune_make_tempdir() {
    emulate -L zsh

    local tmpdir="${TMPDIR:-/tmp}"
    tmpdir="${tmpdir%/}"

    mktemp -d "${tmpdir}/zsh-rune.XXXXXX" 2>/dev/null
}

_zsh_rune_system_prompt() {
    emulate -L zsh
    local prompt_file="${ZSH_RUNE_SYSTEM_PROMPT_FILE:-${_zsh_rune_plugin_dir}/zsh-rune-prompt.txt}"
    if [[ ! -r "$prompt_file" ]]; then
        printf 'Error: system prompt file not found: %s' "$prompt_file" >&2
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
    local text="$1" outer header
    local fence='```'
    local think_open='<think>'
    local think_close='</think>'

    # Inspect wrappers on a copy: trimming shell text can remove escaped spaces.
    outer=$(_zsh_rune_trim_text "$text")

    # Only unwrap leading reasoning, never tags inside shell strings or heredocs.
    while [[ "$outer" == "${think_open}"* ]]; do
        if [[ "$outer" != *"${think_close}"* ]]; then
            printf 'Error: incomplete reasoning block' >&2
            return 1
        fi
        text="${text#*"${think_close}"}"
        outer=$(_zsh_rune_trim_text "$text")
    done

    # A fence must wrap the whole response. Preserve its contents verbatim.
    if [[ "$outer" == "${fence}"* ]]; then
        header="${outer%%$'\n'*}"
        case "$header" in
            '```'|'```zsh'|'```sh'|'```bash'|'```shell') ;;
            *) printf 'Error: unsupported command wrapper' >&2; return 1 ;;
        esac
        if [[ "$outer" != *$'\n'"${fence}" ]]; then
            printf 'Error: incomplete command fence' >&2
            return 1
        fi
        text="${outer#*$'\n'}"
        text="${text%"${fence}"}"
        text="${text%$'\n'}"
    elif [[ "$outer" == '`'*'`' && "$outer" != *$'\n'* ]]; then
        # Only unwrap a single inline-code pair around the entire response.
        local inner="${outer[2,-2]}"
        if [[ "$inner" != *'`'* ]]; then
            text="$inner"
        fi
    fi

    if [[ -z "${text//[[:space:]]/}" ]]; then
        printf 'Error: empty command' >&2
        return 1
    fi

    printf '%s' "$text"
}

_zsh_rune_pending_clear() {
    emulate -L zsh
    _ZSH_RUNE_PENDING_IDX=""
}

_zsh_rune_thread_drop_pending_response() {
    emulate -L zsh

    [[ -z "$_ZSH_RUNE_PENDING_IDX" ]] && return

    local idx=$(( _ZSH_RUNE_PENDING_IDX ))
    if (( idx >= 1 && idx <= ${#_ZSH_RUNE_THREAD_A} )); then
        _ZSH_RUNE_THREAD_A[$idx]=""
    fi

    _zsh_rune_pending_clear
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
    local query="$1" cmd="$2"

    _ZSH_RUNE_THREAD_Q+=("$query")
    _ZSH_RUNE_THREAD_A+=("$cmd")
    _zsh_rune_thread_trim

    _ZSH_RUNE_PENDING_IDX=${#_ZSH_RUNE_THREAD_A}
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
        filter+="{role:\"user\",content:\$q${i}}"
        if [[ -n "${_ZSH_RUNE_THREAD_A[$(( start + i - 1 ))]}" ]]; then
            filter+=",{role:\"assistant\",content:\$a${i}}"
        fi
    done
    filter+=']'

    jq -c -n "${jq_args[@]}" "$filter"
}

# ── API ───────────────────────────────────────────────────────────────────────

_zsh_rune_query() {
    emulate -L zsh
    local query="$1" history_json="${2:-[]}"

    _zsh_rune_check_deps || return 1

    if [[ -z "$ZSH_RUNE_API_KEY" ]]; then
        printf 'Error: ZSH_RUNE_API_KEY not set' >&2
        return 1
    fi

    # Compute expensive values once
    local sys_prompt ctx_all
    sys_prompt=$(_zsh_rune_system_prompt) || return 1
    ctx_all=$(_zsh_rune_context_all) || { printf 'Error: cannot collect shell context' >&2; return 1; }

    local payload
    payload=$(jq -c -n \
        --arg model "$ZSH_RUNE_MODEL" \
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
        }') || { printf 'Error: cannot build API request' >&2; return 1; }

    local response curl_exit http_code
    response=$(curl -sS \
        --connect-timeout 5 \
        --max-time "${ZSH_RUNE_TIMEOUT}" \
        --write-out $'\n%{http_code}' \
        -H "Authorization: Bearer ${ZSH_RUNE_API_KEY}" \
        -H "Content-Type: application/json" \
        -H "HTTP-Referer: https://github.com/zsh-rune" \
        -H "X-Title: zsh-rune" \
        -d "$payload" \
        "https://openrouter.ai/api/v1/chat/completions" 2>/dev/null)
    curl_exit=$?

    if (( curl_exit != 0 )); then
        case $curl_exit in
            6)  printf 'Error: cannot resolve openrouter.ai — check DNS' ;;
            7)  printf 'Error: connection refused — check network' ;;
            28) printf 'Error: request timed out (%ss)' "$ZSH_RUNE_TIMEOUT" ;;
            35) printf 'Error: SSL/TLS handshake failed' ;;
            *)  printf 'Error: curl failed (exit %d)' "$curl_exit" ;;
        esac >&2
        return 1
    fi

    http_code="${response##*$'\n'}"
    response="${response%$'\n'*}"
    if [[ "$http_code" != 2[0-9][0-9] ]]; then
        local err
        err=$(printf '%s' "$response" | jq -r '.error.message | select(type == "string")' 2>/dev/null)
        printf 'Error: HTTP %s — %s' "$http_code" "${err:-request failed}" >&2
        return 1
    fi

    local result
    result=$(printf '%s' "$response" | jq -ers '
        if length != 1 then error("expected one response object") else .[0] end
        | if .error != null then error(.error.message // "API error") else .choices[0] end
        | if .error != null then error(.error.message // "provider error")
          elif .finish_reason == "length" then error("response truncated at the token limit")
          elif .finish_reason != "stop" then error("generation did not complete (\(.finish_reason // "missing finish reason"))")
          elif (.message.content | type) != "string" then error("missing command text")
          else .message.content end
    ' 2>&1) || {
        printf 'Error: invalid API response — %s' "${result:-empty response}" >&2
        return 1
    }

    _zsh_rune_sanitize "$result"
}

# ── Widget ────────────────────────────────────────────────────────────────────

_zsh_rune_accept_line() {
    if [[ "$BUFFER" == *$'\n'* ]]; then
        zle _zsh-rune-original-accept-line -- "$@"
        return
    fi

    local mode="" history_depth=0 query=""

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
        zle _zsh-rune-original-accept-line -- "$@"
        return
    fi

    if [[ -z "${query//[[:space:]]/}" ]]; then
        zle _zsh-rune-original-accept-line -- "$@"
        return
    fi

    local history_json='[]'
    if [[ "$mode" == 'new' ]]; then
        # A fresh request should not leave the previous follow-up thread available.
        _zsh_rune_thread_clear
    else
        _zsh_rune_thread_drop_pending_response
        history_json=$(_zsh_rune_history_messages_json "$history_depth") || {
            zle -M 'Error: cannot build follow-up history'
            return 1
        }
    fi

    local saved="$BUFFER" saved_cursor=$CURSOR
    local -a frames=("✧" "✦" "⟡" "✦")
    local frame=0 tmpdir="" pid=0 status_fd="" cancelled=0 completed=0 query_exit result err

    setopt local_options local_traps no_notify
    trap 'cancelled=1' INT
    {
        zmodload zsh/system 2>/dev/null || { zle -M 'Error: zsh/system module is required'; return 1; }
        tmpdir=$(_zsh_rune_make_tempdir) || { zle -M 'Error: cannot create temp directory'; return 1; }

        # Process substitution avoids job notices; MONITOR still creates a process group.
        # The pipe carries the PID and exit status, since this worker is not wait-able.
        setopt monitor
        exec {status_fd}< <(
            print -r -- "$sysparams[pid]"
            if _zsh_rune_query "$query" "$history_json" >"$tmpdir/response" 2>"$tmpdir/error"; then
                print -r -- 0
            else
                print -r -- "$?"
            fi
        ) || { zle -M 'Error: cannot start request'; return 1; }

        if ! IFS= read -r -u $status_fd pid || [[ "$pid" != <1-> ]]; then
            pid=0
            zle -M 'Error: cannot read request PID'
            return 1
        fi
        # Older zsh gives the terminal to the worker. After its PID handshake,
        # a monitored foreground command returns the terminal to this shell.
        command true
        unsetopt monitor

        while (( ! cancelled )) && kill -0 $pid 2>/dev/null; do
            BUFFER="${saved} ${frames[$(( (frame % 4) + 1 ))]}"
            zle -R
            frame=$((frame + 1))
            sleep 0.15
        done
        (( cancelled )) && return 130
        if ! IFS= read -r -u $status_fd query_exit || [[ "$query_exit" != <0-255> ]]; then
            query_exit=1
        fi
        pid=0
        (( cancelled )) && return 130

        if (( query_exit != 0 )); then
            err=$(<"$tmpdir/error")
            zle -M "${err:-Error: request failed (exit ${query_exit})}"
            return 1
        fi
        result=$(<"$tmpdir/response")
        if [[ -z "${result//[[:space:]]/}" ]]; then
            zle -M 'Error: empty response'
            return 1
        fi

        # Keep long commands from adding seconds of animation latency.
        if (( ZSH_RUNE_ANIM )); then
            local -F SECONDS=0
            local i step=$(( (${#result} + 29) / 30 ))
            for (( i = step; i < ${#result} && SECONDS < 0.3 && ! cancelled; i += step )); do
                BUFFER="${saved}"$'\n'"${result[1,$i]}"
                CURSOR=$#BUFFER
                zle -R
                sleep 0.01
            done
        fi
        (( cancelled )) && return 130

        BUFFER="$result"
        CURSOR=$#BUFFER
        _zsh_rune_thread_append "$query" "$result"
        (( ZSH_RUNE_HISTORY )) && print -s -- "$saved"
        completed=1
    } always {
        # Do not let another Ctrl+C interrupt cleanup.
        trap '' INT
        if (( pid > 0 )); then
            kill -TERM -- -$pid 2>/dev/null
            IFS= read -r -u $status_fd query_exit 2>/dev/null || true
        fi
        if [[ -n "$status_fd" ]]; then
            exec {status_fd}<&-
        fi
        if [[ -n "$tmpdir" ]]; then
            rm -f -- "$tmpdir/response" "$tmpdir/error"
            rmdir -- "$tmpdir"
        fi
        if (( ! completed || cancelled )); then
            BUFFER="$saved"
            CURSOR=$saved_cursor
        fi
        if (( cancelled )); then
            _zsh_rune_thread_drop_pending_response
            zle -M 'Request cancelled'
        fi
        zle reset-prompt
    }
}

_zsh_rune_preexec() {
    emulate -L zsh
    local executed="$1"

    [[ -z "$_ZSH_RUNE_PENDING_IDX" ]] && return

    local idx=$(( _ZSH_RUNE_PENDING_IDX ))
    if (( idx >= 1 && idx <= ${#_ZSH_RUNE_THREAD_A} )); then
        _ZSH_RUNE_THREAD_A[$idx]="$executed"
    fi

    _zsh_rune_pending_clear
}

_zsh_rune_send_break() {
    emulate -L zsh

    _zsh_rune_thread_drop_pending_response
    zle _zsh-rune-original-send-break -- "$@"
}

zsh-rune() {
    print 'zsh-rune: CLI mode has been removed. Use interactive mode instead: type "# your request" and press Enter.' >&2
    return 1
}

# ── Init ──────────────────────────────────────────────────────────────────────

_zsh_rune_init() {
    zle -A accept-line _zsh-rune-original-accept-line
    zle -A send-break _zsh-rune-original-send-break
    zle -N accept-line _zsh_rune_accept_line
    zle -N send-break _zsh_rune_send_break
    add-zsh-hook -d preexec _zsh_rune_preexec
    add-zsh-hook preexec _zsh_rune_preexec
    # Ctrl+C can leave ZLE without invoking the send-break widget.
    add-zsh-hook precmd _zsh_rune_thread_drop_pending_response
    add-zsh-hook -d precmd _zsh_rune_init
}
add-zsh-hook precmd _zsh_rune_init
