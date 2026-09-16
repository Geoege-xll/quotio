"""来源修复回归测试：仓库和 HOME 均在临时目录中，不联网、不接触用户的安装内容。"""
import importlib.util
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("repair_skill_sources", Path(__file__).resolve().parents[1] / "repair_skill_sources.py")
repair = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(repair)


class SkillSourceRepairTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="quotio-source-fixture-")
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "home"
        self.repository = self.root / "repository"
        self.repository.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        self.git("remote", "add", "origin", "https://github.com/fixture/skills.git")
        for name in ("alpha", "beta"):
            path = self.repository / "nested" / name
            path.mkdir(parents=True)
            (path / "SKILL.md").write_text(f"---\nname: {name}\n---\n原始技能正文\n")
            (path / "REFERENCE.md").write_text("原始参考文档")
            shutil.copytree(path, self.home / ".quotio/skills" / name)
        self.commit()
        self.old_revision = self.git("rev-parse", "HEAD").strip()
        (self.repository / "nested/alpha/SKILL.md").write_text("上游新版本")
        # 只改参考文档的版本也必须参与历史比对，不能仅枚举 SKILL.md 的提交。
        (self.repository / "nested/beta/REFERENCE.md").write_text("新版参考文档")
        self.commit()
        self.database = self.home / ".quotio/quotio.db"
        with sqlite3.connect(self.database) as db:
            db.execute("""CREATE TABLE skills_metadata (directory TEXT PRIMARY KEY, name TEXT, description TEXT,
                repo_owner TEXT, repo_name TEXT, repo_branch TEXT, repository_path TEXT, readme_url TEXT,
                installed_at INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0, content_hash TEXT)""")
            db.execute("CREATE TABLE skill_repos (name TEXT)")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", "-C", str(self.repository), *args], stderr=subprocess.PIPE).decode()

    def commit(self):
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "fixture")

    def rows(self):
        with sqlite3.connect(self.database) as db:
            db.row_factory = sqlite3.Row
            return [dict(row) for row in db.execute("SELECT * FROM skills_metadata ORDER BY directory")]

    def run_repair(self, **kwargs):
        return repair.repair(self.home, [self.repository], **kwargs)

    def test_dry_run_finds_historical_files_without_writing(self):
        before = self.database.read_bytes()
        result = self.run_repair()
        self.assertEqual(result["status"], "dry_run")
        self.assertEqual(result["groups"], {"fixture/skills": 2})
        for item in result["changes"]:
            self.assertEqual(item["revision"], self.old_revision)
            self.assertEqual(item["other_differences"], [])
        self.assertEqual(self.database.read_bytes(), before)
        self.assertFalse((self.home / ".quotio/skill_backups").exists())

    def test_apply_preserves_files_other_tables_and_backup_then_is_idempotent(self):
        snapshots = {name: repair.snapshot(self.home / ".quotio/skills" / name) for name in ("alpha", "beta")}
        result = self.run_repair(apply=True)
        self.assertEqual(result["status"], "complete")
        self.assertEqual([row["repo_owner"] for row in self.rows()], ["fixture", "fixture"])
        self.assertEqual(self.rows()[0]["repository_path"], "nested/alpha")
        with sqlite3.connect(Path(result["backup"]) / "quotio.db") as backup:
            self.assertEqual(backup.execute("SELECT count(*) FROM skills_metadata").fetchone(), (0,))
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM skill_repos").fetchone(), (0,))
        for name, snapshot in snapshots.items():
            self.assertEqual(repair.snapshot(self.home / ".quotio/skills" / name), snapshot)
        evidence = json.loads((Path(result["backup"]) / "source-evidence.json").read_text())
        self.assertEqual(evidence["change_count"], 2)
        self.assertEqual(self.run_repair(apply=True)["status"], "unchanged")

    def test_existing_sources_and_existing_non_source_fields_are_preserved(self):
        with sqlite3.connect(self.database) as db:
            db.execute("INSERT INTO skills_metadata(directory,repo_owner,repo_name) VALUES ('alpha','original','repo')")
            db.execute("INSERT INTO skills_metadata(directory,name,description,installed_at,updated_at,content_hash) VALUES ('beta','自定义名字','本地备注',123,456,'local-hash')")
        result = self.run_repair(apply=True)
        self.assertEqual(result["change_count"], 1)
        alpha, beta = self.rows()
        self.assertEqual(alpha["repo_owner"], "original")
        self.assertEqual((beta["name"], beta["description"], beta["installed_at"], beta["updated_at"], beta["content_hash"]),
                         ("自定义名字", "本地备注", 123, 456, "local-hash"))

    def test_write_failure_rolls_back_all_rows_and_keeps_backup(self):
        with sqlite3.connect(self.database) as db:
            db.execute("CREATE TRIGGER reject_second BEFORE INSERT ON skills_metadata WHEN NEW.directory='beta' BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        with self.assertRaises(sqlite3.Error):
            self.run_repair(apply=True)
        self.assertEqual(self.rows(), [])
        self.assertEqual(len(list((self.home / ".quotio/skill_backups").glob("*/quotio.db"))), 1)

    def test_external_file_change_prevents_all_metadata_writes(self):
        def edit_skill():
            (self.home / ".quotio/skills/beta/SKILL.md").write_text("核实后的外部编辑")
        with self.assertRaises(repair.RepairError):
            self.run_repair(apply=True, before_write=edit_skill)
        self.assertEqual(self.rows(), [], "第二条文件变化也必须回滚已插入的第一条来源")

    def test_commit_failure_does_not_leave_success_report(self):
        reader = sqlite3.connect(self.database)
        def hold_read_lock():
            # 模拟其它进程持有 SQLite 读锁：允许 INSERT，但最终 COMMIT 会超时失败。
            reader.execute("BEGIN")
            reader.execute("SELECT * FROM skills_metadata").fetchall()
        try:
            with self.assertRaises(sqlite3.OperationalError):
                self.run_repair(apply=True, before_write=hold_read_lock)
        finally:
            reader.close()
        self.assertEqual(self.rows(), [])
        reports = list((self.home / ".quotio/skill_backups").glob("*/source-evidence.json"))
        self.assertEqual(len(reports), 1)
        self.assertEqual(json.loads(reports[0].read_text())["status"], "pending_commit")

    def test_ambiguous_repository_is_not_guessed(self):
        other = self.root / "other"
        shutil.copytree(self.repository, other)
        subprocess.check_call(["git", "-C", str(other), "remote", "set-url", "origin", "https://github.com/other/skills.git"])
        result = repair.repair(self.home, [self.repository, other], apply=True)
        self.assertEqual(result["change_count"], 0)
        self.assertEqual(result["ambiguous"], ["alpha", "beta"])
        self.assertEqual(self.rows(), [])

    def test_relocated_skill_uses_unique_current_path_with_matching_history(self):
        old = self.repository / "nested/beta"
        new = self.repository / "skills/beta"
        new.parent.mkdir()
        old.rename(new)
        self.commit()
        # 新路径先有相同正文，之后上游正常升级；本机仍保留旧版本，不能为补来源而更新内容。
        (new / "SKILL.md").write_text("上游更新后的正文")
        old.symlink_to("../skills/beta", target_is_directory=True)
        self.commit()
        result = self.run_repair(apply=True)
        beta = next(item for item in result["changes"] if item["directory"] == "beta")
        self.assertEqual(beta["repository_path"], "skills/beta")
        self.assertEqual(beta["historical_paths"], ["nested/beta", "skills/beta"])
        self.assertEqual(self.rows()[1]["repository_path"], "skills/beta")
        self.assertIn("原始技能正文", (self.home / ".quotio/skills/beta/SKILL.md").read_text())

    def test_simultaneous_duplicate_paths_remain_ambiguous(self):
        shutil.copytree(self.repository / "nested/beta", self.repository / "another/beta")
        self.commit()
        result = self.run_repair()
        self.assertIn("beta", result["ambiguous"])
        self.assertEqual([item["directory"] for item in result["changes"]], ["alpha"])

    def test_symlinked_private_library_is_rejected(self):
        skills = self.home / ".quotio/skills"
        moved = self.root / "moved-skills"
        skills.rename(moved)
        skills.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(repair.RepairError):
            self.run_repair(apply=True)
        self.assertEqual(self.rows(), [])


if __name__ == "__main__":
    unittest.main()
