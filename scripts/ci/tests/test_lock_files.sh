#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
C="${SCRIPTS}/ci/check-lock-files.sh"

echo "== check-lock-files.sh"
R="${WORK}/lockrepo"; rm -rf "$R"; mkdir -p "$R/env"; cd "$R" && git init -q . && git config user.email t@t && git config user.name t
cat > env/versions.tf <<'TF'
terraform {
  required_providers {
    aws    = { source = "hashicorp/aws" }
    random = { source = "hashicorp/random" }
  }
}
TF
lock(){ printf '%s\n' "$@" > env/.terraform.lock.hcl; }
# A provider block as terraform writes it: $2 h1 hashes (plus a zh: one, which does not count).
prov(){ local n="$2" i; echo "provider \"registry.terraform.io/hashicorp/$1\" {"; echo '  version = "1.0.0"'; echo '  hashes = ['
  for ((i=1;i<=n;i++)); do echo "    \"h1:hash$i=\","; done; echo '    "zh:abc",'; echo '  ]'; echo '}'; }

check "no lock file fails"                   bash -c "! bash '$C' env >/dev/null 2>&1"
lock "$(prov aws 4)" "$(prov random 4)"
check "an untracked lock file fails"         bash -c "! bash '$C' env >/dev/null 2>&1"
git add env/.terraform.lock.hcl
check "a tracked, complete lock file passes" bash "$C" env
lock "$(prov aws 4)"; git add env/.terraform.lock.hcl
out="$(bash "$C" env 2>&1)"; rc=$?
check "a lock file missing a declared provider fails" test $rc -ne 0
check "and names the missing provider"       bash -c "grep -q 'hashicorp/random' <<< \"$out\""
lock "$(prov aws 1)" "$(prov random 1)"; git add env/.terraform.lock.hcl
out="$(bash "$C" env 2>&1)"; rc=$?
check "one h1 per provider (a plain init) fails" test $rc -ne 0
check "and names both providers with their counts" bash -c "grep -q 'hashicorp/aws has 1' <<< \"$out\" && grep -q 'hashicorp/random has 1' <<< \"$out\""
check "and prints the lock command"          bash -c "grep -q 'providers lock -platform=windows_amd64 -platform=linux_amd64 -platform=darwin_amd64 -platform=darwin_arm64' <<< \"$out\""
lock "$(prov aws 4)" "$(prov random 1)"; git add env/.terraform.lock.hcl
out="$(bash "$C" env 2>&1)"; rc=$?
check "one good and one thin provider fails" test $rc -ne 0
check "and names only the thin one"          bash -c "grep -q 'hashicorp/random has 1' <<< \"$out\" && ! grep -q 'hashicorp/aws has' <<< \"$out\""
lock "$(prov aws 4)"; git add env/.terraform.lock.hcl
mkdir -p env2; cp env/versions.tf env2/
check "every directory is checked, not just the first" bash -c "! bash '$C' env env2 >/dev/null 2>&1"
check "no directory given fails"             bash -c "! bash '$C' >/dev/null 2>&1"
cd - >/dev/null
finish
