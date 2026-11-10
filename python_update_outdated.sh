#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# python_update_outdated.sh
#
# Updates pip and installs packages from requirements files.
# Then updates outdated pip packages and patches the requirements files
# in-place.
#
# Requirement files handled:
#   - requirements.txt          (required) - the shared/base requirements
#   - requirements_*.txt        (optional) - one per project, e.g.
#                                requirements_projecta.txt,
#                                requirements_projectb.txt
#     Any file matching requirements_*.txt in the current directory is
#     picked up automatically - no need to edit this script when a project
#     file is added or removed. Excluded from autodiscovery: this
#     script's own generated output files (requirements_installed.txt,
#     requirements_deptree.txt, requirements_toplevel.txt).
#
# Packages are not updated if:
#   - They appear in constraints.txt or in any per-project constraints file
#     (constraints_<project>.txt) with a version pin (e.g. "cbor2<=6.0"),
#     in which case they are highlighted in yellow showing the constraint
#     (and, for per-project constraints, the file it came from).
#
# Constraint files handled:
#   - constraints.txt           (optional) - global; applies to every project
#   - constraints_*.txt         (optional) - one per project, paired with the
#                                requirements file of the same name:
#                                requirements_projecta.txt <-> constraints_projecta.txt
#     Any file matching constraints_*.txt is picked up automatically.
#     When installing requirements_<project>.txt, pip gets constraints.txt
#     plus constraints_<project>.txt (requirements.txt gets constraints.txt
#     only). All projects share one environment, so when deciding what to
#     upgrade a package is skipped if ANY constraint file constrains it.
#     A constraints file that is unreadable, or contains a line that cannot
#     be parsed as "<package><operator><version>", aborts the run (before
#     anything is installed) rather than being silently ignored. A
#     constraints_<project>.txt without a matching requirements file is
#     still applied to upgrade decisions, with a warning.
#   - The new version was released less than MIN_AGE_DAYS days ago (default: 5),
#     to avoid freshly released packages that may be unstable or get yanked.
#
# For packages that are updated, only the affected lines are modified in
# whichever requirements file(s) actually pin that package — comments,
# formatting and all other lines are preserved. The pin's existing operator
# (==, >=, <=, ~=, !=, >, <) is preserved; only the version number changes.
# A package is only ever installed/upgraded once, even if it's referenced
# by more than one requirements file.
#
# Environment guard:
#   Before doing anything, the script asks "Continue anyway? [y/N]" if
#   python3 is the system Python (not a venv), if a venv folder exists in the
#   current directory but a different Python is active, or if "pip" belongs to
#   a different Python than python3. It aborts if there is no terminal to ask on.
#
# Usage:
#   ./python_update_outdated.sh [--dry-run]
#
# Options:
#   --dry-run    Show what would be updated without making any changes
#
# Requirements:
#   pip, jq, curl, perl
#
# Files:
#   requirements.txt    (required) - shared packages to update
#   requirements_*.txt  (optional) - per-project packages to update
#   constraints.txt     (optional) - global packages to skip, e.g. "cbor2<=6.0"
#   constraints_*.txt   (optional) - per-project packages to skip
# -----------------------------------------------------------------------------

shopt -s nullglob

MAIN_REQUIREMENTS_FILE="requirements.txt"
CONSTRAINTS_FILE="constraints.txt"
DRY_RUN=false
MIN_AGE_DAYS=5
# The pin's existing operator is normalized to == (see below), but the
# package NAME's casing is left as whatever pip itself reports for the
# installed package: this is the maintainer's own display name as
# published on PyPI (e.g. "PyYAML", "SQLAlchemy"), which pip preserves
# from the package's metadata. Casing is purely cosmetic — pip/PyPI
# resolve package names case-insensitively (PEP 503) — so this has no
# effect on what actually gets installed.
#   "canonical" - use the casing pip reports (the default, above)
#   "lower"     - always write the name in lowercase instead
NAME_CASE="canonical"

# Parse --dry-run flag
for arg in "$@"; do
  [ "$arg" = "--dry-run" ] && DRY_RUN=true
done

if [ ! -f "$MAIN_REQUIREMENTS_FILE" ]; then
  echo "Error: $MAIN_REQUIREMENTS_FILE not found"
  exit 1
fi

# Build the list of requirement files: requirements.txt plus every
# requirements_*.txt project file found in the current directory,
# excluding this script's own generated output files (in case they
# ever end up alongside the source requirements files rather than in
# postinstall/).
EXCLUDED_FILES=("requirements_installed.txt" "requirements_deptree.txt" "requirements_toplevel.txt")
is_excluded() {
  local candidate="$1"
  for ex in "${EXCLUDED_FILES[@]}"; do
    [ "$candidate" = "$ex" ] && return 0
  done
  return 1
}

REQUIREMENTS_FILES=("$MAIN_REQUIREMENTS_FILE")
for f in requirements_*.txt; do
  is_excluded "$f" && continue
  REQUIREMENTS_FILES+=("$f")
done

# Build the list of constraint files: the global constraints.txt (if
# present) plus every per-project constraints_*.txt found.
PROJECT_CONSTRAINTS_FILES=()
for f in constraints_*.txt; do
  PROJECT_CONSTRAINTS_FILES+=("$f")
  req_counterpart="requirements_${f#constraints_}"
  if [ ! -f "$req_counterpart" ]; then
    echo "Warning: $f has no matching $req_counterpart (still applied to upgrade decisions)" >&2
  fi
done
CONSTRAINTS_FILES=()
[ -f "$CONSTRAINTS_FILE" ] && CONSTRAINTS_FILES+=("$CONSTRAINTS_FILE")
CONSTRAINTS_FILES+=("${PROJECT_CONSTRAINTS_FILES[@]}")

YELLOW='\033[0;33m'
GREEN='\033[0;32m'
GRAY='\033[0;90m'
RESET='\033[0m'

# Applies NAME_CASE to a package name before it's written into a
# requirements file.
display_name() {
  if [ "$NAME_CASE" = "lower" ]; then
    echo "$1" | tr '[:upper:]' '[:lower:]'
  else
    echo "$1"
  fi
}

# PEP 503 name normalization: lowercase, and treat runs of -, _, . as
# equivalent (collapsed to a single -). Two names are the "same" package
# to pip/PyPI iff they normalize to the same string — e.g. "pydantic_core",
# "pydantic-core" and "Pydantic.Core" are all the same package. Every
# place this script compares package names (constraints, outdated-list
# lookups, installed-package lookups) must normalize both sides this way
# or matches get silently missed.
normalize_pkg() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[-_.]+/-/g'
}

# Parses one constraints file into the CONSTRAINTS associative array
# (key: normalized package name, value: the specifier(s) plus, for
# per-project files, the file they came from). A package constrained in
# several files keeps all of them. Fails closed: an unreadable file or an
# unparseable line aborts the run, so a typo can never silently turn into
# "no constraint".
declare -A CONSTRAINTS
parse_constraints_file() {
  local file="$1" label="" lineno=0 line clean pkg spec
  [ "$file" != "$CONSTRAINTS_FILE" ] && label=" ($file)"
  if [ ! -r "$file" ]; then
    echo "Error: cannot read constraints file $file" >&2
    exit 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # Drop comments and environment markers (ignoring a marker makes the
    # constraint apply unconditionally, i.e. the stricter reading), then
    # all whitespace.
    clean=$(printf '%s\n' "$line" | sed -e 's/#.*//' -e 's/;.*//' | tr -d '[:space:]')
    [ -z "$clean" ] && continue
    if [[ ! "$clean" =~ ^([A-Za-z0-9][A-Za-z0-9_.-]*)((===|==|>=|<=|~=|!=|>|<).+)$ ]]; then
      echo "Error: $file:$lineno: cannot parse constraint '$line'" >&2
      exit 1
    fi
    pkg=$(normalize_pkg "${BASH_REMATCH[1]}")
    spec="${BASH_REMATCH[2]}${label}"
    if [ -n "${CONSTRAINTS[$pkg]:-}" ]; then
      CONSTRAINTS[$pkg]="${CONSTRAINTS[$pkg]}; ${spec}"
    else
      CONSTRAINTS[$pkg]="$spec"
    fi
  done < "$file"
}

# Parse every constraints file up front, before anything is installed.
for f in "${CONSTRAINTS_FILES[@]}"; do
  parse_constraints_file "$f"
done

# Sets CONSTRAINTS_ARGS to the "-c" arguments for installing the given
# requirements file: the global constraints.txt, plus the matching
# constraints_<project>.txt for requirements_<project>.txt.
set_constraints_args() {
  local req="$1" suffix project_constraints
  CONSTRAINTS_ARGS=()
  [ -f "$CONSTRAINTS_FILE" ] && CONSTRAINTS_ARGS+=(-c "$CONSTRAINTS_FILE")
  if [ "$req" != "$MAIN_REQUIREMENTS_FILE" ]; then
    suffix="${req#requirements_}"
    project_constraints="constraints_${suffix}"
    [ -f "$project_constraints" ] && CONSTRAINTS_ARGS+=(-c "$project_constraints")
  fi
}

# -----------------------------------------------------------------------------
# Environment guard. Runs before anything is installed or modified (also in
# --dry-run, so you see the same warnings). Warns, then asks to continue, if:
#   1. python3 is NOT running inside a virtual environment (i.e. it is the
#      system/base interpreter), or
#   2. a virtual environment folder (any subfolder of the current directory
#      containing pyvenv.cfg, e.g. venv/ or .venv/) exists here but the
#      active python3 is not one of them, or
#   3. "pip" does not belong to the same interpreter as "python3", since the
#      script installs with pip but inspects with python3.
# Fails closed: if the environment cannot be determined, or there is no
# terminal to ask on, the script aborts. The default answer is "no".
# -----------------------------------------------------------------------------
confirm_continue() {
  local w reply
  echo "" >&2
  for w in "$@"; do
    printf '%b%s%b\n' "$YELLOW" "Warning: $w" "$RESET" >&2
  done
  if [ ! -t 0 ]; then
    echo "Error: no terminal available to ask whether to continue - aborting." >&2
    exit 1
  fi
  read -r -p "Continue anyway? [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS]) echo "" ;;
    *) echo "Aborted."; exit 1 ;;
  esac
}

ENV_INFO=$(python3 -c 'import sys, os; print(int(sys.prefix != sys.base_prefix)); print(os.path.realpath(sys.prefix))') || {
  echo "Error: could not inspect python3 - aborting." >&2
  exit 1
}
IN_VENV=$(printf '%s\n' "$ENV_INFO" | sed -n 1p)
PY_PREFIX=$(printf '%s\n' "$ENV_INFO" | sed -n 2p)
if { [ "$IN_VENV" != "0" ] && [ "$IN_VENV" != "1" ]; } || [ -z "$PY_PREFIX" ]; then
  echo "Error: could not determine whether python3 is in a virtual environment - aborting." >&2
  exit 1
fi

ENV_WARNINGS=()

if [ "$IN_VENV" = "0" ]; then
  ENV_WARNINGS+=("python3 ($PY_PREFIX) is the system/base Python, not a virtual environment.")
fi

# Virtual environments in the current directory (one level deep).
LOCAL_VENVS=()
for d in */ .[!.]*/; do
  if [ -f "${d}pyvenv.cfg" ]; then
    LOCAL_VENVS+=("$(cd "$d" && pwd -P)")
  fi
done
if [ "${#LOCAL_VENVS[@]}" -gt 0 ]; then
  venv_match=false
  for v in "${LOCAL_VENVS[@]}"; do
    [ "$v" = "$PY_PREFIX" ] && venv_match=true
  done
  if [ "$venv_match" = false ]; then
    ENV_WARNINGS+=("a virtual environment exists in this folder (${LOCAL_VENVS[*]}) but python3 is using $PY_PREFIX instead.")
  fi
fi

PIP_VER=$(pip --version 2>/dev/null) || {
  echo "Error: pip not found - aborting." >&2
  exit 1
}
PY_PIP_VER=$(python3 -m pip --version 2>/dev/null)
if [ "$PIP_VER" != "$PY_PIP_VER" ]; then
  ENV_WARNINGS+=("'pip' does not belong to the active python3 (pip: $PIP_VER; python3 -m pip: ${PY_PIP_VER:-unavailable}).")
fi

echo ""
echo "-----------------------------------------------------------------"
echo "PIP UPDATE SCRIPT"
echo "Date:          $(date +%F)"
echo "Min Age:       $MIN_AGE_DAYS"
echo "Active Python: $(python3 -c 'import sys; print(sys.executable)')"
if [ "${#LOCAL_VENVS[@]}" -gt 0 ]; then
  echo "Found venv:    ${LOCAL_VENVS[*]}"
else
  echo "Found venv:    (none in $(pwd))"
fi
echo "Requirements:  ${REQUIREMENTS_FILES[*]}"
[ "${#CONSTRAINTS_FILES[@]}" -gt 0 ] && echo "Constraints:   ${CONSTRAINTS_FILES[*]}"
[ "$DRY_RUN" = true ] && echo "Mode:          DRY RUN"
echo "-----------------------------------------------------------------"
if [ "${#ENV_WARNINGS[@]}" -gt 0 ]; then
  confirm_continue "${ENV_WARNINGS[@]}"
fi

# update pip
if [ "$DRY_RUN" = false ]; then
  pip install --upgrade pip --quiet
fi

# install packages from every requirements file
if [ "$DRY_RUN" = false ]; then

  for f in "${REQUIREMENTS_FILES[@]}"; do
    echo "Installing from $f..."
    set_constraints_args "$f"
    pip install -r "$f" "${CONSTRAINTS_ARGS[@]}"
  done

  # Normalize every requirements-file line so its package NAME matches
  # pip's canonical casing/spelling, and so every pin uses ==:
  #   - lines already pinned with == : casing is fixed if needed, the
  #     pinned version is left exactly as-is (never overwritten here)
  #   - lines pinned with >=, <=, ~=, !=, >, < : rewritten to == using
  #     whatever version actually got installed. This catches packages
  #     pip never reports as "outdated" (e.g. a >= pin that already
  #     resolved to the latest version on this install) which the
  #     outdated-package loop below would otherwise never touch.
  # Name matching uses PEP 503 normalization (case-insensitive, -/_/.
  # treated as equivalent) so e.g. a file's "pydantic_core" matches
  # pip's "pydantic-core".
  echo ""
  echo "Normalizing package pins..."
  INSTALLED_JSON=$(pip list --format=json)
  for f in "${REQUIREMENTS_FILES[@]}"; do
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        \#*|'') continue ;;
      esac
      pkg=$(echo "$line" | sed -E 's/^([A-Za-z0-9_.-]+).*/\1/')
      op=$(echo "$line" | sed -nE 's/^[A-Za-z0-9_.-]+(==|>=|<=|~=|!=|>|<).*/\1/p')
      [ -z "$op" ] && continue
      cur_ver=$(echo "$line" | sed -E "s/^[A-Za-z0-9_.-]+(==|>=|<=|~=|!=|>|<)([^[:space:]#]*).*/\\2/")
      pkg_norm=$(normalize_pkg "$pkg")
      result=$(echo "$INSTALLED_JSON" | jq -r --arg p "$pkg_norm" '.[] | select((.name | ascii_downcase | gsub("[-_.]+"; "-")) == $p) | "\(.name)\t\(.version)"')
      [ -z "$result" ] && continue
      canonical_name=$(echo "$result" | cut -f1)
      installed_ver=$(echo "$result" | cut -f2)
      new_name=$(display_name "$canonical_name")
      if [ "$op" = "==" ]; then
        # Fix casing only; never touch an already-exact pinned version.
        [ "$new_name" = "$pkg" ] && continue
        perl -i -pe "s/^(\\Q${pkg}\\E)(==)([^\\s#]*)(.*)\$/${new_name}==${cur_ver}\${4}/i" "$f"
      else
        perl -i -pe "s/^(\\Q${pkg}\\E)(==|>=|<=|~=|!=|>|<)([^\\s#]*)(.*)\$/${new_name}==${installed_ver}\${4}/i" "$f"
      fi
    done < "$f"
  done
fi

# Ensure "packaging" is importable for PEP 440-aware version comparison
# (needed by find_installable_version below). Almost every Python
# environment already has it as a transitive dependency of pip/setuptools,
# so this is normally a no-op.
if [ "$DRY_RUN" = false ]; then
  python3 -c "import packaging.version" 2>/dev/null || pip install --quiet packaging
fi
HAVE_PACKAGING=true
python3 -c "import packaging.version" 2>/dev/null || HAVE_PACKAGING=false

# Given a package name, its currently installed version, and MIN_AGE_DAYS,
# looks at every release on PyPI (not just the single latest one) and
# picks the newest release that is both newer than the installed version
# AND old enough (upload date <= now - MIN_AGE_DAYS). Prereleases,
# devreleases and yanked releases are ignored. This means a package whose
# absolute latest release is too fresh still gets upgraded to the newest
# safe intermediate release, instead of being skipped entirely.
#
# Prints four tab-separated fields:
#   latest_version  latest_release_date  best_version  best_release_date
# best_version/best_release_date are empty if no release is both newer
# and old enough (i.e. every newer release is too new). latest_version
# and latest_release_date are empty if the PyPI lookup itself failed.
find_installable_version() {
  local name="$1" curr="$2" min_age_days="$3"
  python3 - "$name" "$curr" "$min_age_days" <<'PYEOF'
import sys, json, urllib.request, datetime
from packaging.version import Version, InvalidVersion

name, curr, min_age_days = sys.argv[1], sys.argv[2], int(sys.argv[3])

try:
    req = urllib.request.Request(
        f"https://pypi.org/pypi/{name}/json",
        headers={"User-Agent": "python_update_outdated.sh"},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.load(resp)
except Exception:
    print("\t\t\t")
    sys.exit(0)

try:
    curr_v = Version(curr)
except InvalidVersion:
    print("\t\t\t")
    sys.exit(0)

now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(days=min_age_days)

releases = []
for ver_str, files in data.get("releases", {}).items():
    if not files:
        continue
    if any(f.get("yanked") for f in files):
        continue
    try:
        v = Version(ver_str)
    except InvalidVersion:
        continue
    if v.is_prerelease or v.is_devrelease:
        continue
    upload_times = [f["upload_time_iso_8601"] for f in files if f.get("upload_time_iso_8601")]
    if not upload_times:
        continue
    earliest = min(upload_times)
    try:
        rel_date = datetime.datetime.fromisoformat(earliest.replace("Z", "+00:00"))
    except ValueError:
        continue
    releases.append((v, ver_str, rel_date))

if not releases:
    print("\t\t\t")
    sys.exit(0)

releases.sort(key=lambda r: r[0])
latest_v, latest_ver_str, latest_date = releases[-1]

candidates = [r for r in releases if r[0] > curr_v and r[2] <= cutoff]
if candidates:
    best_v, best_ver_str, best_date = max(candidates, key=lambda r: r[0])
    best_out = f"{best_ver_str}\t{best_date.date().isoformat()}"
else:
    best_out = "\t"

print(f"{latest_ver_str}\t{latest_date.date().isoformat()}\t{best_out}")
PYEOF
}

# Get outdated packages as JSON
echo ""
echo "Checking for outdated packages..."
OUTDATED=$(pip list --outdated --format=json)
COUNT=$(echo "$OUTDATED" | jq 'length')

if [ "$COUNT" -eq 0 ]; then
  echo "All packages are up to date."
  exit 0
fi

echo "Found $COUNT outdated package(s)."
echo ""
printf "%-30s %-12s %-12s %-12s %-8s\n" "PACKAGE" "CURRENT" "NEW" "RELEASED" "STATUS"
echo "-------------------------------------------------------------------------"

UPDATED=0
SKIPPED=0
TOO_NEW=0

# Today's date as epoch seconds
TODAY_EPOCH=$(date +%s)

# Process each outdated package (once, regardless of how many requirements
# files reference it)
while IFS= read -r row; do
  name=$(echo "$row" | jq -r '.name')
  curr=$(echo "$row" | jq -r '.version')
  latest=$(echo "$row" | jq -r '.latest_version')
  pkg_lower=$(normalize_pkg "$name")

  # Check constraints
  constraint=${CONSTRAINTS[$pkg_lower]:-}
  if [ -n "$constraint" ]; then
    printf "${YELLOW}%-30s${RESET} %-12s %-12s %-12s ${YELLOW}SKIPPED (constrained: %s)${RESET}\n" "$name" "$curr" "$latest" "-" "$constraint"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Find the newest release that's both newer than what's installed and
  # old enough to install (see find_installable_version above). Falls
  # back to the old "only ever consider the single latest release"
  # behavior if the packaging library couldn't be made available (e.g.
  # a --dry-run with no network permission to install it).
  target=""
  target_date=""
  pypi_latest=""
  latest_date=""
  if [ "$HAVE_PACKAGING" = true ]; then
    IFS=$'\t' read -r pypi_latest latest_date target target_date < <(find_installable_version "$name" "$curr" "$MIN_AGE_DAYS")
  else
    pypi_latest="$latest"
    latest_date=$(curl -s "https://pypi.org/pypi/$name/$latest/json" | jq -r '.urls[0].upload_time_iso_8601[:10] // ""')
    if [ -n "$latest_date" ]; then
      # Cross-platform day-age check (macOS vs Linux date)
      if date -j > /dev/null 2>&1; then
        rel_epoch=$(date -j -f "%Y-%m-%d" "$latest_date" "+%s")
      else
        rel_epoch=$(date -d "$latest_date" "+%s")
      fi
      age_days=$(( (TODAY_EPOCH - rel_epoch) / 86400 ))
      if [ "$age_days" -ge "$MIN_AGE_DAYS" ]; then
        target="$latest"
        target_date="$latest_date"
      else
        target=""
        target_date=""
      fi
    fi
  fi

  if [ -z "$latest_date" ]; then
    printf "%-30s %-12s %-12s %-12s FAILED (no release date)\n" "$name" "$curr" "$latest" "unknown"
    continue
  fi

  if [ -z "$target" ]; then
    # Every release newer than what's installed is still too new.
    if date -j > /dev/null 2>&1; then
      rel_epoch=$(date -j -f "%Y-%m-%d" "$latest_date" "+%s")
    else
      rel_epoch=$(date -d "$latest_date" "+%s")
    fi
    age_days=$(( (TODAY_EPOCH - rel_epoch) / 86400 ))
    printf "${GRAY}%-30s${RESET} %-12s %-12s %-12s ${GRAY}TOO NEW (%d days old)${RESET}\n" "$name" "$curr" "$pypi_latest" "$latest_date" "$age_days"
    TOO_NEW=$((TOO_NEW + 1))
    continue
  fi

  # Install the chosen version
  if [ "$DRY_RUN" = false ]; then
    pip install --quiet "$name==$target"
    STATUS=$?
  else
    STATUS=0
  fi

  if [ $STATUS -eq 0 ]; then
    if [ "$DRY_RUN" = false ]; then
      # Patch every requirements file that pins this package. Whatever
      # operator was used before (==, >=, <=, ~=, !=, >, <), the pin is
      # normalized to == so every package stays pinned to an exact
      # version. Files that don't reference the package are left
      # untouched.
      new_name=$(display_name "$name")
      for f in "${REQUIREMENTS_FILES[@]}"; do
        perl -i -pe "s/^(\\Q${name}\\E)(==|>=|<=|~=|!=|>|<)([^\\s#]*)(.*)\$/${new_name}==${target}\${4}/i" "$f"
      done
    fi
    if [ "$target" = "$pypi_latest" ]; then
      printf "${GREEN}%-30s${RESET} %-12s ${GREEN}%-12s${RESET} %-12s ${GREEN}UPDATED${RESET}\n" "$name" "$curr" "$target" "$target_date"
    else
      printf "${GREEN}%-30s${RESET} %-12s ${GREEN}%-12s${RESET} %-12s ${GREEN}UPDATED (latest %s too new)${RESET}\n" "$name" "$curr" "$target" "$target_date" "$pypi_latest"
    fi
    UPDATED=$((UPDATED + 1))
  else
    printf "%-30s %-12s %-12s %-12s FAILED\n" "$name" "$curr" "$target" "$target_date"
  fi

done < <(echo "$OUTDATED" | jq -c '.[]')

echo "-------------------------------------------------------------------------"
echo "Updated: $UPDATED  Skipped (constrained): $SKIPPED  Too new: $TOO_NEW"
echo ""

echo ""
echo "Unresolved constraints:"
pip check

echo "Writing requirements_installed.txt"
mkdir -p postinstall
pip freeze > postinstall/requirements_installed.txt
echo "Writing requirements_toplevel.txt"
pipdeptree -f --warn silence | grep -E '^[a-zA-Z0-9\-]+' > postinstall/requirements_toplevel.txt
echo "Writing requirements_deptree.txt"
pipdeptree -fl --warn silence > postinstall/requirements_deptree.txt