import copy
import importlib.util
import io
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from contextlib import nullcontext
from types import SimpleNamespace
from unittest.mock import patch

DIRECTORY = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("google_configuration", DIRECTORY / "google-configuration.py")
producer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(producer)


class GoogleConfigurationTest(unittest.TestCase):
    def setUp(self):
        self.client = {"web": {
            "project_id": "example-project", "client_id": "example-client", "client_secret": "PRIVATE-CLIENT-SECRET",
            "javascript_origins": ["https://chat.example.com"],
            "redirect_uris": ["https://chat.example.com/session/google/callback", "https://chat.example.com/google/callback"],
        }}
        self.environ = {
            "GCP_APP_HOST": "chat.example.com", "GCP_PROJECT_ID": "example-project",
            "GOOGLE_OAUTH_CLIENT_JSON": json.dumps(self.client), "GOOGLE_PICKER_API_KEY": "PRIVATE-PICKER-KEY",
            "GOOGLE_SIGN_IN_DOMAINS": " Example.com, second.example ", "GOOGLE_CLOUD_PROJECT_NUMBER": "123456",
        }
        self.image = "example-docker.pkg.dev/example-project/app/web@sha256:" + "a" * 64

    def payload(self):
        return dict(producer.configuration(self.environ), expected_revision="b" * 40, expected_image=self.image)

    def host_run(self, payload, *, wrong_revision=False, drop_existing=False):
        settings = {"host": "chat.example.com", "image": self.image, "autoUpdate": False,
                    "env": {"WEB_CONCURRENCY": "1", "LIVEKIT_API_SECRET": "PRIVATE-LIVEKIT-SECRET"},
                    "secretKeyBase": "PRIVATE-SIGNING-KEY", "backup": {"path": "/backups"}}
        container = {"Config": {"Labels": {"once": json.dumps(settings)}, "Env": [
            "GIT_REVISION=" + ("c" * 40 if wrong_revision else "b" * 40),
            "SECRET_KEY_BASE=PRIVATE-SIGNING-KEY", "WEB_CONCURRENCY=1", "LIVEKIT_API_SECRET=PRIVATE-LIVEKIT-SECRET",
        ]}, "Mounts": [{"Type": "volume", "Source": "/storage", "Destination": "/rails/storage", "RW": True}], "Image": "image-id"}
        commands = []

        def fake_run(args, **kwargs):
            commands.append(args)
            if args[:3] == ["docker", "ps", "-q"]:
                output = "container-id\n"
            elif args[:2] == ["docker", "inspect"]:
                output = json.dumps([container])
            elif args[:2] == ["once", "update"]:
                merged = dict(args[i + 1].split("=", 1) for i, value in enumerate(args) if value == "--env")
                settings["env"] = merged
                container["Config"]["Labels"]["once"] = json.dumps(settings)
                current_env = dict(value.split("=", 1) for value in container["Config"]["Env"])
                current_env.update(merged)
                if drop_existing:
                    del current_env["SECRET_KEY_BASE"]
                container["Config"]["Env"] = [k + "=" + v for k, v in current_env.items()]
                output = "Potentially sensitive child output PRIVATE-CLIENT-SECRET"
            else:
                raise AssertionError("Unexpected command")
            return SimpleNamespace(returncode=0, stdout=output, stderr="")

        stdout, stderr = io.StringIO(), io.StringIO()
        real_path = Path
        with tempfile.TemporaryDirectory() as directory:
            temporary = real_path(directory)
            with patch("sys.stdin", io.StringIO(json.dumps(payload))), patch("sys.stdout", stdout), patch("sys.stderr", stderr), \
                 patch("builtins.open", return_value=io.StringIO()), patch("fcntl.flock"), \
                 patch("pathlib.Path", side_effect=lambda value: temporary if value == "/var/backups" else real_path(value)), \
                 patch("subprocess.run", side_effect=fake_run), \
                 patch("urllib.request.urlopen", return_value=nullcontext(SimpleNamespace(status=200))):
                code = 0
                try:
                    runpy.run_path(str(DIRECTORY / "configure-google.py"), run_name="__main__")
                except SystemExit as error:
                    code = error.code
            backups = list(temporary.glob("smartfire-google-config-*/before-settings.json"))
            if backups:
                self.assertEqual(0o600, backups[0].stat().st_mode & 0o777)
                self.assertEqual(0o700, backups[0].parent.stat().st_mode & 0o777)
            return code, stdout.getvalue(), stderr.getvalue(), commands, settings

    def test_normalizes_configured_domains_and_allows_disabling_sign_in(self):
        self.assertEqual("example.com,second.example", self.payload()["environment"]["GOOGLE_SIGN_IN_DOMAINS"])
        self.environ["GOOGLE_SIGN_IN_DOMAINS"] = ""
        self.assertEqual("", self.payload()["environment"]["GOOGLE_SIGN_IN_DOMAINS"])

    def test_rejects_wrong_project_missing_callback_origin_and_invalid_domain(self):
        for key, value in [("project_id", "other-project"), ("redirect_uris", []), ("javascript_origins", [])]:
            client = copy.deepcopy(self.client)
            client["web"][key] = value
            with self.assertRaises(ValueError):
                producer.configuration(dict(self.environ, GOOGLE_OAUTH_CLIENT_JSON=json.dumps(client)))
        with self.assertRaises(ValueError):
            producer.configuration(dict(self.environ, GOOGLE_SIGN_IN_DOMAINS="example.com;injected"))

    def test_update_preserves_existing_secrets_settings_and_storage_without_printing_secrets(self):
        code, stdout, stderr, commands, settings = self.host_run(self.payload())
        self.assertEqual(0, code, stderr)
        self.assertTrue(json.loads(stdout)["existing_environment_preserved"])
        self.assertEqual("PRIVATE-LIVEKIT-SECRET", settings["env"]["LIVEKIT_API_SECRET"])
        self.assertEqual("PRIVATE-SIGNING-KEY", settings["secretKeyBase"])
        self.assertEqual(1, sum(c[:2] == ["once", "update"] for c in commands))
        self.assertNotIn("PRIVATE-", stdout + stderr)

    def test_refuses_stale_revision_and_unexpected_configuration_before_mutation(self):
        for request, wrong_revision in [(self.payload(), True), (dict(self.payload(), expected_image="wrong"), False),
                                        (dict(self.payload(), environment={"SECRET_KEY_BASE": "replacement"}), False)]:
            code, stdout, stderr, commands, _ = self.host_run(request, wrong_revision=wrong_revision)
            self.assertEqual(1, code)
            self.assertFalse(any(c[:2] == ["once", "update"] for c in commands))
            self.assertNotIn("PRIVATE-", stdout + stderr)

    def test_detects_lost_existing_secret_without_reporting_success(self):
        code, stdout, stderr, _, _ = self.host_run(self.payload(), drop_existing=True)
        self.assertEqual(1, code)
        self.assertEqual("", stdout)
        self.assertIn("environment verification failed", stderr)
        self.assertNotIn("PRIVATE-", stderr)


if __name__ == "__main__":
    unittest.main()
