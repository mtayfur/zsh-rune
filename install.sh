#!/usr/bin/env zsh
# install.sh — install zsh-rune into oh-my-zsh custom plugins

set -e

PLUGIN_NAME="zsh-rune"
PLUGIN_FILE="zsh-rune.plugin.zsh"
PLUGIN_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/${PLUGIN_NAME}"

# Resolve script directory so this works from any cwd
SCRIPT_DIR="${0:A:h}"

if [[ ! -f "${SCRIPT_DIR}/${PLUGIN_FILE}" ]]; then
    print "install.sh: ${PLUGIN_FILE} not found in ${SCRIPT_DIR}" >&2
    exit 1
fi

print "Installing ${PLUGIN_NAME} to ${PLUGIN_DIR} ..."
mkdir -p "${PLUGIN_DIR}"
cp "${SCRIPT_DIR}/${PLUGIN_FILE}" "${PLUGIN_DIR}/${PLUGIN_FILE}"
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
