#!/usr/bin/env python3
"""Validate deployment input; emit the secret payload only to the SSH pipe."""

import json
import os
import re
import sys


def configuration(environ):
    host = environ["GCP_APP_HOST"]
    if not re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?", host):
        raise ValueError("Invalid application host")
    origin = "https://" + host
    client = json.loads(environ["GOOGLE_OAUTH_CLIENT_JSON"])["web"]
    if client.get("project_id") != environ["GCP_PROJECT_ID"]:
        raise ValueError("OAuth client must belong to the deployment project")
    required_redirects = {origin + "/session/google/callback", origin + "/google/callback"}
    if not required_redirects.issubset(client.get("redirect_uris", [])):
        raise ValueError("OAuth client is missing a required callback")
    if origin not in client.get("javascript_origins", []):
        raise ValueError("OAuth client is missing the application JavaScript origin")
    domains = ",".join(d.strip().lower() for d in environ["GOOGLE_SIGN_IN_DOMAINS"].split(",") if d.strip())
    if domains and not all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+", d) for d in domains.split(",")):
        raise ValueError("Invalid Google sign-in domain allowlist")
    number = environ["GOOGLE_CLOUD_PROJECT_NUMBER"]
    if not re.fullmatch(r"[0-9]+", number):
        raise ValueError("Invalid Google Cloud project number")
    values = {
        "APP_URL": origin,
        "GOOGLE_CLIENT_ID": client["client_id"],
        "GOOGLE_CLIENT_SECRET": client["client_secret"],
        "GOOGLE_PICKER_API_KEY": environ["GOOGLE_PICKER_API_KEY"],
        "GOOGLE_SIGN_IN_DOMAINS": domains,
        "GOOGLE_CLOUD_PROJECT_NUMBER": number,
    }
    if not all(isinstance(v, str) and (v or k == "GOOGLE_SIGN_IN_DOMAINS") for k, v in values.items()):
        raise ValueError("Missing Google configuration")
    return {"mode": "apply", "host": host, "environment": values}


if __name__ == "__main__":
    try:
        payload = configuration(os.environ)
        if sys.argv[1:] == ["--validate"]:
            print("Google OAuth project, callbacks, origin, domains, and Picker settings validated")
        elif not sys.argv[1:]:
            payload["expected_revision"] = os.environ["EXPECTED_REVISION"]
            payload["expected_image"] = os.environ["EXPECTED_IMAGE"]
            print(json.dumps(payload))
        else:
            raise ValueError("Unsupported arguments")
    except Exception:
        # Do not print exception values or the input: they may contain secrets.
        print("Google configuration is invalid; check the protected deployment secrets and variables", file=sys.stderr)
        sys.exit(1)
