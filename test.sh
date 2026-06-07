#!/usr/bin/env bash
# Run the test suite for end_point_blank (Ruby gem).
set -euo pipefail
cd "$(dirname "$0")"
exec bundle exec rspec "$@"
