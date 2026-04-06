# zsh-rune

> AI command completion for ZSH via OpenRouter.

Supports `zsh` on macOS and Linux.

Type what you want in plain English, get the exact command — ready to run.

```zsh
$ # list docker containers and their sizes
$ docker ps --format "table {{.Names}}\t{{.Size}}"
```

## How it works

1. Type `# your request` and press **Enter**
2. A spinner plays while your request is sent to OpenRouter with shell context
3. The generated command types itself out in your terminal — review it, then press Enter to run

The command never runs automatically. You always see it first.

Interactive follow-ups keep a short in-memory thread for the current shell session:

- `# ` starts a new thread
- `## ` is shorthand for `#1 ` and reuses up to the last 1 round
- `#N ` reuses up to the last `N` rounds

## Usage

### Interactive Mode
Type `# ` followed by your request and press **Enter**:

```zsh
# kill the process on port 8080
# show disk usage of top 10 directories
# find recent git changes with authorship
```

Refine the previous result with follow-ups:

```zsh
# docker list containers
## also show sizes
#1 keep only running containers
#3 sort by size descending and keep the headers
# new unrelated task
```

Only the previous natural-language requests and generated or edited commands are sent as follow-up history. Command output is not captured.
If you cancel a suggested command with `Ctrl+C`, it stays in history — the model will see it and can avoid repeating the same mistake when you send a follow-up.

## Context

The plugin automatically sends shell context to help the model generate better commands:

- Shell version, OS, and architecture
- Current user and environment (WSL, display server, editor)
- Working directory and file listing
- Git branch and status
- Available tools (docker, npm, cargo, python3, etc.)

## Installation

### Oh My Zsh

```zsh
git clone https://github.com/mtayfur/zsh-rune ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-rune
```

Add to `~/.zshrc`:

```zsh
plugins=(... zsh-rune)
```

### Local development

Run the included install script to copy the plugin into your oh-my-zsh custom plugins directory:

```zsh
./install.sh
```

## Configuration

Set your API key — required:

```zsh
export ZSH_RUNE_API_KEY="sk-or-..."
```

Get a key at [openrouter.ai/keys](https://openrouter.ai/keys). The free tier works.

| Variable | Default | Description |
|---|---|---|
| `ZSH_RUNE_API_KEY` | — | **Required.** Your OpenRouter API key |
| `ZSH_RUNE_MODEL` | `qwen/qwen3.5-35b-a3b` | Any model from [openrouter.ai/models](https://openrouter.ai/models) |
| `ZSH_RUNE_TIMEOUT` | `30` | API request timeout in seconds |
| `ZSH_RUNE_ANIM` | `1` | Typewriter animation (`1` = on, `0` = off) |
| `ZSH_RUNE_HISTORY` | `1` | Save `# queries` to shell history (`1` = on, `0` = off) |
| `ZSH_RUNE_MAX_THREAD_ROUNDS` | `10` | Max rounds kept in memory for `##` / `#N` follow-ups |
| `ZSH_RUNE_PROMPT_EXTEND` | — | Extra instructions appended to the system prompt |
| `ZSH_RUNE_CONTEXT_RULES_FILE` | `zsh-rune-context-rules.zsh` | Optional override for file filtering and prioritization rules |

### Custom instructions

```zsh
export ZSH_RUNE_PROMPT_EXTEND="Always use ripgrep instead of grep. Prefer fd over find."
```

### Context file rules

The top-level `Files:` list is driven by `zsh-rune-context-rules.zsh`.
You can point the plugin at your own rules file:

```zsh
export ZSH_RUNE_CONTEXT_RULES_FILE="$HOME/.config/zsh-rune/context-rules.zsh"
```

The rules file is a zsh snippet that assigns three arrays:

```zsh
skip_patterns=( .git node_modules .venv )
deprioritize_patterns=( dist build target )
prefer_patterns=( README 'README.*' package.json pyproject.toml .gitignore )
```

Quote any pattern that contains `*` so it stays a pattern instead of expanding to files while the rules file is loaded.

`skip_patterns` is also extended automatically from readable ignore files, with de-duplication:

- Current directory: `.gitignore`, `.ignore`, `.fdignore`, `.rgignore`
- Git repo local excludes: `.git/info/exclude`
- Global git ignores: `core.excludesfile`, `~/.config/git/ignore`, `~/.gitignore`, `~/.gitignore_global`

Only simple top-level ignore entries are imported into `Files:` filtering. Nested path rules and unignore rules like `!keep-me` are ignored.

## Requirements

- ZSH 5.0+
- `curl`
- `jq`
