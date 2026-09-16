#!/usr/bin/env python3
"""从明确指定的 GitHub 仓库本地快照核实历史技能来源，默认只读预览，不下载或执行仓库代码。"""

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import subprocess
import sys
from urllib.parse import urlsplit
import uuid


class RepairError(Exception):
    pass


def git(checkout, *arguments):
    # 只运行固定的 Git 只读子命令；禁用部分克隆的隐式下载，执行修复不依赖联网。
    environment = dict(os.environ, GIT_NO_LAZY_FETCH="1", GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    result = subprocess.run(["git", "-C", str(checkout), *arguments], env=environment,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise RepairError("无法读取仓库快照，请先准备完整的提交及目录树：" + str(checkout))
    return result.stdout


def repository(checkout):
    remote = git(checkout, "config", "--get", "remote.origin.url").decode().strip()
    if remote.startswith("git@github.com:"):
        path = remote.removeprefix("git@github.com:")
    else:
        url = urlsplit(remote)
        if url.scheme != "https" or url.netloc.lower() != "github.com":
            raise RepairError("只接受来源明确的 GitHub 仓库快照")
        path = url.path.strip("/")
    path = path.removesuffix(".git")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", path) or any(x in (".", "..") for x in path.split("/")):
        raise RepairError("仓库地址缺少有效的 owner/repo")
    return path


def secure_path(home, path):
    # 此维护脚本只面向 ~/.quotio 私有库，不跟随其中的链接修改外部数据库或技能。
    current = home
    for component in path.relative_to(home).parts:
        current = current / component
        if current.is_symlink():
            raise RepairError("私有库路径不能包含符号链接：" + str(current))


def snapshot(directory):
    """Git blob 哈希按原始字节计算；同时记录执行位，不受 checkout 换行配置影响。"""
    result = {}
    for root, directories, files in os.walk(directory, followlinks=False):
        for name in directories + files:
            path = Path(root) / name
            if path.is_symlink():
                raise RepairError("待核实技能包含符号链接：" + str(path))
        for name in files:
            path = Path(root) / name
            if not stat.S_ISREG(path.stat().st_mode):
                raise RepairError("待核实技能包含非普通文件")
            data = path.read_bytes()
            sha = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
            result[path.relative_to(directory).as_posix()] = [sha, "100755" if path.stat().st_mode & 0o111 else "100644"]
    return result


def candidates(home, checkouts):
    root = home / ".quotio/skills"
    secure_path(home, root)
    local = {}
    for directory in sorted(root.iterdir()):
        if directory.name.startswith(".") or not (directory / "SKILL.md").is_file():
            continue
        secure_path(home, directory)
        local[directory.name] = snapshot(directory)
    matches = defaultdict(dict)
    current_paths = defaultdict(set)
    heads = {}
    for checkout in checkouts:
        repo = repository(checkout)
        revisions = git(checkout, "rev-list", "HEAD").decode().splitlines()
        heads[repo.lower()] = revisions[0]
        # 历史版本也要核实：仅对比当前 HEAD 会把旧版安装错误地当成来源不明。
        # 遍历提交树只取对象 ID，不读取/执行仓库脚本、Git hooks 或技能说明中的指令。
        for revision in revisions:
            tree = {}
            for entry in git(checkout, "ls-tree", "-r", "-z", revision).split(b"\0"):
                if not entry:
                    continue
                header, raw_path = entry.split(b"\t", 1)
                mode, kind, sha = header.decode().split()
                if kind == "blob":
                    tree[raw_path.decode()] = [sha, mode]
            for path, identity in tree.items():
                if Path(path).name != "SKILL.md":
                    continue
                relative = str(Path(path).parent)
                name = Path(relative).name
                if revision == revisions[0]:
                    current_paths[(repo.lower(), name)].add(relative)
                if name not in local or local[name]["SKILL.md"] != identity:
                    continue
                prefix = "" if relative == "." else relative + "/"
                expected = {key[len(prefix):]: value for key, value in tree.items() if key.startswith(prefix)}
                # .DS_Store 是 Finder 元数据；缺少 .keep 不代表技能正文不同，但保留差异供复核。
                actual = {key: value for key, value in local[name].items() if Path(key).name != ".DS_Store"}
                differences = sorted(key for key in actual.keys() | expected.keys() if actual.get(key) != expected.get(key))
                candidate = {"directory": name, "repository": repo, "repository_path": "" if relative == "." else relative,
                             "revision": revision, "skill_md_blob": identity[0], "other_differences": differences}
                key = (repo.lower(), relative)
                previous = matches[name].get(key)
                if previous is None or len(differences) < len(previous["other_differences"]):
                    matches[name][key] = candidate
    verified, ambiguous = [], []
    for name, values in matches.items():
        if len(values) == 1:
            verified.append(next(iter(values.values())))
            continue
        repos = {key[0] for key in values}
        # 同仓库曾迁移目录时，多个历史匹配不一定代表多个技能。只有 HEAD 中同名技能
        # 唯一、且现存路径本身也有完全匹配的历史正文，才能采用该路径；仓库间仍保留歧义。
        # Git 中指向新目录的旧软链接不是另一份 SKILL.md，因此不会重复计入现存路径。
        if len(repos) == 1:
            repo = next(iter(repos))
            paths = current_paths[(repo, name)]
            if len(paths) == 1:
                key = (repo, next(iter(paths)))
                if key in values:
                    item = dict(values[key], historical_paths=sorted(path for _, path in values), current_path_confirmed_at=heads[repo])
                    verified.append(item)
                    continue
        ambiguous.append(name)
    ambiguous.sort()
    return sorted(verified, key=lambda item: item["directory"]), ambiguous, local


def repair(home, checkouts, apply=False, before_write=None):
    home = home.resolve()
    database = home / ".quotio/quotio.db"
    secure_path(home, database)
    if not database.is_file():
        raise RepairError("请先由 Quotio 初始化技能数据库")
    verified, ambiguous, snapshots = candidates(home, checkouts)
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as reader:
        reader.row_factory = sqlite3.Row
        existing = {row["directory"]: dict(row) for row in reader.execute("SELECT * FROM skills_metadata")}

    def missing_source(row):
        # 已有任何来源证据都保留，包含不完整记录；修复工具不裁决互相冲突的来源。
        return row is None or not any(row.get(key) for key in ("repo_owner", "repo_name", "readme_url"))

    changes = [item for item in verified if missing_source(existing.get(item["directory"]))]
    report = {"status": "dry_run", "skill_count": len(snapshots), "change_count": len(changes),
              "groups": dict(Counter(item["repository"] for item in changes)), "changes": changes,
              "ambiguous": ambiguous, "preserved_existing": sorted(item["directory"] for item in verified if item not in changes)}
    if not apply or not changes:
        if apply:
            report["status"] = "unchanged"
        return report

    backup_root = home / ".quotio/skill_backups"
    secure_path(home, backup_root)
    backup = backup_root / ("source-repair-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8])
    backup.mkdir(parents=True, mode=0o700)
    # BEGIN IMMEDIATE 阻止其它写入者在备份和补齐之间改变来源；backup API 包含已提交 WAL。
    with sqlite3.connect(database, timeout=5) as writer:
        writer.row_factory = sqlite3.Row
        writer.execute("BEGIN IMMEDIATE")
        with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as reader:
            with sqlite3.connect(backup / "quotio.db") as destination:
                reader.backup(destination)
                if destination.execute("PRAGMA quick_check").fetchone() != ("ok",):
                    raise RepairError("来源修复备份未通过完整性检查")
        (backup / "quotio.db").chmod(0o600)
        # 测试回调可模拟外部文件变化或写入失败；命令行不暴露这个入口。
        if before_write:
            before_write()
        for item in changes:
            name = item["directory"]
            path = home / ".quotio/skills" / name
            secure_path(home, path)
            if snapshot(path) != snapshots[name]:
                raise RepairError("核实后技能文件发生变化，数据库事务已回滚：" + name)
            current = writer.execute("SELECT * FROM skills_metadata WHERE directory=?", (name,)).fetchone()
            if (dict(current) if current else None) != existing.get(name):
                raise RepairError("核实后来源记录发生变化，数据库事务已回滚：" + name)
            owner, repo_name = item["repository"].split("/")
            # 更新只补来源字段；保留时间、内容哈希、说明和所有客户端启用状态。
            writer.execute("""INSERT INTO skills_metadata(directory,repo_owner,repo_name,repo_branch,repository_path,readme_url)
                VALUES (?,?,?,'HEAD',?,?) ON CONFLICT(directory) DO UPDATE SET
                repo_owner=excluded.repo_owner,repo_name=excluded.repo_name,repo_branch=excluded.repo_branch,
                repository_path=excluded.repository_path,readme_url=excluded.readme_url""",
                (name, owner, repo_name, item["repository_path"], "https://github.com/" + item["repository"]))
        report.update(status="pending_commit", backup=str(backup))
        # 提交前仅记录待提交状态；最终 COMMIT 也可能失败，不能留下虚假的完成报告。
        # pending_commit 表示需要检查数据库；再次运行仍会根据现有来源保证幂等。
        report_path = backup / "source-evidence.json"
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        report_path.chmod(0o600)
    report["status"] = "complete"
    try:
        # 数据库已提交，再原子替换证据状态。此时报告写失败不能宣称数据库已经回滚。
        staged = backup / "source-evidence.tmp"
        staged.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        staged.chmod(0o600)
        staged.replace(report_path)
    except OSError:
        report["warning"] = "数据库已提交，证据文件仍为待确认状态，请以本次结果和数据库为准。"
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path)
    parser.add_argument("--checkout", type=Path, action="append", required=True, help="已核实远程地址的只读本地仓库快照，可重复")
    parser.add_argument("--apply", action="store_true")
    arguments = parser.parse_args()
    if arguments.apply and arguments.home is None:
        parser.error("--apply 必须显式指定 --home")
    try:
        print(json.dumps(repair(arguments.home or Path.home(), arguments.checkout, arguments.apply), ensure_ascii=False, indent=2))
        return 0
    except (RepairError, OSError, sqlite3.Error) as error:
        print("来源修复未完成：" + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
