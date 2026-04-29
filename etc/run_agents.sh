#!/bin/bash
set -e

# Activate environment if "hermes" command not found
if ! command -v hermes &>/dev/null; then
    source /opt/hermes/.venv/bin/activate
fi

AGENTS_YML="/agents.yml"
PROFILES_DIR="/opt/data/profiles"

# =============================================================================
# Read /agents.yml and set up agent profiles
#
# Parses the YAML, resolves clone-from dependencies via topological sort so
# sources are always created before their dependents, creates any missing
# profiles, and writes/updates each profile's .env.  All errors are caught
# and logged so a bad entry never breaks container startup.
# =============================================================================

python3 - "$AGENTS_YML" "$PROFILES_DIR" <<'PYEOF'
import sys, os, subprocess

AGENTS_YML  = sys.argv[1]
PROFILES_DIR = sys.argv[2]
STATIC_ENV   = {"API_SERVER_ENABLED": "true", "API_SERVER_HOST": "0.0.0.0"}

def log(msg):  print(f"[agents] {msg}",          flush=True)
def warn(msg): print(f"[agents] WARNING: {msg}", file=sys.stderr, flush=True)

try:
    import yaml
except ImportError:
    warn("PyYAML not available – skipping profile setup")
    sys.exit(0)

# --- Load config -----------------------------------------------------------
try:
    with open(AGENTS_YML) as f:
        config = yaml.safe_load(f)
except Exception as e:
    warn(f"Cannot read {AGENTS_YML}: {e}")
    sys.exit(0)

if not isinstance(config, dict):
    log("agents.yml is empty or invalid – skipping profile setup")
    sys.exit(0)

# --- Build profile map -----------------------------------------------------
profiles = {}
for name, props in config.items():
    if not isinstance(props, dict):
        continue
    clone_from = props.get("clone-from", False)
    if not clone_from:           # normalise False / None / "" / 0
        clone_from = False
    profiles[name] = {
        "active":     bool(props.get("active", False)),
        "clone_from": clone_from,
        "env":        {str(k): str(v) for k, v in (props.get("env") or {}).items()},
    }

# --- Topological sort: sources before dependents ---------------------------
visited, order = set(), []

def visit(name, ancestors=None):
    if ancestors is None:
        ancestors = set()
    if name in visited:
        return
    if name in ancestors:
        warn(f"Circular clone-from dependency at '{name}' – skipping")
        return
    p = profiles.get(name, {})
    src = p.get("clone_from", False)
    if src and src in profiles:          # managed source → visit first
        visit(src, ancestors | {name})
    visited.add(name)
    order.append(name)

for name in profiles:
    visit(name)

# --- Create profiles and update .env ---------------------------------------
for name in order:
    p          = profiles[name]
    clone_from = p["clone_from"]
    profile_dir = os.path.join(PROFILES_DIR, name)

    # Create profile directory if it does not exist yet
    if not os.path.isdir(profile_dir):
        try:
            if clone_from:
                log(f"Creating profile '{name}' (clone from '{clone_from}')")
                cmd = ["hermes", "profile", "create", name,
                       "--clone", "--clone-from", clone_from]
            else:
                log(f"Creating profile '{name}' (blank)")
                cmd = ["hermes", "profile", "create", name]

            result = subprocess.run(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
            )
            if result.returncode != 0:
                warn(f"Failed to create profile '{name}': {result.stderr.strip()}")
                continue
            log(f"Profile '{name}' created successfully")
        except Exception as e:
            warn(f"Error creating profile '{name}': {e}")
            continue
    else:
        log(f"Profile '{name}' already exists – skipping creation")

    # Write / update .env for this profile
    try:
        os.makedirs(profile_dir, exist_ok=True)
        env_file = os.path.join(profile_dir, ".env")

        # Read existing vars so we only touch what we need to
        existing = {}
        if os.path.isfile(env_file):
            with open(env_file) as f:
                for line in f:
                    line = line.strip()
                    if "=" in line and not line.startswith("#"):
                        k, _, v = line.partition("=")
                        existing[k.strip()] = v.strip()

        # Merge priority: existing < static overrides < profile-specific vars
        merged = {**existing, **STATIC_ENV, **p["env"]}

        with open(env_file, "w") as f:
            for k, v in merged.items():
                f.write(f"{k}={v}\n")
        log(f"Updated .env for profile '{name}'")
    except Exception as e:
        warn(f"Failed to update .env for profile '{name}': {e}")

    # Fix ownership so the hermes user (non-root) can read/write the profile
    # after entrypoint.sh drops privileges via gosu.
    try:
        result = subprocess.run(
            ["chown", "-R", "hermes:hermes", profile_dir],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
        )
        if result.returncode != 0:
            warn(f"chown failed for '{name}': {result.stderr.strip()}")
        else:
            log(f"Ownership set for profile '{name}'")
    except Exception as e:
        warn(f"Failed to chown profile '{name}': {e}")

log("Profile setup complete")
PYEOF

# =============================================================================
# Start active profile gateways with auto-restart in background
#
# Each gateway runs inside a subshell restart-loop so it automatically comes
# back up if it crashes.  gosu is used so the gateway process runs under the
# same 'hermes' user that the main entrypoint will drop to, avoiding root /
# permission conflicts after the chown performed by entrypoint.sh.
# =============================================================================

_get_active_profiles() {
    python3 - "$AGENTS_YML" <<'PYEOF'
import sys
try:
    import yaml
    with open(sys.argv[1]) as f:
        config = yaml.safe_load(f)
    if isinstance(config, dict):
        for name, props in config.items():
            if isinstance(props, dict) and props.get("active", False):
                print(name)
except Exception as e:
    print(f"[agents] WARNING: {e}", file=sys.stderr, flush=True)
PYEOF
}

ACTIVE_PROFILES=$(_get_active_profiles) || ACTIVE_PROFILES=""

for profile in $ACTIVE_PROFILES; do
    echo "[agents] Starting gateway for profile '${profile}' (auto-restart enabled)"
    (
        while true; do
            echo "[agents] [${profile}] Gateway starting..."
            # Run as hermes user. Ownership was already fixed (chown -R hermes:hermes)
            # by the profile-setup step above, so no race with entrypoint.sh's chown.
            gosu hermes hermes -p "${profile}" gateway || true
            echo "[agents] [${profile}] Gateway stopped – restarting in 5 s..."
            sleep 5
        done
    ) &
done

# =============================================================================
# Execute the built-in entrypoint as usual
# =============================================================================
exec /opt/hermes/docker/entrypoint.sh "$@"
