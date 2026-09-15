#!/bin/bash
set -euo pipefail

EXPERIMENT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP_NAME=hybrid_synthetic
APP_VERSION=1.0
PROJECT_ROOT=${PROJECT_ROOT:-/home/boincadm/project}
MAX_WUS_TO_SEND=${MAX_WUS_TO_SEND:-1}
MAX_WUS_IN_PROGRESS=${MAX_WUS_IN_PROGRESS:-2}

if [[ -f "${PROJECT_ROOT}.dst/config.xml" ]]; then
    PROJECT_DIR="${PROJECT_ROOT}.dst"
elif [[ -f "$PROJECT_ROOT/config.xml" ]]; then
    PROJECT_DIR="$PROJECT_ROOT"
else
    echo "BOINC project is not initialized" >&2
    exit 2
fi

case "$(uname -m)" in
    x86_64) PLATFORM=x86_64-pc-linux-gnu ;;
    aarch64|arm64) PLATFORM=aarch64-unknown-linux-gnu ;;
    *)
        echo "Unsupported experiment platform: $(uname -m)" >&2
        exit 3
        ;;
esac

# apps/uppercase is built by the server tree.  Depending on how libtool links
# it, the real ELF binary is either apps/uppercase or apps/.libs/uppercase,
# with the other one being a wrapper shell script.
APP_BINARY=""
for candidate in /usr/local/boinc/apps/.libs/uppercase \
                 /usr/local/boinc/apps/uppercase; do
    [[ -x "$candidate" ]] || continue
    [[ "$(head -c 2 "$candidate")" == "#!" ]] && continue
    APP_BINARY="$candidate"
    break
done
if [[ -z "$APP_BINARY" ]]; then
    echo "Compiled BOINC uppercase app not found under /usr/local/boinc/apps" >&2
    ls -la /usr/local/boinc/apps /usr/local/boinc/apps/.libs 2>/dev/null >&2 || true
    exit 4
fi

APP_DIR="$PROJECT_DIR/apps/$APP_NAME/$APP_VERSION/$PLATFORM"
mkdir -p "$APP_DIR" "$PROJECT_DIR/templates"
install -m 0755 "$APP_BINARY" \
    "$APP_DIR/${APP_NAME}_${APP_VERSION}_${PLATFORM}"
cp "$EXPERIMENT_DIR/server/templates/hybrid_synthetic_in" \
    "$PROJECT_DIR/templates/hybrid_synthetic_in"
cp "$EXPERIMENT_DIR/server/templates/hybrid_synthetic_out" \
    "$PROJECT_DIR/templates/hybrid_synthetic_out"
printf 'Hybrid BOINC load-balancer experiment\n' \
    > "$PROJECT_DIR/hybrid_synthetic_input.txt"

python3 - "$PROJECT_DIR/project.xml" "$APP_NAME" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, app_name = sys.argv[1:]
tree = ET.parse(path)
root = tree.getroot()
if not any(node.findtext("name") == app_name for node in root.findall("app")):
    app = ET.SubElement(root, "app")
    ET.SubElement(app, "name").text = app_name
    ET.SubElement(app, "user_friendly_name").text = "Hybrid synthetic CPU workload"
    ET.SubElement(app, "min_version").text = "1"
    tree.write(path, encoding="unicode")
PY

python3 - "$PROJECT_DIR/config.xml" "$APP_NAME" \
    "$MAX_WUS_TO_SEND" "$MAX_WUS_IN_PROGRESS" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, app_name, max_wus_to_send, max_wus_in_progress = sys.argv[1:]
tree = ET.parse(path)
root = tree.getroot()
config = root.find("config")
if config is None:
    raise SystemExit("config.xml has no <config> section")

values = {
    "max_wus_to_send": max_wus_to_send,
    "max_wus_in_progress": max_wus_in_progress,
    "custom_load_balancer": "0",
    "custom_lb_policy": "hybrid",
    "custom_lb_target_runtime": "30",
    "custom_lb_size_weight": "2",
    "custom_lb_deadline_weight": "5",
    "custom_lb_runtime_weight": "0.55",
    "debug_custom_load_balancer": "1",
}
for name, value in values.items():
    node = config.find(name)
    if node is None:
        node = ET.SubElement(config, name)
    node.text = value

daemons = root.find("daemons")
if daemons is None:
    daemons = ET.SubElement(root, "daemons")
commands = [
    f"sample_trivial_validator -d 2 --app {app_name}",
    f"sample_dummy_assimilator -d 2 --app {app_name}",
]
existing = {node.findtext("cmd") for node in daemons.findall("daemon")}
for command in commands:
    if command not in existing:
        daemon = ET.SubElement(daemons, "daemon")
        ET.SubElement(daemon, "cmd").text = command

tree.write(path, encoding="unicode")
PY

cd "$PROJECT_DIR"
bin/xadd
# --noconfirm accepts the unsigned-app warning without an interactive prompt.
# `yes | bin/update_versions` cannot be used here: under `set -o pipefail`
# `yes` dies of SIGPIPE and aborts the script after a successful update.
bin/update_versions --noconfirm

APP_FILENAME="${APP_NAME}_${APP_VERSION}_${PLATFORM}"
if [[ ! -f "$PROJECT_DIR/download/$APP_FILENAME" ]]; then
    cp "$APP_DIR/$APP_FILENAME" "$PROJECT_DIR/download/$APP_FILENAME"
fi
chmod a+r "$PROJECT_DIR/download/$APP_FILENAME"

echo "Installed $APP_NAME $APP_VERSION for $PLATFORM in $PROJECT_DIR"
