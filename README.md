# zsh-rune

> AI command completion for ZSH via OpenRouter.

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

## Usage

### Interactive Mode
Type `# ` followed by your request and press **Enter**:

```zsh
# kill the process on port 8080
# show disk usage of top 10 directories
# find recent git changes with authorship
```

### CLI Mode
Use the `zsh-rune` command directly:

```zsh
zsh-rune "list all npm packages with outdated versions"
zsh-rune -m openai/gpt-4o "search for files modified today"
zsh-rune --help
```

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
| `ZSH_RUNE_PROMPT_EXTEND` | — | Extra instructions appended to the system prompt |

### Custom instructions

```zsh
export ZSH_RUNE_PROMPT_EXTEND="Always use ripgrep instead of grep. Prefer fd over find."
```

## Requirements

- ZSH 5.0+
- `curl`
- `jq`
