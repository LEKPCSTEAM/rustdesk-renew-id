#!/usr/bin/env bash
# ติดตั้ง Renew RustDesk ID ลงรายการ app (รันด้วย sudo = ติดตั้งให้ทุก user)
set -euo pipefail
exec bash "$(dirname "$(readlink -f "$0")")/renew-rustdesk-id.sh" --install
