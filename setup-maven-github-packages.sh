#!/usr/bin/env bash
#
# One-time per-machine setup so Maven can read the MariTrace GitHub Packages registry,
# which is where the shared BOM (com.maritrace:maritrace-dependencies) lives.
#
# It adds/updates a <server> entry in ~/.m2/settings.xml. Any existing settings.xml is
# backed up first and otherwise left intact. Your token is never printed, and the file
# is locked to 0600. Safe to re-run (idempotent).
#
# Usage:  ./setup-maven-github-packages.sh
#
set -euo pipefail

SERVER_ID="github-maritrace"
PKG_URL="https://maven.pkg.github.com/MariTrace/maritrace_dependancies_maritrace-dependencies"
# Derive the version from the pom next to this script rather than hard-coding it,
# so the verification step cannot silently check a stale release. Falls back to a
# literal only if the pom is not alongside (e.g. the script was copied elsewhere).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOM_VERSION="$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "${SCRIPT_DIR}/pom.xml" 2>/dev/null | head -1)"
BOM_VERSION="${BOM_VERSION:-0.0.3}"
BOM_ARTIFACT="com.maritrace:maritrace-dependencies:${BOM_VERSION}:pom"
M2="${HOME}/.m2"
SETTINGS="${M2}/settings.xml"

cyan(){ printf '\n\033[1;36m%s\033[0m\n' "$*"; }
red(){  printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
grn(){  printf '\033[1;32m%s\033[0m\n' "$*"; }

cyan "MariTrace • Maven GitHub Packages setup"

command -v mvn     >/dev/null 2>&1 || { red "Maven (mvn) is not on your PATH."; exit 1; }
command -v python3 >/dev/null 2>&1 || { red "python3 is required (used to edit settings.xml safely)."; exit 1; }

# ---------------------------------------------------------------------------
# 1. Obtain a GitHub username + token with the read:packages scope.
#    Prefer the GitHub CLI if the developer is already logged in.
# ---------------------------------------------------------------------------
USERNAME=""; TOKEN=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  cyan "Using your authenticated GitHub CLI."
  if ! gh auth status 2>&1 | grep -q 'read:packages'; then
    echo "Your gh login is missing the read:packages scope — requesting it now"
    echo "(a browser window may open to approve)."
    gh auth refresh -h github.com -s read:packages
  fi
  USERNAME="$(gh api user --jq .login)"
  TOKEN="$(gh auth token)"
  echo "Authenticated as: ${USERNAME}"
else
  echo "No GitHub CLI login found. You'll need a Personal Access Token."
  echo "Create a classic token with ONLY the 'read:packages' scope:"
  echo "  https://github.com/settings/tokens/new?scopes=read:packages&description=maritrace-maven"
  read -r -p "GitHub username: " USERNAME
  read -r -s -p "GitHub token (read:packages): " TOKEN; echo
fi
[ -n "${USERNAME}" ] && [ -n "${TOKEN}" ] || { red "Username or token was empty — aborting."; exit 1; }

# ---------------------------------------------------------------------------
# 2. Merge the <server> entry into ~/.m2/settings.xml (existing content preserved).
# ---------------------------------------------------------------------------
mkdir -p "${M2}"
if [ -f "${SETTINGS}" ]; then
  backup="${SETTINGS}.bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo backup)"
  cp "${SETTINGS}" "${backup}"
  echo "Backed up existing settings.xml → ${backup}"
fi

SERVER_ID="${SERVER_ID}" MT_USER="${USERNAME}" MT_TOKEN="${TOKEN}" SETTINGS="${SETTINGS}" python3 - <<'PY'
import os, re
sid  = os.environ["SERVER_ID"]
user = os.environ["MT_USER"]
tok  = os.environ["MT_TOKEN"]
path = os.environ["SETTINGS"]

block = (f"    <server>\n"
         f"      <id>{sid}</id>\n"
         f"      <username>{user}</username>\n"
         f"      <password>{tok}</password>\n"
         f"    </server>\n")

if not os.path.exists(path):
    open(path, "w").write(
        '<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"\n'
        '          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"\n'
        '          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 '
        'https://maven.apache.org/xsd/settings-1.0.0.xsd">\n'
        '  <servers>\n' + block + '  </servers>\n</settings>\n')
    print("created new settings.xml")
else:
    s = open(path).read()
    # Idempotent: drop any prior entry for this server id, then re-add.
    s = re.sub(r'[ \t]*<server>\s*<id>' + re.escape(sid) + r'</id>.*?</server>\s*',
               '', s, flags=re.S)
    if '<servers>' in s:
        s = s.replace('<servers>', '<servers>\n' + block, 1)
    elif '</settings>' in s:
        s = s.replace('</settings>', '  <servers>\n' + block + '  </servers>\n</settings>', 1)
    else:  # a settings.xml with no <settings> wrapper is malformed; wrap defensively
        s = ('<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">\n'
             '  <servers>\n' + block + '  </servers>\n</settings>\n')
    open(path, "w").write(s)
    print("updated settings.xml (server '%s')" % sid)
PY
chmod 600 "${SETTINGS}"
grn "Configured server '${SERVER_ID}' in ${SETTINGS} (permissions set to 0600)."

# ---------------------------------------------------------------------------
# 3. Verify by actually resolving the BOM from GitHub Packages.
# ---------------------------------------------------------------------------
cyan "Verifying access by resolving the BOM…"
if mvn -q dependency:get -Dartifact="${BOM_ARTIFACT}" \
       -DremoteRepositories="${SERVER_ID}::::${PKG_URL}"; then
  grn "✅  Success — Maven on this machine can resolve the MariTrace BOM."
  cat <<EOF

Next step (per service, one-off): in the service pom.xml add

  <repositories>
    <repository>
      <id>${SERVER_ID}</id>
      <url>${PKG_URL}</url>
    </repository>
  </repositories>

then import the BOM in <dependencyManagement> and remove the <version> from any
library it manages. See the repo README for the exact snippet.
EOF
else
  red "Could not resolve the BOM. Check that your token has the read:packages scope."
  exit 1
fi
