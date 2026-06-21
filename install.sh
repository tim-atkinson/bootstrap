#!/usr/bin/env bash
# Minimal bootstrap: installs pass-cli + gh-cli, authenticates pass-cli with
# a Proton Pass PAT, reads a GitHub PAT from the 'tokens' vault, authenticates
# gh with it, clones a target repo, and hands off to its setup.sh.
# Safe to re-run.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/tim-atkinson/bootstrap/master/install.sh)
#   bash install.sh [--repo rybbt/dotfiles] [--branch master]
#
# Flags / environment variables:
#   --repo / BOOTSTRAP_REPO        e.g. org/repo (default: rybbt/dotfiles)
#   --branch / BOOTSTRAP_BRANCH    e.g. master (default: master)
#   --proton-pat <value>           Proton Pass PAT (pst_xxxx::TOKENKEY) —
#                                  scoped read on the 'ssh' and 'tokens'
#                                  vaults. If omitted, prompted interactively.
#                                  There is no env var for the PAT on
#                                  purpose — it must be typed or passed by
#                                  switch, never persisted in the environment.
#
# The GitHub PAT is read from the 'tokens' vault (item: github-bootstrap,
# field: pat) — not supplied here at all.

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────

REPO="${BOOTSTRAP_REPO:-rybbt/dotfiles}"
PROTON_PAT=""
BRANCH_SET=false
BRANCH="master"

# Env var counts as explicit — suppress interactive prompt for branch.
if [[ -n "${BOOTSTRAP_BRANCH:-}" ]]; then
  BRANCH="$BOOTSTRAP_BRANCH"
  BRANCH_SET=true
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)       REPO="$2";                      shift 2 ;;
    --branch)     BRANCH="$2"; BRANCH_SET=true;   shift 2 ;;
    --proton-pat) PROTON_PAT="$2";                shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Prompts ───────────────────────────────────────────────────────────────────

if [[ "$BRANCH_SET" == false ]]; then
  read -rp "Branch [$BRANCH]: " _branch
  BRANCH="${_branch:-$BRANCH}"
fi

if [[ -z "$PROTON_PAT" ]]; then
  read -rsp "Proton Pass PAT (pst_...::TOKENKEY): " PROTON_PAT
  echo
fi

# ── Minimal apt prereqs ───────────────────────────────────────────────────────

sudo apt-get update -qq
sudo apt-get install -y git curl ca-certificates gpg jq

# ── GitHub CLI ────────────────────────────────────────────────────────────────

if ! command -v gh &>/dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
  sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y gh
fi

# ── Proton Pass CLI ───────────────────────────────────────────────────────────
# Disable and stop the SSH agent service. Disabling prevents Restart=on-failure
# from recreating the pass-cli database between our state wipe and our login.
systemctl --user disable proton-pass-ssh-agent.service 2>/dev/null || true
systemctl --user stop proton-pass-ssh-agent.service 2>/dev/null || true
pkill -f "pass-cli" 2>/dev/null || true

if [[ ! -x "$HOME/.local/bin/pass-cli" ]]; then
  curl -fsSL https://proton.me/download/pass-cli/install.sh | bash
fi

# Installer puts pass-cli in ~/.local/bin which may not be in PATH yet.
export PATH="$HOME/.local/bin:$PATH"

# ── Authenticate pass-cli with the Proton Pass PAT ────────────────────────────
# Wipe the default session directory so every run starts clean.
# Do NOT set PROTON_PASS_SESSION_DIR — overriding it changes where pass-cli
# looks for session files and can cause "Passphrases file not found" even
# after a successful login.
#
# Use the env key provider so the session is encrypted with a key derived from
# the PAT rather than the system keyring. The keyring (default provider) can
# cause "Error decrypting local session" on machines where D-Bus is available
# during login but not accessible to the immediately following vault-read
# command (common in SSH sessions on machines with gnome-keyring installed).
# The env provider is safe here: this session is ephemeral — setup.sh replaces
# it immediately with an interactive fs-provider login.
export PROTON_PASS_KEY_PROVIDER=env
export PROTON_PASS_ENCRYPTION_KEY="$PROTON_PAT"
pass-cli logout --force 2>/dev/null || true
rm -rf "$HOME/.local/share/proton-pass-cli"
pass-cli login --pat "$PROTON_PAT"

unset PROTON_PAT
unset PROTON_PASS_ENCRYPTION_KEY
unset PROTON_PASS_KEY_PROVIDER

# ── Read GitHub PAT from the 'tokens' vault, authenticate gh ──────────────────

GH_PAT=$(pass-cli item view \
  --vault-name tokens \
  --item-title github-bootstrap \
  --field pat) || {
  echo "ERROR: could not read GitHub PAT from vault (tokens/github-bootstrap/pat)" >&2
  exit 1
}

if [[ -z "$GH_PAT" ]]; then
  echo "ERROR: GitHub PAT is empty — check the tokens vault item" >&2
  exit 1
fi

if ! echo "$GH_PAT" | gh auth login --with-token; then
  echo "ERROR: gh auth failed — the GitHub PAT may be expired; regenerate it on github.com and update the tokens vault" >&2
  exit 1
fi
unset GH_PAT
gh auth setup-git

# ── Clone target repo ─────────────────────────────────────────────────────────

CLONE_DIR="$HOME/.bootstrap/$(echo "$REPO" | tr '/' '-')"
mkdir -p "$(dirname "$CLONE_DIR")"
rm -rf "$CLONE_DIR"
gh repo clone "$REPO" "$CLONE_DIR" -- --branch "$BRANCH" --depth 1

# ── Hand off to setup.sh ──────────────────────────────────────────────────────

export BOOTSTRAP_REPO="$REPO"
export BOOTSTRAP_BRANCH="$BRANCH"
exec bash "$CLONE_DIR/setup.sh"
