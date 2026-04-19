# bootstrap

A headless bootstrap for Debian-based machines. Authenticates with
[Proton Pass](https://proton.me/pass) via a scoped PAT, reads a GitHub PAT
from the vault, clones a target repository, and hands off to its `setup.sh`.

## How it works

1. Installs `gh` (GitHub CLI) and `pass-cli` (Proton Pass CLI)
2. Authenticates `pass-cli` using a Proton Pass PAT supplied at the prompt
3. Reads a GitHub PAT from the `tokens` vault (`github-bootstrap` / `pat`)
   and authenticates `gh`
4. Clones the target repository and `exec`s its `setup.sh`

The Proton Pass PAT is the only credential you type. Everything else lives
in the vault.

## Prerequisites

- Debian or Ubuntu host
- A [Proton Pass](https://proton.me/pass) account with:
  - A vault named `tokens` containing a login item `github-bootstrap` with a
    `pat` field holding a GitHub PAT with repo clone access
  - A scoped Proton Pass PAT with read access to the `tokens` vault (and any
    other vaults your `setup.sh` needs)
- A target repository with a `setup.sh` at its root

## Usage

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<user>/bootstrap/master/install.sh)
```

Or with flags:

```bash
bash install.sh \
  --repo <user>/<repo> \
  --branch master \
  --proton-pat pst_xxxx::TOKENKEY
```

### Flags

| Flag | Env var | Description |
|---|---|---|
| `--repo` | `BOOTSTRAP_REPO` | Target repo (`org/repo`) |
| `--branch` | `BOOTSTRAP_BRANCH` | Branch to clone (default: `master`) |
| `--proton-pat` | — | Proton Pass PAT. No env var by design — never persisted. |

## Vault structure

```
tokens/
  github-bootstrap/
    pat    ← GitHub PAT with repo read access
```

Your `setup.sh` may read additional vault items — bootstrap does not
constrain what the target repo uses.

## Security notes

- The Proton Pass PAT is `unset` immediately after `pass-cli login` succeeds
- The GitHub PAT is `unset` immediately after `gh auth login` succeeds
- No credentials are written to disk or environment outside their point of use
- Bootstrap never performs an interactive browser login — aborts if PAT auth fails

## License

MIT — see [LICENSE](LICENSE).
