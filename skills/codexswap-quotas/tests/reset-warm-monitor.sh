#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
/usr/bin/python3 "$script_dir/test_reset_warm_monitor.py"
