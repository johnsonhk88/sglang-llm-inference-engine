#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "${ROOT}/tests/scripts/test_launchers.sh"
bash "${ROOT}/tests/docs/test_docs.sh"
bash "${ROOT}/tests/helm/test_chart.sh"
bash "${ROOT}/tests/monitoring/test_stack.sh"
echo "All offline tests passed."
