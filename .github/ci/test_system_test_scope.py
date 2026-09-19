import unittest
from unittest.mock import patch

from system_test_scope import GOOGLE_PROFILE_FILES, PROFILE, changed_paths, scope_for


class SystemTestScopeTest(unittest.TestCase):
    def test_isolated_profile_fix_uses_google_browser_tests(self):
        self.assertEqual("google", scope_for([PROFILE]))
        self.assertEqual("google", scope_for(GOOGLE_PROFILE_FILES))

    def test_ci_only_or_test_only_changes_use_full_suite(self):
        self.assertEqual("full", scope_for(GOOGLE_PROFILE_FILES - {PROFILE}))

    def test_missing_changes_use_full_suite(self):
        self.assertEqual("full", scope_for([]))

    def test_every_unlisted_app_or_build_change_uses_full_suite(self):
        for path in ["app/javascript/controllers/huddle_controller.js", "app/views/layouts/application.html.erb",
                     "app/controllers/google/connections_controller.rb", "Gemfile.lock", "Dockerfile",
                     "test/application_system_test_case.rb", "test/system/drive_share_test.rb",
                     ".github/workflows/deploy-gcp.yml", "app/views/users/profiles/_google_calendar.html.erb.bak"]:
            with self.subTest(path=path):
                self.assertEqual("full", scope_for([PROFILE, path]))

    @patch("system_test_scope.subprocess.check_output")
    def test_new_branch_and_unknown_events_cannot_select_focused_scope(self, git):
        self.assertEqual([], changed_paths({"before": "0" * 40, "after": "a" * 40}, "push"))
        self.assertEqual([], changed_paths({}, "workflow_dispatch"))
        git.assert_not_called()

    @patch("system_test_scope.subprocess.check_output")
    def test_pull_request_diff_uses_merge_base(self, git):
        git.side_effect = ["c" * 40 + "\n", (PROFILE + "\0").encode()]
        event = {"pull_request": {"base": {"sha": "a" * 40}, "head": {"sha": "b" * 40}}}
        self.assertEqual([PROFILE], changed_paths(event, "pull_request"))
        self.assertEqual(["git", "diff", "--name-only", "-z", "c" * 40, "b" * 40, "--"], git.call_args.args[0])

    @patch("system_test_scope.subprocess.check_output")
    def test_push_diff_covers_all_commits(self, git):
        git.return_value = (PROFILE + "\0Gemfile.lock\0").encode()
        self.assertEqual("full", scope_for(changed_paths({"before": "a" * 40, "after": "b" * 40}, "push")))


if __name__ == "__main__":
    unittest.main()
