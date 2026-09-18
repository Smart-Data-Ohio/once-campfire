#!/usr/bin/env python3
# Configure the current pinned image after cutover, before release logout.
# Reads secrets only from stdin; all output is an allowlisted verification result.
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request

os.umask(0o077)
request = json.load(sys.stdin)
host = request["host"]
allowed = {"APP_URL", "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GOOGLE_SIGN_IN_DOMAINS", "GOOGLE_PICKER_API_KEY", "GOOGLE_CLOUD_PROJECT_NUMBER"}

def run(args, *, data=None):
    result = subprocess.run(args, input=data, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("Command failed: " + args[0])
    return result.stdout

def current():
    ids = run(["docker", "ps", "-q", "--filter", "label=once"]).split()
    containers = json.loads(run(["docker", "inspect", *ids])) if ids else []
    found = []
    for container in containers:
        settings = json.loads(container["Config"]["Labels"].get("once", "{}"))
        if settings.get("host") == host:
            found.append((container, settings))
    if len(found) != 1:
        raise RuntimeError("Expected one running Smartfire application")
    return found[0]

def env(container):
    return dict(item.split("=", 1) for item in container["Config"].get("Env", []) if "=" in item)

def storage(container):
    return sorted((m["Type"], m["Source"], m["Destination"], m["RW"]) for m in container["Mounts"])

def protected_write(path, value):
    with path.open("x") as stream:
        stream.write(value)

try:
    with open("/var/lock/campfire-release.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if not re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?", host):
            raise RuntimeError("Invalid application host")
        before, settings = current()
        before_env = env(before)
        if request["mode"] == "plan":
            print(json.dumps({"host": host, "image": settings["image"], "revision": before_env.get("GIT_REVISION"), "configured_environment_keys": sorted(settings.get("env", {})), "override_keys": sorted(allowed), "will_preserve_existing_settings": True}))
            sys.exit(0)
        if request["mode"] != "apply":
            raise RuntimeError("Unsupported mode")
        if before_env.get("GIT_REVISION") != request["expected_revision"]:
            raise RuntimeError("Production revision changed; refusing configuration update")
        image = settings["image"]
        if image != request["expected_image"]:
            raise RuntimeError("Production image changed; refusing configuration update")
        if not re.fullmatch(r"[a-z0-9.-]+/[a-zA-Z0-9._/-]+@sha256:[0-9a-f]{64}", image):
            raise RuntimeError("Current image must be the pinned production image")
        changes = request["environment"]
        if set(changes) != allowed or not all(isinstance(v, str) and (v or k == "GOOGLE_SIGN_IN_DOMAINS") for k, v in changes.items()):
            raise RuntimeError("Unexpected or missing Google configuration")
        if changes["APP_URL"] != "https://" + host or not re.fullmatch(r"[0-9]+", changes["GOOGLE_CLOUD_PROJECT_NUMBER"]):
            raise RuntimeError("Unexpected deployment origin or project number")
        domains = changes["GOOGLE_SIGN_IN_DOMAINS"].split(",") if changes["GOOGLE_SIGN_IN_DOMAINS"] else []
        if not all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+", d) for d in domains):
            raise RuntimeError("Invalid sign-in domain allowlist")
        merged = dict(settings.get("env", {}))
        merged.update(changes)
        backup = Path("/var/backups") / time.strftime("smartfire-google-config-%Y%m%dT%H%M%SZ", time.gmtime())
        backup.mkdir(mode=0o700)
        protected_write(backup / "before-inspect.json", json.dumps(before))
        protected_write(backup / "before-settings.json", json.dumps(settings))
        args = ["once", "update", host, "--image", image, "--auto-update=false"]
        for key, value in sorted(merged.items()):
            args.extend(["--env", key + "=" + value])
        result = subprocess.run(args, capture_output=True, text=True)
        protected_write(backup / "update-output.log", result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError("ONCE configuration update failed; protected diagnostics: " + str(backup))
        deadline = time.monotonic() + 120
        while True:
            try:
                with urllib.request.urlopen("https://" + host + "/up", timeout=5) as response:
                    if response.status == 200:
                        break
            except Exception:
                pass
            if time.monotonic() >= deadline:
                raise RuntimeError("Application did not become healthy after configuration update")
            time.sleep(2)
        after, after_settings = current()
        expected_env = dict(before_env)
        expected_env.update(changes)
        if env(after) != expected_env:
            raise RuntimeError("Runtime environment verification failed")
        if after_settings.get("autoUpdate") is not False:
            raise RuntimeError("Automatic image updates must remain disabled")
        if after_settings.get("env") != merged:
            raise RuntimeError("Persistent environment verification failed")
        if storage(after) != storage(before) or after["Image"] != before["Image"]:
            raise RuntimeError("Image or storage changed unexpectedly")
        for key in settings:
            if key not in {"env", "autoUpdate"} and after_settings.get(key) != settings[key]:
                raise RuntimeError("An existing ONCE setting changed unexpectedly")
        protected_write(backup / "after-settings.json", json.dumps(after_settings))
        print(json.dumps({"host": host, "revision": env(after)["GIT_REVISION"], "configured_keys": sorted(changes), "existing_environment_preserved": True, "existing_settings_preserved": True, "image_and_storage_preserved": True, "healthy": True, "protected_backup": str(backup)}))
except Exception as error:
    if isinstance(error, RuntimeError):
        print(str(error), file=sys.stderr)
    else:
        print("Configuration operation failed: " + type(error).__name__, file=sys.stderr)
    sys.exit(1)
