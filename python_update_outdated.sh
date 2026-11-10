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
# Constrained packages (listed in constraints.txt or any constraints_<project>.txt
# with a version specifier, e.g. "cbor2<=6.0") are still upgraded, but only to
# the newest release that satisfies EVERY constraint on them (and is old
# enough). They are shown as "UPDATED (within <=6.0; latest X)". If no newer
# allowed release exists they are highlighted in yellow as SKIPPED, showing the
# constraint (and, for per-project constraints, the file it came from). They
# are also skipped if the constraint cannot be evaluated (see below).
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
#     upgrade a package must satisfy ALL constraint files that mention it.
#     A specifier that packaging cannot parse (e.g. "requests<abc") makes
#     that package FAILED, never unconstrained; if the packaging library is
#     unavailable, constrained packages are skipped rather than upgraded.
#     A constraints file that is unreadable, or contains a line that cannot
#     be parsed as "<package><operator><version>", aborts the run (before
#     anything is installed) rather than being silently ignored. A
#     constraints_<project>.txt without a matching requirements file is
#     still applied to upgrade decisions, with a warning.
# Packages are also not updated to a version released less than MIN_AGE_DAYS
# days ago (default: 5),
#     to avoid freshly released packages that may be unstable or get yanked.
#
# Per-project versions: all projects share one environment, but every
# requirements file is updated on its own. Each pinned line moves to the newest
# release (old enough, see MIN_AGE_DAYS) that satisfies the constraints that
# apply to THAT file (constraints.txt + its own constraints_<project>.txt), so
# e.g. ternary can stay on wrapt 1.x while the other projects move to 2.x. If
# the files end up on different versions of a package, nothing is installed
# for it in the shared environment ("ENV UNCHANGED (files differ: ...)").
# A >=, ~=, <=, ... line is only rewritten to the installed version if that
# version satisfies the line and the file's constraints; otherwise it is left
# alone (with a note) and handled by the per-file update, which stays inside
# the line's own range.
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
#
# CONSTRAINT_SPECS holds the same constraints as bare, comma-joined
# specifiers (e.g. "<=6.0,!=5.9") with no file labels, in the form
# packaging's SpecifierSet understands. A package constrained in several
# files must satisfy all of them.
declare -A CONSTRAINTS
#
# FILE_SPECS keeps the same bare specifiers per constraints FILE
# (key: "<constraints file>|<normalized package name>"), so the constraints
# that apply to one particular requirements file can be worked out later
# (see applicable_spec).
declare -A CONSTRAINT_SPECS
declare -A FILE_SPECS
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
    if [ -n "${CONSTRAINT_SPECS[$pkg]:-}" ]; then
      CONSTRAINT_SPECS[$pkg]="${CONSTRAINT_SPECS[$pkg]},${BASH_REMATCH[2]}"
    else
      CONSTRAINT_SPECS[$pkg]="${BASH_REMATCH[2]}"
    fi
    if [ -n "${FILE_SPECS["$file|$pkg"]:-}" ]; then
      FILE_SPECS["$file|$pkg"]="${FILE_SPECS["$file|$pkg"]},${BASH_REMATCH[2]}"
    else
      FILE_SPECS["$file|$pkg"]="${BASH_REMATCH[2]}"
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

# Prints the comma-joined specifier that applies to package $2 (normalized
# name) when it appears in requirements file $1: the global constraints.txt
# plus the matching constraints_<project>.txt (requirements.txt gets
# constraints.txt only). Prints nothing if the package is unconstrained
# for that file.
applicable_spec() {
  local req="$1" pkg="$2" g="" p=""
  [ -f "$CONSTRAINTS_FILE" ] && g="${FILE_SPECS["$CONSTRAINTS_FILE|$pkg"]:-}"
  if [ "$req" != "$MAIN_REQUIREMENTS_FILE" ]; then
    p="${FILE_SPECS["constraints_${req#requirements_}|$pkg"]:-}"
  fi
  printf '%s' "$g${g:+${p:+,}}$p"
}

# version_satisfies VERSION SPEC: exit 0 if VERSION satisfies the
# comma-joined specifier SPEC (an empty SPEC accepts anything). Fails
# closed: an unparseable version or specifier, or a missing "packaging"
# library, is exit 1.
version_satisfies() {
  python3 -c '
import sys
from packaging.version import Version
from packaging.specifiers import SpecifierSet
try:
    ok = SpecifierSet(sys.argv[2]).contains(Version(sys.argv[1]), prereleases=True)
except Exception:
    sys.exit(1)
sys.exit(0 if ok else 1)
' "$1" "$2" 2>/dev/null
}

# Progress output for the slow per-package steps. On a terminal a single
# line is overwritten in place ("[12/87] requirements_yoe.txt: wrapt"); when
# output is not a terminal (redirected to a file, cron) it is silent and
# only a line per requirements file is printed instead, so logs stay clean.
progress() {
  [ -t 1 ] && printf '\r\033[K%s' "${1:0:78}"
  return 0
}
progress_done() {
  [ -t 1 ] && printf '\r\033[K'
  return 0
}
# Number of pinned lines (name + operator + version) across all requirements
# files, used as the denominator for progress.
count_pins() {
  cat "${REQUIREMENTS_FILES[@]}" | grep -cE '^[A-Za-z0-9_.-]+(==|>=|<=|~=|!=|>|<)' || true
}

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

  # "packaging" is needed below to check pins against constraints.
  python3 -c "import packaging.version" 2>/dev/null || pip install --quiet packaging

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
  norm_total=$(count_pins)
  norm_i=0
  for f in "${REQUIREMENTS_FILES[@]}"; do
    [ -t 1 ] || echo "  $f"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        \#*|'') continue ;;
      esac
      pkg=$(echo "$line" | sed -E 's/^([A-Za-z0-9_.-]+).*/\1/')
      op=$(echo "$line" | sed -nE 's/^[A-Za-z0-9_.-]+(==|>=|<=|~=|!=|>|<).*/\1/p')
      [ -z "$op" ] && continue
      norm_i=$((norm_i + 1))
      progress "[$norm_i/$norm_total] $f: $pkg"
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
        # Only rewrite to the installed version if that version actually
        # satisfies the line itself and the constraints that apply to this
        # file. The environment is shared, so the installed version may
        # belong to another project (e.g. wrapt 2.x installed for one
        # project while ternary needs 1.x); in that case the line is left
        # alone rather than silently broken. Fails closed.
        applicable=$(applicable_spec "$f" "$pkg_norm")
        check_spec="${op}${cur_ver}${applicable:+,$applicable}"
        if ! version_satisfies "$installed_ver" "$check_spec"; then
          echo "Note: $f: left '$pkg$op$cur_ver' as-is (installed $installed_ver does not satisfy $check_spec)"
          continue
        fi
        perl -i -pe "s/^(\\Q${pkg}\\E)(==|>=|<=|~=|!=|>|<)([^\\s#]*)(.*)\$/${new_name}==${installed_ver}\${4}/i" "$f"
      fi
    done < "$f"
  done
  progress_done
  echo "Checked $norm_i pinned line(s)."
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
#
# An optional 4th argument is a comma-joined constraint specifier
# (e.g. "<=6.0,!=5.9"). When given, the chosen release must also satisfy
# it, so a constrained package is upgraded to the newest allowed release
# instead of being skipped. An invalid specifier is treated as a failed
# lookup (all fields empty, reason on stderr), never as "no constraint".
find_installable_version() {
  local name="$1" curr="$2" min_age_days="$3" spec="${4:-}"
  python3 - "$name" "$curr" "$min_age_days" "$spec" <<'PYEOF'
import sys, json, urllib.request, datetime
from packaging.version import Version, InvalidVersion
from packaging.specifiers import SpecifierSet, InvalidSpecifier

name, curr, min_age_days = sys.argv[1], sys.argv[2], int(sys.argv[3])
spec_str = sys.argv[4]

try:
    spec = SpecifierSet(spec_str)
except InvalidSpecifier:
    print(f"invalid constraint '{spec_str}' for {name}", file=sys.stderr)
    print("\t\t\t")
    sys.exit(0)

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

candidates = [r for r in releases
              if r[0] > curr_v and r[2] <= cutoff and spec.contains(r[0])]
if candidates:
    best_v, best_ver_str, best_date = max(candidates, key=lambda r: r[0])
    best_out = f"{best_ver_str}\t{best_date.date().isoformat()}"
else:
    best_out = "\t"

print(f"{latest_ver_str}\t{latest_date.date().isoformat()}\t{best_out}")
PYEOF
}

# -----------------------------------------------------------------------------
# Per-file planning. All projects share one environment, but each
# requirements file is updated on its own terms: for every pinned line the
# newest release that is old enough and satisfies the constraints that apply
# to THAT file (constraints.txt + its own constraints_<project>.txt) is
# chosen, starting from the version pinned in that file. So ternary can stay
# on wrapt 1.x while every other project moves to 2.x.
# For non-== lines (>=, ~=, <=, ...) the line's own range is honoured too.
# -----------------------------------------------------------------------------
declare -A PKG_FILES PIN_NAME PIN_CURR PIN_TARGET PIN_TDATE PIN_FAILED FIND_CACHE ENV_FAILED
PLAN_KEYS=()

plan_file_updates() {
  local f line pkg op cur_ver pkg_norm spec cache_key key res
  local latest_v latest_d target target_d
  if [ "$HAVE_PACKAGING" != true ]; then
    echo "Note: 'packaging' is unavailable - per-file checks skipped, requirements files will not be patched"
    return
  fi
  local plan_total plan_i=0
  plan_total=$(count_pins)
  for f in "${REQUIREMENTS_FILES[@]}"; do
    [ -t 1 ] || echo "  $f"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        \#*|'') continue ;;
      esac
      op=$(echo "$line" | sed -nE 's/^[A-Za-z0-9_.-]+(==|>=|<=|~=|!=|>|<).*/\1/p')
      [ -z "$op" ] && continue
      pkg=$(echo "$line" | sed -E 's/^([A-Za-z0-9_.-]+).*/\1/')
      plan_i=$((plan_i + 1))
      progress "[$plan_i/$plan_total] $f: $pkg (querying PyPI)"
      cur_ver=$(echo "$line" | sed -E "s/^[A-Za-z0-9_.-]+(==|>=|<=|~=|!=|>|<)([^[:space:]#]*).*/\\2/")
      pkg_norm=$(normalize_pkg "$pkg")
      spec=$(applicable_spec "$f" "$pkg_norm")
      [ "$op" != "==" ] && spec="${op}${cur_ver}${spec:+,$spec}"
      cache_key="$pkg_norm|$cur_ver|$spec"
      if [ -z "${FIND_CACHE[$cache_key]+x}" ]; then
        FIND_CACHE[$cache_key]=$(find_installable_version "$pkg" "$cur_ver" "$MIN_AGE_DAYS" "$spec")
      fi
      res="${FIND_CACHE[$cache_key]}"
      IFS=$'\t' read -r latest_v latest_d target target_d <<< "$res"
      key="$f|$pkg_norm"
      PKG_FILES[$pkg_norm]="${PKG_FILES[$pkg_norm]:-} $f"
      PIN_NAME[$key]="$pkg"
      PIN_CURR[$key]="$cur_ver"
      PIN_TARGET[$key]="$target"
      PIN_TDATE[$key]="$target_d"
      [ -z "$latest_v" ] && PIN_FAILED[$key]=1
      PLAN_KEYS+=("$key")
    done < "$f"
  done
  progress_done
  echo "Checked $plan_i pinned line(s) against PyPI."
}

# Prints the distinct versions the requirements files that pin package $1
# (normalized name) will have once the planned updates are applied.
pkg_versions_after_update() {
  local pkg_norm="$1" f key
  for f in ${PKG_FILES[$pkg_norm]:-}; do
    key="$f|$pkg_norm"
    printf '%s\n' "${PIN_TARGET[$key]:-${PIN_CURR[$key]}}"
  done | sort -u | tr '\n' ' '
}

# Applies (or, in --dry-run, only reports) the planned per-file updates.
# A package whose install into the environment failed is not patched.
FILE_UPDATED=0
apply_file_updates() {
  local key f pkg_norm name target new_name header_done=false
  for key in "${PLAN_KEYS[@]}"; do
    f="${key%%|*}"
    pkg_norm="${key#*|}"
    name="${PIN_NAME[$key]}"
    target="${PIN_TARGET[$key]:-}"
    if [ -n "${PIN_FAILED[$key]:-}" ]; then
      [ "$header_done" = false ] && { echo ""; echo "Requirements file updates:"; header_done=true; }
      printf "%-30s %-28s %-12s FAILED (PyPI lookup or constraint)\n" "$name" "$f" "${PIN_CURR[$key]}"
      continue
    fi
    [ -z "$target" ] && continue
    [ "$header_done" = false ] && { echo ""; echo "Requirements file updates:"; header_done=true; }
    if [ -n "${ENV_FAILED[$pkg_norm]:-}" ]; then
      printf "${YELLOW}%-30s${RESET} %-28s %-12s %-12s ${YELLOW}SKIPPED (install failed)${RESET}\n" "$name" "$f" "${PIN_CURR[$key]}" "$target"
      continue
    fi
    if [ "$DRY_RUN" = false ]; then
      new_name=$(display_name "$name")
      perl -i -pe "s/^(\\Q${name}\\E)(==|>=|<=|~=|!=|>|<)([^\\s#]*)(.*)\$/${new_name}==${target}\${4}/i" "$f"
    fi
    printf "${GREEN}%-30s${RESET} %-28s %-12s ${GREEN}%-12s${RESET} %-12s\n" "$name" "$f" "${PIN_CURR[$key]}" "$target" "${PIN_TDATE[$key]}"
    FILE_UPDATED=$((FILE_UPDATED + 1))
  done
  [ "$header_done" = true ] && echo "Requirements lines updated: $FILE_UPDATED"
}

echo ""
echo "Checking requirements files..."
plan_file_updates

# Get outdated packages as JSON
echo ""
echo "Checking for outdated packages..."
OUTDATED=$(pip list --outdated --format=json)
COUNT=$(echo "$OUTDATED" | jq 'length')

if [ "$COUNT" -eq 0 ]; then
  echo "All packages are up to date."
  apply_file_updates
  exit 0
fi

echo "Found $COUNT outdated package(s)."
echo ""
printf "%-30s %-12s %-12s %-12s %-8s\n" "PACKAGE" "CURRENT" "NEW" "RELEASED" "STATUS"
echo "-------------------------------------------------------------------------"

UPDATED=0
SKIPPED=0
TOO_NEW=0
ENV_LEFT=0

# Today's date as epoch seconds
TODAY_EPOCH=$(date +%s)

# Process each outdated package (once, regardless of how many requirements
# files reference it)
while IFS= read -r row; do
  name=$(echo "$row" | jq -r '.name')
  curr=$(echo "$row" | jq -r '.version')
  latest=$(echo "$row" | jq -r '.latest_version')
  pkg_lower=$(normalize_pkg "$name")

  # Constrained packages are still upgraded, but only to the newest
  # release that satisfies every constraint (see find_installable_version).
  # Fails closed: if the constraint can't be evaluated (no packaging
  # library, or no bare specifier recorded), the package is skipped.
  constraint=${CONSTRAINTS[$pkg_lower]:-}
  constraint_spec=${CONSTRAINT_SPECS[$pkg_lower]:-}
  if [ -n "$constraint" ] && { [ "$HAVE_PACKAGING" != true ] || [ -z "$constraint_spec" ]; }; then
    printf "${YELLOW}%-30s${RESET} %-12s %-12s %-12s ${YELLOW}SKIPPED (constrained: %s; cannot evaluate)${RESET}\n" "$name" "$curr" "$latest" "-" "$constraint"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # The requirements files that pin this package may end up on different
  # versions (e.g. ternary on wrapt 1.x, everything else on 2.x). The
  # environment is shared and can only hold one, so it is left unchanged;
  # each file is still updated on its own by apply_file_updates.
  versions_after=$(pkg_versions_after_update "$pkg_lower")
  if [ "$(printf '%s' "$versions_after" | wc -w)" -gt 1 ]; then
    printf "${YELLOW}%-30s${RESET} %-12s %-12s %-12s ${YELLOW}ENV UNCHANGED (files differ: %s)${RESET}\n" "$name" "$curr" "$latest" "-" "${versions_after% }"
    ENV_LEFT=$((ENV_LEFT + 1))
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
    IFS=$'\t' read -r pypi_latest latest_date target target_date < <(find_installable_version "$name" "$curr" "$MIN_AGE_DAYS" "$constraint_spec")
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

  if [ -z "$target" ] && [ -n "$constraint" ]; then
    # No newer release is both old enough and allowed by the constraints.
    printf "${YELLOW}%-30s${RESET} %-12s %-12s %-12s ${YELLOW}SKIPPED (constrained: %s; no newer allowed release)${RESET}\n" "$name" "$curr" "$pypi_latest" "-" "$constraint"
    SKIPPED=$((SKIPPED + 1))
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
    # Requirements files are patched separately, per file, by
    # apply_file_updates (each file gets the newest version allowed for it).
    if [ -n "$constraint" ]; then
      printf "${GREEN}%-30s${RESET} %-12s ${GREEN}%-12s${RESET} %-12s ${GREEN}UPDATED (within %s; latest %s)${RESET}\n" "$name" "$curr" "$target" "$target_date" "$constraint" "$pypi_latest"
    elif [ "$target" = "$pypi_latest" ]; then
      printf "${GREEN}%-30s${RESET} %-12s ${GREEN}%-12s${RESET} %-12s ${GREEN}UPDATED${RESET}\n" "$name" "$curr" "$target" "$target_date"
    else
      printf "${GREEN}%-30s${RESET} %-12s ${GREEN}%-12s${RESET} %-12s ${GREEN}UPDATED (latest %s too new)${RESET}\n" "$name" "$curr" "$target" "$target_date" "$pypi_latest"
    fi
    UPDATED=$((UPDATED + 1))
  else
    ENV_FAILED[$pkg_lower]=1
    printf "%-30s %-12s %-12s %-12s FAILED\n" "$name" "$curr" "$target" "$target_date"
  fi

done < <(echo "$OUTDATED" | jq -c '.[]')

echo "-------------------------------------------------------------------------"
echo "Updated: $UPDATED  Skipped (constrained): $SKIPPED  Too new: $TOO_NEW  Env unchanged (files differ): $ENV_LEFT"
apply_file_updates
echo ""

echo ""
echo "Unresolved constraints:"
pip check

echo ""
echo "Writing requirements_installed.txt"
mkdir -p postinstall
pip freeze > postinstall/requirements_installed.txt
echo "Writing requirements_toplevel.txt"
pipdeptree -f --warn silence | grep -E '^[a-zA-Z0-9\-]+' > postinstall/requirements_toplevel.txt
echo "Writing requirements_deptree.txt"
pipdeptree -fl --warn silence > postinstall/requirements_deptree.txt
