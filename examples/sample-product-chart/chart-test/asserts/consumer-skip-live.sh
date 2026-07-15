#!/usr/bin/env bash
# DEPTH: L3
# Consumer-only assert that checks a live cluster condition and emits SKIP
# when not applicable. This exercises the consumer-first resolver path
# end-to-end: run-scenario.sh → resolve_assert_script() → consumer script → result.yaml → collect.py
set -euo pipefail

RELEASE="${RELEASE:-sample}"
NAMESPACE="${NAMESPACE:-sample}"

echo "consumer-skip-live: checking condition for release=$RELEASE namespace=$NAMESPACE"

# Simulate a check that SKIPs when condition is not applicable
# In a real scenario this would check e.g. a platform capability
CONDITION_MET="${CONDITION_MET:-false}"

if [ "$CONDITION_MET" = "true" ]; then
  echo "consumer-skip-live: condition met, would PASS"
  echo "ASSERTION_RESULT: PASS"
  echo "ASSERTION_DETAIL: {\"condition\":\"met\",\"release\":\"$RELEASE\"}"
else
  echo "consumer-skip-live: condition not applicable, SKIP"
  echo "ASSERTION_RESULT: SKIP"
  echo "ASSERTION_DETAIL: {\"reason\":\"consumer override skip - platform capability absent\",\"release\":\"$RELEASE\",\"namespace\":\"$NAMESPACE\"}"
fi
