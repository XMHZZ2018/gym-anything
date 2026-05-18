#!/bin/bash
set -e
echo "=== Warmup: launching bare LibreOffice Writer ==="
su - ga -c "DISPLAY=:1 libreoffice --writer --norestore > /dev/null 2>&1 &"
sleep 4
source /workspace/scripts/task_utils.sh 2>/dev/null || true
ensure_writer_loaded || true
echo "=== Warmup complete ==="
