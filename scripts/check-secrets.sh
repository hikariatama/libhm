#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
gitleaks git . --config .gitleaks.toml --redact --no-banner --log-opts="--all"
gitleaks dir . --config .gitleaks.toml --redact --no-banner
