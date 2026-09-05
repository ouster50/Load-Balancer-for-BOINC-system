#!/bin/bash
set -euo pipefail

POLICY=${1:?usage: set_policy.sh baseline|random|lpt|sjf|hybrid}
case "$POLICY" in
    baseline) ENABLED=0; CUSTOM_POLICY=hybrid ;;
    custom|hybrid) ENABLED=1; CUSTOM_POLICY=hybrid ;;
    random|lpt|sjf) ENABLED=1; CUSTOM_POLICY=$POLICY ;;
    *) echo "Unknown policy: $POLICY" >&2; exit 2 ;;
esac

PROJECT_ROOT=${PROJECT_ROOT:-/home/boincadm/project}
python - "$PROJECT_ROOT/config.xml" "$ENABLED" "$CUSTOM_POLICY" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, enabled, policy = sys.argv[1:]
tree = ET.parse(path)
root = tree.getroot()
config = root.find("config")
node = config.find("custom_load_balancer")
if node is None:
    node = ET.SubElement(config, "custom_load_balancer")
node.text = enabled
node = config.find("custom_lb_policy")
if node is None:
    node = ET.SubElement(config, "custom_lb_policy")
node.text = policy
tree.write(path, encoding="UTF-8")
PY

echo "Scheduler policy set to $POLICY"
