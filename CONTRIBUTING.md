# Contributing to meeting-to-obsidian

Thanks for your interest! Contributions are welcome — bug reports, fixes, documentation and
quality improvements are all appreciated.

## Ground rules

- **No personal data in commits.** Do not commit your `config.sh`, your glossary (it may contain
  company/product terms), recordings, transcripts, or screenshots. Both files live under
  `~/.zcode/config/meeting-to-obsidian/` and are already git-ignored patterns to keep clean.
- **No model weights or binaries.** Compiled Swift helpers and downloaded weights must never be
  committed (see `.gitignore`). Weight URLs and expected SHA256 sizes go in scripts/docs only.
- **Respect recording privacy.** Features must not weaken the consent/notice guidance in
  [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Development setup

```sh
git clone https://github.com/fbica2gh/meeting-to-obsidian.git
cd meeting-to-obsidian
./install.sh          # scaffolds config, builds helpers, installs MLX deps
```

The Python venv lives at `~/.zcode/venvs/whisper` by default; use it to run the scripts.

## Code guidelines

- Shell scripts: `set -euo pipefail`, `${VAR}` braces whenever a variable is followed by a
  CJK character (bash will parse `$VAR（` as an unknown variable).
- Prompt templates: never pass templates containing literal `{...}` JSON examples through
  `.format()` — use `@PLACEHOLDER@` + `.replace()` (see `polish_note.py`).
- Model downloads must verify HTTP 206 + Content-Range per request and compare SHA256 when a
  reference hash is available.
- Keep every external model/weight referenced by URL + license, never vendored.

## Testing

```sh
# shell syntax
for f in scripts/*.sh; do bash -n "$f"; done
# python syntax
python3 -m compileall -q scripts
# end-to-end smoke test with a short recording
bash scripts/process_live.sh <capture_dir> "" "test note"
```

## Submitting

1. Fork / create a branch
2. Keep PRs focused; one fix or feature per PR
3. Describe the hardware you tested on (chip, RAM) and the meeting length used
