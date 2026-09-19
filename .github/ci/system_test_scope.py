"""Choose focused browser coverage for isolated Google profile consent changes.

Unknown changes, missing history, and changes to shared app code use the full
browser/LiveKit suite. The narrow allowlist also permits this CI scheduling code
to ship with a consent fix; it does not exclude arbitrary workflow or test files.
"""

import json
import os
import re
import subprocess
from pathlib import Path

PROFILE = "app/views/users/profiles/_google_calendar.html.erb"
GOOGLE_PROFILE_FILES = frozenset(
    {
        PROFILE,
        "test/controllers/users/profiles_controller_test.rb",
        ".github/workflows/ci.yml",
        ".github/ci/system_test_scope.py",
        ".github/ci/test_system_test_scope.py",
    }
)


def scope_for(paths):
    changed = set(paths)
    return "google" if PROFILE in changed and changed <= GOOGLE_PROFILE_FILES else "full"


def changed_paths(event, event_name):
    if event_name == "pull_request":
        base = event["pull_request"]["base"]["sha"]
        head = event["pull_request"]["head"]["sha"]
    elif event_name == "push":
        base, head = event["before"], event["after"]
    else:
        return []
    if any(not re.fullmatch(r"[0-9a-f]{40}", sha) or sha == "0" * 40 for sha in (base, head)):
        return []
    if event_name == "pull_request":
        base = subprocess.check_output(["git", "merge-base", base, head], text=True).strip()
    output = subprocess.check_output(["git", "diff", "--name-only", "-z", base, head, "--"])
    return output.decode().rstrip("\0").split("\0") if output else []


def main():
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        scope = scope_for(changed_paths(event, os.environ["GITHUB_EVENT_NAME"]))
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError):
        scope = "full"
    print(scope)


if __name__ == "__main__":
    main()
