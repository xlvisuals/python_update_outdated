# python_update_outdated.sh

A Bash script that keeps Python requirements files up to date without picking up brand-new releases.

It installs your requirements, finds outdated packages, upgrades each one to the **newest release that is at least N days old**, and patches the pinned versions back into your requirements files, leaving comments and formatting alone.

## Features

- **Release-age buffer.** A release must be at least `MIN_AGE_DAYS` old (default 5) before it's installed. If the latest release is too new, the script installs the newest older release that qualifies, rather than skipping the package. Prereleases, dev releases and yanked releases are ignored.
- **Multiple requirements files.** Handles `requirements.txt` plus any `requirements_*.txt` (one per project) found in the current directory. No script edits are needed when you add or remove a project.
- **Constraints support.** Packages listed in `constraints.txt` or `constraints_<project>.txt` are never upgraded and are shown as skipped. A constraints file that can't be read or parsed aborts the run rather than being ignored.
- **In-place patching.** Only the lines for upgraded packages change, and every pin is normalised to `==`. Package names take pip's canonical casing (set `NAME_CASE="lower"` for lowercase).
- **Environment guard.** Asks before continuing if you're on the system Python rather than a virtual environment, if a venv folder exists in the current directory but a different Python is active, or if `pip` belongs to a different Python than `python3`. It aborts if there is no terminal to ask on.
- **Dry run.** `--dry-run` shows what would change without modifying anything.

## Requirements

- Bash, `python3`, `pip`
- `jq`, `curl`, `perl`
- `pipdeptree` (used to write the dependency reports at the end of a run)
- Network access to `pypi.org`

The `packaging` library is installed automatically if it's missing.

## Usage

Run it from the folder containing your requirements files, inside your virtual environment:

```bash
source venv/bin/activate
./python_update_outdated.sh            # install, upgrade and patch requirements files
./python_update_outdated.sh --dry-run  # preview only
```

## Files

| File | Required | Purpose |
|---|---|---|
| `requirements.txt` | yes | Shared packages |
| `requirements_<project>.txt` | no | Per-project packages |
| `constraints.txt` | no | Global "do not upgrade" rules, e.g. `cbor2<=6.0` |
| `constraints_<project>.txt` | no | Per-project rules, paired with `requirements_<project>.txt` |

When installing `requirements_<project>.txt`, pip receives `constraints.txt` plus the matching `constraints_<project>.txt`. Because all projects share one environment, a package is skipped if **any** constraints file constrains it.

## Example output

```
PACKAGE                        CURRENT      NEW          RELEASED     STATUS
-------------------------------------------------------------------------
requests                       2.30.0       2.33.1       2026-03-30   UPDATED (latest 2.34.2 too new)
cbor2                          5.6.0        5.6.0        -            SKIPPED (constrained: <=6.0)
somepkg                        1.2.0        1.2.0        2026-11-08   TOO NEW (2 days old)
```

| Status | Meaning |
|---|---|
| `UPDATED` | Installed and patched into the requirements files. "latest X too new" means a newer release exists but is still inside the age buffer. |
| `SKIPPED (constrained)` | Held back by a constraints file. |
| `TOO NEW` | Every newer release is younger than `MIN_AGE_DAYS`. |
| `FAILED` | The PyPI lookup or the install failed. |

## Output files

Written to `postinstall/` after each run:

- `requirements_installed.txt`: `pip freeze`
- `requirements_toplevel.txt`: top-level packages
- `requirements_deptree.txt`: full dependency tree

Packages that `pip check` reports as unresolved are printed at the end.

## Configuration

Edit the variables at the top of the script:

| Variable | Default | Meaning |
|---|---|---|
| `MIN_AGE_DAYS` | `5` | Minimum age of a release before it's installed |
| `NAME_CASE` | `canonical` | `canonical` keeps pip's casing; `lower` writes names in lowercase |

## Notes

- The initial `pip install -r` installs whatever satisfies each line. For `>=`, `~=` or unpinned lines this can be the newest release regardless of age. The later pin-normalising step then rewrites those lines to `==` at the installed version. The age buffer applies to the upgrade step.
- Environment markers in constraints files are ignored, so the constraint applies unconditionally.
