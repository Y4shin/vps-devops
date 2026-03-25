#!/usr/bin/env bash
set -euo pipefail

SOPS_CONFIG=".sops.yaml"

if [ ! -f "$SOPS_CONFIG" ]; then
  echo "No .sops.yaml found, skipping SOPS check."
  exit 0
fi

FAILED=0
rule_count=$(yq '.creation_rules | length' "$SOPS_CONFIG")

for i in $(seq 0 $((rule_count - 1))); do
  regex=$(yq "explode(.) | .creation_rules[$i].path_regex" "$SOPS_CONFIG")

  # Collect age + pgp keys for this rule, resolving YAML anchors via explode
  raw_age=$(yq "explode(.) | .creation_rules[$i].age // \"\"" "$SOPS_CONFIG")
  raw_pgp=$(yq "explode(.) | .creation_rules[$i].pgp // \"\"" "$SOPS_CONFIG")
  mapfile -t keys < <(
    echo "$raw_age,$raw_pgp" \
      | tr ',' '\n' \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
      | grep -v '^$\|^null$' \
      || true
  )

  while IFS= read -r file; do
    [ -f "$file" ] || continue
    [[ "$file" =~ $regex ]] || continue

    if ! grep -q 'ENC\[' "$file"; then
      echo "❌ Not encrypted: $file"
      FAILED=1
      continue
    fi

    for key in "${keys[@]:-}"; do
      [ -z "$key" ] && continue
      if ! grep -q "$key" "$file"; then
        echo "❌ $file: missing recipient '$key'"
        FAILED=1
      fi
    done

  done < <(git ls-files)
done

if [ "$FAILED" -eq 1 ]; then
  echo ""
  echo "Aborting commit: fix the issues above before committing."
  exit 1
fi

echo "✅ All SOPS files are encrypted with the correct recipients."
