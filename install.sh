#!/usr/bin/env zsh
# install.sh — install zsh-rune into oh-my-zsh custom plugins

set -e

PLUGIN_NAME="zsh-rune"
PLUGIN_FILE="zsh-rune.plugin.zsh"
CONTEXT_FILE="zsh-rune-context.sh"
PROMPT_FILE="zsh-rune-prompt.txt"
PLUGIN_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/${PLUGIN_NAME}"

# Resolve script directory so this works from any cwd
SCRIPT_DIR="${0:A:h}"

for f in "$PLUGIN_FILE" "$CONTEXT_FILE" "$PROMPT_FILE"; do
    if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
        print "install.sh: ${f} not found in ${SCRIPT_DIR}" >&2
        exit 1
    fi
done

print "Installing ${PLUGIN_NAME} to ${PLUGIN_DIR} ..."
mkdir -p "${PLUGIN_DIR}"
cp "${SCRIPT_DIR}/${PLUGIN_FILE}" "${PLUGIN_DIR}/${PLUGIN_FILE}"
cp "${SCRIPT_DIR}/${CONTEXT_FILE}" "${PLUGIN_DIR}/${CONTEXT_FILE}"
cp "${SCRIPT_DIR}/${PROMPT_FILE}" "${PLUGIN_DIR}/${PROMPT_FILE}"
print "Done."
print ""
print "Next steps:"
print "  1. Add '${PLUGIN_NAME}' to your plugins in ~/.zshrc:"
print "       plugins=(... ${PLUGIN_NAME})"
print ""
print "  2. Set your API key in ~/.zshrc (if not already set):"
print "       export ZSH_RUNE_API_KEY=\"sk-or-...\""
print ""
print "  3. Reload your shell:"
print "       source ~/.zshrc"
