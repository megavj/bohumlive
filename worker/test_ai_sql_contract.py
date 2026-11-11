"""Offline SQL-contract checks: no connection, credentials, or database writes.

These verify migration patch applicability and critical boundaries. They do not
substitute for the operator's PostgreSQL permission/concurrency acceptance tests.
"""
from pathlib import Path
import re
import unittest


DB = Path(__file__).resolve().parents[1] / "db"
UPGRADE = (DB / "026_ai_upgrade.sql").read_text()
ROLLBACK = (DB / "026_ai_upgrade_rollback.sql").read_text()


def function_source(name, source=UPGRADE):
    match = re.search(
        rf"create(?: or replace)? function public\.{re.escape(name)}\(.*?"
        rf"\bas\s+(\$[a-z_]*\$)(.*?)\1\s*;",
        source,
        re.I | re.S,
    )
    if not match:
        raise AssertionError(f"Function missing: {name}")
    return match.group(0)


def patched_legacy():
    legacy = (DB / "023_ai_real_comments.sql").read_text()
    notes = (DB / "021_comment_alerts_grouped.sql").read_text()
    names = (
        "bl_post_json", "bl_comment_json", "bl_read", "bl_worker",
        "bl_action_internal", "bl_admin_read", "bl_note_visible",
    )
    definitions = {
        name: function_source(name, notes if name == "bl_note_visible" else legacy)
        for name in names
    }
    patches = re.findall(
        r"select pg_temp\.bl_aiup_patch\('public\.([a-z_]+)\([^']+\)',"
        r"\s*\$old\$(.*?)\$old\$,\s*\$new\$(.*?)\$new\$\);",
        UPGRADE,
        re.S,
    )
    if len(patches) != UPGRADE.count("select pg_temp.bl_aiup_patch("):
        raise AssertionError("Malformed guarded migration patch")
    for name, old, new in patches:
        count = definitions[name].count(old)
        if count != 1:
            raise AssertionError(f"Ambiguous or missing original source: {name} ({count})")
        definitions[name] = definitions[name].replace(old, new)
    return definitions


class AiSqlContractTests(unittest.TestCase):
    def test_every_guarded_patch_matches_023_025_exactly_once(self):
        definitions = patched_legacy()
        self.assertIn("public.bl_ai_worker_upgrade(p_action,p_payload)", definitions["bl_worker"])
        self.assertIn("public.bl_ai_enqueue(idv)", definitions["bl_action_internal"])
        self.assertIn("public.bl_ai_thread_visible(c.id)", definitions["bl_note_visible"])

    def test_worker_and_admin_paths_keep_their_authorization(self):
        worker = function_source("bl_ai_worker_upgrade")
        admin = function_source("bl_ai_admin_action")
        self.assertIn("auth.role()='service_role'", worker)
        self.assertIn("public.bl_is_admin()", admin)
        self.assertNotRegex(UPGRADE.lower(), r"grant\s+execute.*bl_ai_")
        self.assertIn("from public, anon, authenticated, service_role", UPGRADE)
        self.assertIn("enable row level security", UPGRADE)
        self.assertIn("auth.role()='service_role' or public.bl_test_visible(is_test)", function_source("bl_ai_thread_visible"))
        old = patched_legacy()["bl_worker"]
        for protected_action in ("proof_judgment", "cleanup_users", "cleanup_user_done", "heartbeat", "temporary_review"):
            self.assertIn(protected_action, old)

    def test_five_reply_limit_accounts_for_reservations_and_deleted_answers(self):
        slots = function_source("bl_ai_slots_used")
        self.assertIn("j.comment_id is null", slots)
        self.assertIn("('queued','processing','review')", slots)
        self.assertNotIn("c.status='published'", slots)
        enqueue = function_source("bl_ai_enqueue")
        self.assertLess(enqueue.index("for update"), enqueue.index("public.bl_ai_slots_used(p_post)>=5"))
        guard = function_source("bl_ai_comment_guard")
        self.assertIn("count(*)<5", guard)
        self.assertIn("for update", guard)
        worker = function_source("bl_ai_worker_upgrade")
        self.assertIn("j.comment_id is null and (select count(*)", worker)
        self.assertIn("lease_token=(p_payload->>'lease_token')::uuid and lease_until>now()", worker)

    def test_skip_completes_without_an_ai_insert_or_error(self):
        worker = function_source("bl_ai_worker_upgrade")
        branch = worker.split("if p_action='skip' then", 1)[1].split("end if;", 1)[0]
        self.assertIn("status='skipped',error_code=null,lease_token=null,lease_until=null,completed_at=now()", branch)
        self.assertNotIn("insert into public.bl_comments", branch)

    def test_peer_references_exclude_private_test_sample_and_ai_content(self):
        peers = function_source("bl_ai_peer_sources")
        for boundary in (
            "p.id<>p_post", "p.status='published'", "not p.is_test", "not p.is_sample",
            "not p.anonymous", "not ch.anonymous", "not c.is_ai", "not c.is_test",
            "not c.is_sample", "not c.anonymous", "public.bl_ai_thread_visible(c.id)",
        ):
            self.assertIn(boundary, peers)
        self.assertIn("when adopted then 2", peers)
        self.assertIn("public.bl_ai_redact(c.body", peers)
        self.assertNotIn("'author_id'", peers)
        self.assertNotIn("'author_company'", peers)
        worker = function_source("bl_ai_worker_upgrade")
        self.assertIn("'is_accepted',coalesce(c.id=p.accepted_comment_id,false)", worker)
        self.assertIn("or c.id=p.accepted_comment_id and not c.is_ai", worker)

    def test_related_links_are_rebuilt_from_live_public_post_ids(self):
        related = function_source("bl_ai_related_posts")
        self.assertIn("jsonb_build_object('id',x.id,'title',x.title)", related)
        self.assertIn("^[0-9a-f]{8}-", related)
        self.assertIn("p.id<>p_post", related)
        self.assertIn("not p.anonymous and ch.enabled and not ch.anonymous", related)
        self.assertIn("limit 2", related)
        self.assertNotIn("->>'url'", related)
        self.assertNotIn("->>'title'", related)
        self.assertIn("public.bl_ai_related_posts(c.post_id,c.related_posts)", function_source("bl_ai_comment_fields"))

    def test_acceptance_and_admin_changes_are_scoped_to_one_comment(self):
        accept = function_source("bl_ai_accept")
        for check in ("p.author_id=auth.uid()", "c.post_id=p.id", "not c.is_ai", "c.author_id<>auth.uid()"):
            self.assertIn(check, accept)
        self.assertIn("accepted_comment_id=cid", accept)
        admin = function_source("bl_ai_admin_action")
        self.assertEqual(admin.count("where id=j.comment_id and post_id=p.id and is_ai"), 3)
        read = patched_legacy()["bl_admin_read"]
        self.assertIn("where id=j.comment_id and post_id=j.post_id and is_ai", read)

    def test_rollback_archives_followups_and_preserves_human_comments(self):
        for kind in ("comment", "reparented_comment", "ai_job", "ai_run", "notification", "reaction", "post_acceptance"):
            self.assertIn(f"select '{kind}'", ROLLBACK)
        self.assertIn("execute r.definition", ROLLBACK)
        self.assertIn("enable row level security", ROLLBACK)
        self.assertIn("and not c.is_ai and c.parent_id is not null", ROLLBACK)
        self.assertIn("bl_comments_one_ai_per_post", ROLLBACK)
        self.assertNotRegex(ROLLBACK, r"delete from public\.bl_comments\s*;")


if __name__ == "__main__":
    unittest.main()
