"""迁移测试只使用 TemporaryDirectory，不读取真实 home，也不启动任何客户端。"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import stat
import tempfile
import tomllib
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "migrate_workspace_skills.py"
SPEC = importlib.util.spec_from_file_location("migrate_workspace_skills", MODULE_PATH)
migration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migration)


class SkillMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="quotio-migration-fixture-")
        self.home = Path(self.temporary.name).resolve()
        self.names = ["alpha", "beta", "disabled-one", "disabled-two", "solo"]
        self.create_fixture()

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, relative, data, mode=0o640):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))
        path.chmod(mode)
        return path

    def create_fixture(self):
        for name in self.names:
            self.write(f".agents/skills/{name}/SKILL.md", f"---\nname: {name}\n---\n中文技能正文\n")
            self.write(f".agents/skills/{name}/bin/run.sh", "#!/bin/sh\necho fixture\n", 0o751)
            (self.home / ".agents/skills" / name).chmod(0o750)
        (self.home / ".agents/skills").chmod(0o750)
        self.write(".agents/.skill-lock.json", '{"skills":{"alpha":{"source":"fixture"}}}')
        for client, names in {"claude": ["alpha", "disabled-one"], "codex_legacy": ["beta", "disabled-one"],
                              "opencode": ["alpha"], "gemini": ["solo", "disabled-two"]}.items():
            root = self.home / migration.CLIENT_ROOTS[client]
            root.mkdir(parents=True, exist_ok=True)
            for index, name in enumerate(names):
                target = self.home / ".agents/skills" / name
                # 同时覆盖相对/绝对链接，回滚必须保留原始 readlink 文本。
                raw = os.path.relpath(target, root) if index == 0 else str(target)
                (root / name).symlink_to(raw, target_is_directory=True)
        self.write(".claude/skills/local-only/SKILL.md", "客户端独立技能")
        self.write(".pi/agent/skills/pi-only/SKILL.md", "Pi 保持不变")
        self.write(".config/opencode/opencode.jsonc", '{\n// 注释必须保留\n"provider":{"url":"https://example.invalid/path,}"},\n"permission":{"read":"ask"},\n}\n')
        configuration = '# 模型和注释必须逐字保留\nmodel = "fixture-model"\n[model_providers.fixture]\nbase_url = "https://example.invalid"\n'
        for name in ["disabled-one", "disabled-two"]:
            configuration += '\n[[skills.config]]\npath = ' + json.dumps(str(self.home / ".agents/skills" / name / "SKILL.md")) + '\nenabled = false # 保持关闭\n'
        self.write(".codex/config.toml", configuration, 0o600)
        target = self.home / ".quotio/skills"
        target.mkdir(parents=True)
        target.chmod(0o711)
        with sqlite3.connect(self.home / ".quotio/quotio.db") as database:
            database.execute("CREATE TABLE marker(value TEXT)")
            database.execute("INSERT INTO marker VALUES ('keep unchanged')")

    def snapshot(self, exclude_backups=False):
        """比较内容、权限、链接文字；忽略文件系统更新时间，允许失败时留下受保护备份。"""
        result = {}
        for current, directories, filenames in os.walk(self.home, followlinks=False):
            if exclude_backups and Path(current) == self.home / ".quotio":
                directories[:] = [name for name in directories if name != "skill_backups"]
            for name in sorted(directories + filenames):
                path = Path(current) / name
                info = path.lstat()
                relative = path.relative_to(self.home).as_posix()
                if path.is_symlink():
                    result[relative] = ("link", os.readlink(path))
                elif path.is_dir():
                    result[relative] = ("dir", stat.S_IMODE(info.st_mode))
                else:
                    result[relative] = ("file", stat.S_IMODE(info.st_mode), hashlib.sha256(path.read_bytes()).hexdigest())
        return result

    def test_default_dry_run_has_no_filesystem_writes(self):
        before = self.snapshot()
        result = migration.migrate(self.home)
        self.assertEqual(result["status"], "dry_run")
        self.assertEqual(result["skill_count"], 5)
        self.assertEqual(result["codex_enabled"], 3)
        self.assertEqual(result["opencode_enabled"], 5)
        self.assertEqual(before, self.snapshot())

    def test_success_preserves_content_modes_and_actual_client_state(self):
        source = self.home / ".agents/skills"
        original = migration.tree_manifest(source)
        config_before = (self.home / ".codex/config.toml").read_bytes()
        lock_before = (self.home / ".agents/.skill-lock.json").read_bytes()
        pi_before = (self.home / ".pi/agent/skills/pi-only/SKILL.md").read_bytes()
        independent = (self.home / ".claude/skills/local-only/SKILL.md").read_bytes()
        original_db = (self.home / ".quotio/quotio.db").read_bytes()
        result = migration.migrate(self.home, apply=True)
        self.assertEqual(result["status"], "complete")
        private = self.home / ".quotio/skills"
        self.assertEqual(original, migration.tree_manifest(private))
        self.assertFalse(source.is_symlink())
        self.assertEqual({path.name for path in source.iterdir()}, {"alpha", "beta", "solo"})
        for path in source.iterdir():
            self.assertTrue(path.is_symlink())
            self.assertEqual(path.resolve(), private / path.name)
        for name in self.names:
            self.assertEqual((self.home / ".config/opencode/skills" / name).resolve(), private / name)
        self.assertEqual((self.home / ".codex/skills/disabled-one").resolve(), private / "disabled-one")
        self.assertEqual({path.name for path in (self.home / ".claude/skills").iterdir()}, {"alpha", "disabled-one", "local-only"})
        self.assertEqual({path.name for path in (self.home / ".gemini/skills").iterdir()}, {"solo", "disabled-two"})
        self.assertEqual(lock_before, (self.home / ".agents/.skill-lock.json").read_bytes())
        self.assertEqual(pi_before, (self.home / ".pi/agent/skills/pi-only/SKILL.md").read_bytes())
        self.assertEqual(independent, (self.home / ".claude/skills/local-only/SKILL.md").read_bytes())
        self.assertEqual(original_db, (self.home / ".quotio/quotio.db").read_bytes())
        config_after = (self.home / ".codex/config.toml").read_bytes()
        self.assertTrue(config_after.startswith(config_before))
        before = tomllib.loads(config_before.decode())
        after = tomllib.loads(config_after.decode())
        self.assertEqual(migration.without_skill_config(before), migration.without_skill_config(after))
        disabled = {entry["path"] for entry in after["skills"]["config"] if entry["enabled"] is False}
        for name in ["disabled-one", "disabled-two"]:
            for suffix in [".agents/skills", ".quotio/skills", ".codex/skills"]:
                self.assertIn(str(self.home / suffix / name / "SKILL.md"), disabled)
        backup = Path(result["backup"])
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o700)
        self.assertEqual(original, migration.tree_manifest(backup / "original-skills"))
        self.assertEqual(config_before, (backup / "client-files/.codex/config.toml").read_bytes())
        with sqlite3.connect(backup / "quotio.db") as database:
            self.assertEqual(database.execute("SELECT value FROM marker").fetchone(), ("keep unchanged",))

    def test_failure_at_every_phase_rolls_back_original_state(self):
        for phase in ["staged", "backed_up", "source_moved", "target_published", "links_updated", "config_updated", "verified"]:
            with self.subTest(phase=phase):
                before = self.snapshot(exclude_backups=True)
                with self.assertRaises(migration.MigrationError):
                    migration.migrate(self.home, apply=True, fail_after=phase)
                self.assertEqual(before, self.snapshot(exclude_backups=True))
                self.assertFalse(any((self.home / ".quotio").glob(".skills-staging-*")))

    def test_nonempty_target_is_rejected_without_writes(self):
        self.write(".quotio/skills/occupied/SKILL.md", "独立目标")
        before = self.snapshot()
        with self.assertRaises(migration.MigrationError):
            migration.migrate(self.home, apply=True)
        self.assertEqual(before, self.snapshot())

    def test_opencode_independent_collision_is_rejected_without_overwrite(self):
        self.write(".config/opencode/skills/beta/SKILL.md", "用户独立技能")
        before = self.snapshot()
        with self.assertRaises(migration.MigrationError):
            migration.migrate(self.home, apply=True)
        self.assertEqual(before, self.snapshot())

    def test_complex_opencode_permission_is_rejected(self):
        self.write(".config/opencode/opencode.jsonc", '{"permission":{"skill":{"*":"ask","alpha":"deny"}}}')
        before = self.snapshot()
        with self.assertRaises(migration.MigrationError):
            migration.migrate(self.home, apply=True)
        self.assertEqual(before, self.snapshot())

    def test_internal_symlink_is_rejected(self):
        (self.home / ".agents/skills/alpha/foreign-link").symlink_to(self.home / ".codex/config.toml")
        before = self.snapshot()
        with self.assertRaises(migration.MigrationError):
            migration.migrate(self.home, apply=True)
        self.assertEqual(before, self.snapshot())

    def test_symlinked_client_parent_is_rejected(self):
        outside = self.home / "independent"
        outside.mkdir()
        (self.home / ".claude/skills/alpha").unlink()
        (self.home / ".claude/skills/alpha").symlink_to(outside)
        # OpenCode 同名专属槽不能覆盖独立链接。
        (self.home / ".config/opencode/skills/alpha").unlink()
        (self.home / ".config/opencode/skills/alpha").symlink_to(outside)
        before = self.snapshot()
        with self.assertRaises(migration.MigrationError):
            migration.migrate(self.home, apply=True)
        self.assertEqual(before, self.snapshot())

    def test_repeat_apply_refuses_to_move_native_links_as_new_source(self):
        migration.migrate(self.home, apply=True)
        before = self.snapshot()
        with self.assertRaises(migration.MigrationError):
            migration.migrate(self.home, apply=True)
        self.assertEqual(before, self.snapshot())

    def test_external_target_write_is_preserved_in_failed_backup(self):
        original_source = migration.tree_manifest(self.home / ".agents/skills")

        def external_write(phase, home):
            if phase == "config_updated":
                (home / ".quotio/skills/alpha/new-external-file.txt").write_text("外部新增内容必须保留")

        with self.assertRaises(migration.MigrationError):
            migration.migrate(self.home, apply=True, phase_callback=external_write)
        self.assertEqual(original_source, migration.tree_manifest(self.home / ".agents/skills"))
        self.assertEqual(list((self.home / ".quotio/skills").iterdir()), [])
        backups = list((self.home / ".quotio/skill_backups").glob("migration-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "failed-private-skills/alpha/new-external-file.txt").read_text(), "外部新增内容必须保留")

    def test_external_config_change_is_not_overwritten_during_rollback(self):
        original_source = migration.tree_manifest(self.home / ".agents/skills")
        external = b'model = "external-user-change"\n'

        def external_write(phase, home):
            if phase == "config_updated":
                (home / ".codex/config.toml").write_bytes(external)

        with self.assertRaisesRegex(migration.MigrationError, "回滚遇到外部冲突"):
            migration.migrate(self.home, apply=True, fail_after="config_updated", phase_callback=external_write)
        self.assertEqual((self.home / ".codex/config.toml").read_bytes(), external)
        self.assertEqual(original_source, migration.tree_manifest(self.home / ".agents/skills"))
        self.assertEqual(list((self.home / ".quotio/skills").iterdir()), [])

    def test_system_home_alias_preserves_links_and_disabled_config_identities(self):
        # macOS tempfile 常返回 /var 路径，而 resolve() 得到 /private/var；两者指向同一 fixture。
        logical_home = Path(self.temporary.name)
        if str(self.home).startswith("/private/var/"):
            logical_home = Path(str(self.home).removeprefix("/private"))
        for suffix in migration.CLIENT_ROOTS.values():
            root = self.home / suffix
            for entry in root.iterdir():
                if entry.is_symlink():
                    name = entry.resolve().name
                    entry.unlink()
                    entry.symlink_to(logical_home / ".agents/skills" / name)
        config = self.home / ".codex/config.toml"
        original = config.read_bytes().replace(str(self.home).encode(), str(logical_home).encode())
        config.write_bytes(original)
        result = migration.migrate(logical_home, apply=True)
        self.assertEqual(result["codex_enabled"], 3)
        self.assertEqual(result["codex_disabled"], ["disabled-one", "disabled-two"])
        self.assertEqual(result["opencode_enabled"], 5)
        self.assertEqual({path.name for path in (self.home / ".agents/skills").iterdir()}, {"alpha", "beta", "solo"})
        self.assertTrue(config.read_bytes().startswith(original))


if __name__ == "__main__":
    unittest.main()
