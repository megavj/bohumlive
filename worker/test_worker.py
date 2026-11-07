"""Boundary tests use synthetic strings only; no live accounts or API calls."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("bl_worker", Path(__file__).with_name("bohumlive_worker.py"))
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class PrivacyBoundary(unittest.TestCase):
    def test_direct_identifiers_removed(self):
        value = "010-1234-5678 900101-1234567 test@example.invalid https://example.invalid/private"
        result = worker.redact(value)
        for token in ("1234", "900101", "test@example", "https://"):
            self.assertNotIn(token, result)

    def test_unicode_and_markup_cannot_bypass_phone_filter(self):
        result = worker.redact("０１０-１２３４-５６７８ 010\u200b12345678 <b>900101</b>-<i>1234567</i>")
        self.assertNotIn("1234", result)
        self.assertNotIn("900101", result)

    def test_prompt_has_only_allowlisted_fields(self):
        value = worker.question_data({"title": "약관 확인", "body": "어떤 순서인가요?",
                                      "name": "DO_NOT_SEND_NAME", "phone": "DO_NOT_SEND_PHONE",
                                      "id": "DO_NOT_SEND_ID", "proof_path": "DO_NOT_SEND_PROOF"})
        self.assertNotIn("DO_NOT_SEND", value)
        data = json.loads(value.split("\n", 1)[1])
        self.assertEqual(set(data), {"title", "question", "official_sources"})

    def test_unrelated_environment_credentials_never_inherited(self):
        with mock.patch.dict(worker.os.environ, {"ANTHROPIC_API_KEY": "fake",
                "BL_SERVICE_ROLE_KEY": "fake", "OPENAI_API_KEY": "fake",
                "HTTPS_PROXY": "fake", "CLAUDE_CODE_DEBUG_LOGS_DIR": "fake"}):
            env = worker.claude_environment("test-subscription")
        self.assertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "test-subscription")
        self.assertNotIn("ANTHROPIC_API_KEY", env)
        self.assertNotIn("BL_SERVICE_ROLE_KEY", env)
        self.assertNotIn("OPENAI_API_KEY", env)
        self.assertNotIn("HTTPS_PROXY", env)
        self.assertNotIn("CLAUDE_CODE_DEBUG_LOGS_DIR", env)

    def test_storage_delete_rejects_traversal_and_foreign_paths(self):
        backend = worker.Backend(worker.DEFAULT_URL, "fake")
        with mock.patch.object(backend, "request") as request:
            for value in ("../other", "another-bucket/a", "uuid/realname.png"):
                with self.assertRaises(worker.WorkerError):
                    backend.delete_proofs([value])
            request.assert_not_called()

    def test_backend_rejects_non_supabase_host(self):
        for url in ("http://localhost", "https://supabase.co.evil.invalid", "https://evil.invalid"):
            with self.assertRaises(worker.WorkerError):
                worker.Backend(url, "fake")

    def test_auth_delete_requires_canonical_uuid_and_hard_delete(self):
        backend = worker.Backend(worker.DEFAULT_URL, "fake")
        with mock.patch.object(backend, "request") as request:
            for value in ("../other", "member@example.invalid", "{10000000-0000-0000-0000-000000000001}"):
                with self.assertRaises(worker.WorkerError):
                    backend.delete_withdrawn_auth_user(value)
            request.assert_not_called()
            user_id = "10000000-0000-0000-0000-000000000001"
            backend.delete_withdrawn_auth_user(user_id)
            request.assert_called_once_with("/auth/v1/admin/users/" + user_id,
                {"should_soft_delete": False}, method="DELETE", missing_ok=True)

    def test_auth_cleanup_follows_successful_proof_cleanup(self):
        backend = mock.Mock()
        backend.rpc.side_effect = [{"paths": ["opaque-path"]}, {}, {}, {"ids": ["opaque-user"]}, {}]
        with mock.patch.object(worker, "log"):
            worker.maintenance(backend)
        self.assertEqual(backend.mock_calls, [
            mock.call.rpc("cleanup_list"), mock.call.delete_proofs(["opaque-path"]),
            mock.call.rpc("cleanup_done", {"paths": ["opaque-path"]}),
            mock.call.rpc("temporary_review"), mock.call.rpc("cleanup_users"),
            mock.call.delete_withdrawn_auth_user("opaque-user"),
            mock.call.rpc("cleanup_user_done", {"id": "opaque-user"}),
        ])

    def test_failed_proof_cleanup_never_deletes_auth_account(self):
        backend = mock.Mock()
        backend.rpc.return_value = {"paths": ["opaque-path"]}
        backend.delete_proofs.side_effect = worker.WorkerError("backend_request_failed")
        with self.assertRaises(worker.WorkerError):
            worker.maintenance(backend)
        backend.delete_withdrawn_auth_user.assert_not_called()

    def test_ai_failure_is_recorded_without_question_or_error_body(self):
        backend = mock.Mock()
        backend.rpc.side_effect = [{"job": {"id": "job", "lease_token": "lease", "body": "private"}}, {}]
        with mock.patch.object(worker, "generate", side_effect=worker.WorkerError("subscription_timeout")):
            with self.assertRaises(worker.WorkerError):
                worker.process_one(backend)
        action, payload = backend.rpc.call_args.args
        self.assertEqual(action, "fail")
        self.assertEqual(payload, {"id": "job", "lease_token": "lease", "error": "subscription_timeout"})


if __name__ == "__main__":
    unittest.main()
