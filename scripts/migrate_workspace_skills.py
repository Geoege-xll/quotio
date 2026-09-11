#!/usr/bin/env python3
"""把已确认布局的共享技能迁移到 Quotio 私有库；默认只读预检，不执行迁移。

需要 Python 3.11+，仅依赖标准库。执行前应关闭会修改这些文件的旧版 Quotio。
配置正文不写入日志；任何可捕获异常都会恢复源目录、目标、客户端链接与 Codex 配置。
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import sys
import time
import tomllib
import uuid


class MigrationError(RuntimeError):
    """仅向用户输出不包含配置值/密钥的可处理错误。"""


CLIENT_ROOTS = {
    "claude": ".claude/skills",
    "codex_legacy": ".codex/skills",
    "opencode": ".config/opencode/skills",
    "gemini": ".gemini/skills",
}
CONFIG_PATHS = (
    ".codex/config.toml", ".config/opencode/opencode.json",
    ".config/opencode/opencode.jsonc", ".claude/settings.json",
    ".gemini/settings.json", ".agents/.skill-lock.json",
)


def exists(path: Path) -> bool:
    """包括悬空链接，不能把它误认为可以覆盖的空槽。"""
    return os.path.lexists(path)


def secure_path(home: Path, path: Path) -> None:
    """home 内任何父目录都不能是符号链接；允许 /var 等 home 祖先的系统映射。"""
    try:
        relative = path.relative_to(home)
    except ValueError:
        raise MigrationError("路径超出指定 home") from None
    current = home
    for component in relative.parts:
        current /= component
        if current.is_symlink():
            raise MigrationError("发现符号链接目录或文件，拒绝扩大迁移范围：" + str(current.relative_to(home)))
        if exists(current) and current != path and not current.is_dir():
            raise MigrationError("父路径不是目录：" + str(current.relative_to(home)))


def file_state(path: Path) -> dict | None:
    if not exists(path):
        return None
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise MigrationError("备份/配置对象不是普通文件")
    return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "mode": stat.S_IMODE(info.st_mode), "size": info.st_size}


def tree_manifest(root: Path) -> dict:
    """每个普通文件均校验 SHA-256、字节数、权限；目录权限同样纳入比较。"""
    if root.is_symlink() or not root.is_dir():
        raise MigrationError("技能根必须是真实目录")
    result = {".": {"kind": "directory", "mode": stat.S_IMODE(root.stat().st_mode)}}
    for current, directories, filenames in os.walk(root, followlinks=False):
        for name in sorted(directories + filenames):
            path = Path(current) / name
            info = path.lstat()
            key = path.relative_to(root).as_posix()
            if stat.S_ISDIR(info.st_mode):
                result[key] = {"kind": "directory", "mode": stat.S_IMODE(info.st_mode)}
            elif stat.S_ISREG(info.st_mode):
                result[key] = {"kind": "file", **file_state(path)}
            else:
                raise MigrationError("技能树含符号链接或特殊文件：" + key)
    return result


def directory_listing(path: Path) -> dict | None:
    """只记录客户端一级槽位，不遍历或修改其独立技能内容。"""
    if not exists(path):
        return None
    if path.is_symlink() or not path.is_dir():
        raise MigrationError("客户端技能根必须是真实目录")
    result = {}
    for entry in path.iterdir():
        info = entry.lstat()
        result[entry.name] = {"type": stat.S_IFMT(info.st_mode), "inode": info.st_ino,
                              "link": os.readlink(entry) if entry.is_symlink() else None}
    return result


def jsonc_object(data: bytes) -> dict:
    """仅用于只读权限预检；注释和尾逗号在字符串外处理，避免误改包含 URL 的字符串。"""
    try:
        text = data.decode("utf-8")
        output, index, quoted, escaped = [], 0, False, False
        while index < len(text):
            character = text[index]
            if quoted:
                output.append(character)
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    quoted = False
                index += 1
            elif character == '"':
                quoted = True
                output.append(character)
                index += 1
            elif text.startswith("//", index):
                end = text.find("\n", index)
                index = len(text) if end == -1 else end
            elif text.startswith("/*", index):
                end = text.find("*/", index + 2)
                if end == -1:
                    raise ValueError()
                output.append(" ")
                index = end + 2
            else:
                output.append(character)
                index += 1
        text = "".join(output)
        output, quoted, escaped = [], False, False
        for index, character in enumerate(text):
            if quoted:
                output.append(character)
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    quoted = False
            elif character == '"':
                quoted = True
                output.append(character)
            elif character == "," and text[index + 1:].lstrip().startswith(("}", "]")):
                continue
            else:
                output.append(character)
        value = json.loads("".join(output))
        if not isinstance(value, dict):
            raise ValueError()
        return value
    except (ValueError, UnicodeError):
        raise MigrationError("OpenCode 配置不能安全解析，未进行修改") from None


def without_skill_config(value: dict) -> dict:
    result = copy.deepcopy(value)
    skills = result.get("skills")
    if isinstance(skills, dict):
        skills.pop("config", None)
        if not skills:
            result.pop("skills")
    return result


def normalized_config_path(value: str, home: Path) -> Path:
    if value.startswith("~/"):
        value = str(home / value[2:])
    path = Path(os.path.normpath(value))
    # 只归一化 home 祖先的 /var 等系统别名，不把三种技能身份的客户端链接合并成同一路径。
    for ancestor in path.parents:
        if ancestor.resolve(strict=False) == home:
            return home / path.relative_to(ancestor)
    return path


def codex_configuration(data: bytes, home: Path, names: list[str], links: list[dict]) -> tuple[bytes, set[str]]:
    try:
        original = tomllib.loads(data.decode("utf-8"))
    except (ValueError, UnicodeError):
        raise MigrationError("Codex TOML 无法解析，未进行修改") from None
    skills = original.get("skills", {})
    if not isinstance(skills, dict) or not isinstance(skills.get("config", []), list):
        raise MigrationError("Codex skills.config 结构不受支持")
    entries = skills.get("config", [])
    by_path = {}
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str) or not isinstance(entry.get("enabled", True), bool):
            raise MigrationError("Codex 技能配置条目缺少明确路径或布尔状态")
        path = normalized_config_path(entry["path"], home)
        if path in by_path:
            raise MigrationError("Codex 技能身份存在重复配置，拒绝猜测优先级")
        by_path[path] = entry.get("enabled", True)
    disabled = {name for name in names if by_path.get(home / ".agents/skills" / name / "SKILL.md") is False}
    additions = []
    for name in sorted(disabled):
        identities = {home / ".quotio/skills" / name / "SKILL.md", home / ".codex/skills" / name / "SKILL.md"}
        identities.update(home / item["relative"] / "SKILL.md" for item in links
                          if item["client"] == "codex_legacy" and item["skill"] == name)
        for path in sorted(identities):
            if path in by_path:
                if by_path[path] is not False:
                    raise MigrationError("Codex 同一技能的新旧身份状态冲突")
                continue
            additions.append({"path": str(path), "enabled": False})
    # 原配置字节完整保留，只在文末追加禁用身份；模型、MCP、注释、多行文本均不重排。
    output = data
    if additions:
        output += b"\n\n# Quotio skill migration: preserve disabled skill identities.\n"
        for entry in additions:
            output += ("\n[[skills.config]]\npath = " + json.dumps(entry["path"], ensure_ascii=False) + "\nenabled = false\n").encode("utf-8")
    try:
        updated = tomllib.loads(output.decode("utf-8"))
    except (ValueError, UnicodeError):
        raise MigrationError("当前 TOML 写法不能安全追加 skills.config；未进行修改") from None
    if without_skill_config(original) != without_skill_config(updated) or updated.get("skills", {}).get("config", []) != entries + additions:
        raise MigrationError("Codex 配置语义校验失败")
    return output, disabled


def preflight(home: Path) -> dict:
    home = home.expanduser().resolve(strict=True)
    source, target = home / ".agents/skills", home / ".quotio/skills"
    for path in [source, target, home / ".quotio/skill_backups", home / ".quotio/quotio.db"]:
        secure_path(home, path)
    manifest = tree_manifest(source)
    names = sorted(path.name for path in source.iterdir())
    for name in names:
        if name.startswith(".") or any(ord(character) < 32 for character in name) or not (source / name).is_dir() or not (source / name / "SKILL.md").is_file():
            raise MigrationError("源根必须仅包含有 SKILL.md 的真实技能目录")
    if not names:
        raise MigrationError("源技能目录为空，无需迁移")
    if exists(target) and (not target.is_dir() or any(target.iterdir())):
        raise MigrationError("私有目标目录非空，拒绝覆盖")
    listings, links = {}, []
    for client, suffix in CLIENT_ROOTS.items():
        root = home / suffix
        secure_path(home, root)
        listing = directory_listing(root)
        listings[client] = listing
        for name, item in (listing or {}).items():
            if item["link"] is None:
                continue
            raw = item["link"]
            resolved = Path(os.path.normpath(raw if os.path.isabs(raw) else str(root / raw))).resolve(strict=False)
            try:
                relative = resolved.relative_to(source)
            except ValueError:
                continue  # 不属于共享库的独立内容原样保留。
            if len(relative.parts) != 1 or relative.parts[0] not in names:
                raise MigrationError("客户端链接指向共享技能内部或无效位置，拒绝猜测迁移方式")
            links.append({"client": client, "relative": str((root / name).relative_to(home)),
                          "skill": relative.parts[0], "old": raw, "new": str(target / relative)})
    # OpenCode 原来可扫描全部共享技能；专属槽必须补全，不能随 Codex 禁用而丢失两个技能。
    opencode = listings["opencode"] or {}
    owned = {Path(item["relative"]).name: item["skill"] for item in links if item["client"] == "opencode"}
    for name in names:
        if name in opencode and owned.get(name) != name:
            raise MigrationError("OpenCode 专属槽与独立内容冲突：" + name)
        if name not in opencode:
            links.append({"client": "opencode", "relative": ".config/opencode/skills/" + name,
                          "skill": name, "old": None, "new": str(target / name)})
    configurations, states = {}, {}
    for suffix in CONFIG_PATHS:
        path = home / suffix
        secure_path(home, path)
        states[suffix] = file_state(path)
        configurations[suffix] = path.read_bytes() if states[suffix] is not None else None
    for suffix in (".config/opencode/opencode.json", ".config/opencode/opencode.jsonc"):
        if configurations[suffix] is not None:
            permission = jsonc_object(configurations[suffix]).get("permission", {})
            if not isinstance(permission, dict) or permission.get("*", "allow") != "allow" or permission.get("skill", "allow") != "allow":
                raise MigrationError("OpenCode 存在复杂技能权限，需明确保留规则后迁移")
    updated, disabled = codex_configuration(configurations[".codex/config.toml"] or b"", home, names, links)
    return {"home": home, "source": source, "target": target, "manifest": manifest, "names": names,
            "target_mode": stat.S_IMODE(target.stat().st_mode) if exists(target) else None,
            "listings": listings, "links": links, "configurations": configurations, "config_states": states,
            "codex_updated": updated, "disabled": disabled}


def write_bytes(path: Path, data: bytes, mode: int) -> None:
    """同目录原子替换，避免配置只写了一半；调用方保证父目录在安全边界内。"""
    temporary = path.with_name(".quotio-migrate-" + uuid.uuid4().hex)
    try:
        with temporary.open("xb") as handle:
            os.chmod(temporary, mode)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if exists(temporary):
            temporary.unlink()


def verify(plan: dict) -> None:
    home, source, target = plan["home"], plan["source"], plan["target"]
    if tree_manifest(target) != plan["manifest"]:
        raise MigrationError("迁移后文件内容或权限校验失败")
    expected = set(plan["names"]) - plan["disabled"]
    if {path.name for path in source.iterdir()} != expected:
        raise MigrationError("Codex 原生技能槽集合校验失败")
    for name in expected:
        path = source / name
        if not path.is_symlink() or os.readlink(path) != str(target / name):
            raise MigrationError("Codex 原生技能槽目标校验失败")
    for item in plan["links"]:
        path = home / item["relative"]
        if not path.is_symlink() or os.readlink(path) != item["new"]:
            raise MigrationError("客户端链接校验失败")
    for suffix, original in plan["configurations"].items():
        expected_data = plan["codex_updated"] if suffix == ".codex/config.toml" else original
        path = home / suffix
        if expected_data is None or (original is None and not expected_data):
            if exists(path):
                raise MigrationError("意外创建客户端配置")
        elif not path.is_file() or path.read_bytes() != expected_data:
            raise MigrationError("客户端配置校验失败")


def migrate(home: Path, apply: bool = False, fail_after: str | None = None, phase_callback=None) -> dict:
    plan = preflight(home)
    summary = {"status": "dry_run", "skill_count": len(plan["names"]),
               "file_count": sum(item["kind"] == "file" for item in plan["manifest"].values()),
               "total_bytes": sum(item.get("size", 0) for item in plan["manifest"].values()),
               "codex_enabled": len(plan["names"]) - len(plan["disabled"]),
               "codex_disabled": sorted(plan["disabled"]), "opencode_enabled": len(plan["names"]),
               "retargeted_links": sum(item["old"] is not None for item in plan["links"]),
               "opencode_added_links": sum(item["old"] is None for item in plan["links"])}
    if not apply:
        return summary  # 此前只有读取；不建 staging、备份目录、临时配置或数据库连接。
    home, source, target = plan["home"], plan["source"], plan["target"]
    identifier = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex
    backup = home / ".quotio/skill_backups" / ("migration-" + identifier)
    staging = home / ".quotio" / (".skills-staging-" + identifier)
    changed_links, created_directories = [], []
    source_moved = target_moved = published = config_changed = False
    manifest_path = backup / "manifest.json"

    def ensure_directory(path: Path) -> None:
        if not exists(path):
            ensure_directory(path.parent)
            path.mkdir(mode=0o700)
            created_directories.append(path)
        elif path.is_symlink() or not path.is_dir():
            raise MigrationError("写入父目录已变更")

    def phase(name: str) -> None:
        if backup.exists():
            payload = {**summary, "status": name, "home": str(home), "links": plan["links"],
                       "client_listings": plan["listings"], "skills": plan["manifest"], "config_states": plan["config_states"]}
            write_bytes(manifest_path, json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8"), 0o600)
        if phase_callback is not None:
            phase_callback(name, home)  # 仅供隔离测试模拟外部写入；命令行不提供此入口。
        if fail_after == name:
            raise MigrationError("隔离测试注入失败：" + name)

    try:
        ensure_directory(staging.parent)
        shutil.copytree(source, staging, copy_function=shutil.copy2)
        if tree_manifest(staging) != plan["manifest"]:
            raise MigrationError("staging 的文件内容或权限不一致")
        phase("staged")
        ensure_directory(backup)
        os.chmod(backup, 0o700)
        for suffix, data in plan["configurations"].items():
            if data is not None:
                destination = backup / "client-files" / suffix
                ensure_directory(destination.parent)
                write_bytes(destination, data, plan["config_states"][suffix]["mode"])
        database = home / ".quotio/quotio.db"
        if database.exists():
            # SQLite backup API 合并已提交 WAL，复制结果可独立恢复；绝不 UPDATE 真实数据库。
            secure_path(home, database)
            if not stat.S_ISREG(database.lstat().st_mode):
                raise MigrationError("Quotio 数据库不是普通文件")
            with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as reader:
                with sqlite3.connect(backup / "quotio.db") as writer:
                    reader.backup(writer)
                    if writer.execute("PRAGMA quick_check").fetchone() != ("ok",):
                        raise MigrationError("SQLite 备份完整性校验失败")
            os.chmod(backup / "quotio.db", 0o600)
        phase("backed_up")
        # staging/备份耗时期间若源、配置、链接发生变化，就在原目录尚未移动前停止。
        fresh = preflight(home)
        if any(fresh[key] != plan[key] for key in ("manifest", "listings", "config_states", "links", "target_mode", "disabled")):
            raise MigrationError("预检后数据发生变化，请关闭旧客户端后重试")
        source.rename(backup / "original-skills")
        source_moved = True
        phase("source_moved")
        if exists(target):
            target.rename(backup / "original-private-skills")
            target_moved = True
        staging.rename(target)
        published = True
        phase("target_published")
        source.mkdir(mode=plan["manifest"]["."]["mode"])
        os.chmod(source, plan["manifest"]["."]["mode"])
        for name in sorted(set(plan["names"]) - plan["disabled"]):
            (source / name).symlink_to(target / name, target_is_directory=True)
        for item in plan["links"]:
            path = home / item["relative"]
            ensure_directory(path.parent)
            if item["old"] is not None:
                if not path.is_symlink() or os.readlink(path) != item["old"]:
                    raise MigrationError("客户端链接在迁移中发生变化")
                path.unlink()
            elif exists(path):
                raise MigrationError("客户端空槽在迁移中被占用")
            # 先记账再创建；创建失败也能恢复刚刚移除的原链接。
            changed_links.append(item)
            path.symlink_to(item["new"], target_is_directory=True)
        phase("links_updated")
        original = plan["configurations"][".codex/config.toml"]
        if plan["codex_updated"] != (original or b""):
            path = home / ".codex/config.toml"
            if file_state(path) != plan["config_states"][".codex/config.toml"]:
                raise MigrationError("Codex 配置在迁移中发生变化")
            ensure_directory(path.parent)
            mode = plan["config_states"][".codex/config.toml"]["mode"] if original is not None else 0o600
            write_bytes(path, plan["codex_updated"], mode)
            config_changed = True
        phase("config_updated")
        verify(plan)
        if tree_manifest(backup / "original-skills") != plan["manifest"]:
            raise MigrationError("原始目录备份校验失败")
        phase("verified")
        summary.update(status="complete", backup=str(backup))
        phase("complete")
        return summary
    except BaseException:
        restoration_errors = []

        def restore(operation) -> None:
            # 一个客户端发生外部冲突时仍尝试恢复其它独立资源，避免无关内容停在中间状态。
            try:
                operation()
            except BaseException as rollback_error:
                restoration_errors.append(type(rollback_error).__name__)

        def restore_config() -> None:
            original = plan["configurations"][".codex/config.toml"]
            path = home / ".codex/config.toml"
            if path.is_symlink() or not path.is_file() or path.read_bytes() != plan["codex_updated"]:
                raise MigrationError("回滚时 Codex 配置已被外部改动，保留当前文件")
            if original is None:
                path.unlink()
            else:
                write_bytes(path, original, plan["config_states"][".codex/config.toml"]["mode"])

        def restore_link(item: dict) -> None:
            path = home / item["relative"]
            if exists(path):
                if not path.is_symlink() or os.readlink(path) != item["new"]:
                    raise MigrationError("回滚时客户端槽已被外部改动")
                path.unlink()
            if item["old"] is not None:
                path.symlink_to(item["old"], target_is_directory=True)

        def restore_source() -> None:
            if exists(source):
                # 只删除本次创建的逐技能链接；外部写入的真实内容和原始备份都必须保留。
                for path in source.iterdir():
                    if not path.is_symlink() or os.readlink(path) != str(target / path.name):
                        raise MigrationError("回滚时原生技能槽已有外部内容")
                shutil.rmtree(source)
            (backup / "original-skills").rename(source)

        def restore_target() -> None:
            if published and exists(target):
                # 已发布目标可能在迁移期间收到新内容，一律留存，绝不以 rmtree 丢弃外部写入。
                target.rename(backup / "failed-private-skills")
            if target_moved:
                (backup / "original-private-skills").rename(target)

        try:
            if config_changed:
                restore(restore_config)
            for item in reversed(changed_links):
                restore(lambda item=item: restore_link(item))
            if source_moved:
                restore(restore_source)
            restore(restore_target)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
            # 成功的备份保留便于复核；仅清理本次创建且已经为空的客户端父目录。
            for directory in reversed(created_directories):
                if directory.exists() and directory != backup and backup not in directory.parents:
                    try:
                        directory.rmdir()
                    except OSError:
                        pass
        if backup.exists():
            try:
                phase("rollback_incomplete" if restoration_errors else "rolled_back")
            except BaseException:
                pass
        if restoration_errors:
            raise MigrationError("回滚遇到外部冲突，原始备份保留在：" + str(backup)) from None
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, help="待迁移的 home；执行 --apply 时必须明确指定")
    parser.add_argument("--apply", action="store_true", help="通过预检后执行迁移；默认仅 dry-run")
    arguments = parser.parse_args()
    if arguments.apply and arguments.home is None:
        parser.error("--apply 必须同时显式指定 --home")
    try:
        result = migrate(arguments.home or Path.home(), apply=arguments.apply)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except MigrationError as error:
        print("迁移未完成：" + str(error), file=sys.stderr)
    except Exception as error:
        # 不输出第三方异常的内容，防止 TOML/JSON 解析器带出配置中的敏感值。
        print("迁移未完成，已尝试回滚。错误类型：" + type(error).__name__, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
