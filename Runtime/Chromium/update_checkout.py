"""Advance the Bark overlay in a pinned Chromium checkout with its build outputs in place."""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
from unicodedata import normalize

from replay_gate import HERE, PINS, differences, load_recipe, temporary_index


def existing_path(src, name):
    """Look up actual directory entries, including the spelling on a case-folding volume."""
    directory = src
    for part in Path(name).parts:
        path = directory / part
        if path.is_symlink():
            raise ValueError(f"{path}: unexpected symlink in recipe path")
        if not path.exists():
            return None
        spelling = normalize("NFC", part)
        aliases = [entry for entry in directory.iterdir()
                   if normalize("NFC", entry.name).casefold() == spelling.casefold()]
        if any(normalize("NFC", entry.name) == spelling for entry in aliases):
            directory = path
        else:
            matches = [entry for entry in aliases if path.samefile(entry)]
            if len(matches) != 1:
                raise ValueError(f"{path}: ambiguous filesystem spelling")
            directory = matches[0]
    return directory


def worktree_entry(src, name, git):
    path = existing_path(src, name)
    if path is None or path != src / name or path.is_dir():
        return None
    mode = path.stat().st_mode
    if not stat.S_ISREG(mode):
        raise ValueError(f"{path}: expected a regular recipe file")
    return ("100755" if mode & stat.S_IXUSR else "100644",
            git("hash-object", "--no-filters", "--", name).strip())


def recipe_changes(git, previous, current):
    load_recipe(git, previous)
    before = git("write-tree").strip()
    git("read-tree", "HEAD")
    load_recipe(git, current)
    after = git("write-tree").strip()
    raw = git("diff-tree", "-r", "--no-renames", "--no-abbrev", "--raw", "-z", before, after)
    fields = raw.split("\0")[:-1]
    original, desired = {}, {}
    for header, name in zip(fields[::2], fields[1::2]):
        old_mode, new_mode, old_blob, new_blob, _ = header.lstrip(":").split()
        if {old_mode, new_mode} - {"000000", "100644", "100755"}:
            raise ValueError(f"{name}: unsupported recipe entry type")
        original[name] = (old_mode, old_blob) if old_mode != "000000" else None
        desired[name] = (new_mode, new_blob) if new_mode != "000000" else None
    return original, desired


def replaced_directories(src, files, desired):
    """Only remove directories whose local contents all belong to the retiring recipe."""
    retiring = {src / name for name, entry in desired.items() if entry is None}
    old_dirs = {parent for path in retiring for parent in path.parents}
    displaced = set()
    for name in files:
        for part in (Path(name), *Path(name).parents):
            actual = existing_path(src, part)
            if actual is None:
                continue
            if actual.is_dir():
                if actual != src / part or part == Path(name):
                    if actual not in old_dirs:
                        raise ValueError(f"{actual}: local directory in the recipe path")
                    displaced.add(actual)
            elif (actual != src / part or part != Path(name)) and actual not in retiring:
                raise ValueError(f"{actual}: local file with a different spelling already exists or blocks a recipe directory")

    directories = set(displaced)
    for root in displaced:
        for item in root.rglob("*"):
            if item.is_dir() and not item.is_symlink() and item in old_dirs:
                directories.add(item)
            elif item not in retiring:
                raise ValueError(f"{item}: local data in directory replaced by the recipe")
    return sorted(directories, key=lambda path: len(path.parts), reverse=True)


def advance(src, previous, current, dry_run=False):
    if subprocess.check_output(["git", "-C", src, "diff", "--cached", "--name-only", "-z", "HEAD"]):
        raise ValueError(f"{src}: preserve staged changes before updating the recipe")
    with temporary_index(src) as git:
        original, desired = recipe_changes(git, previous, current)
        unrelated = differences(git).keys() - desired.keys()
        if unrelated:
            raise ValueError("Changes outside the recipe update: " + ", ".join(sorted(unrelated)))
        pending = []
        for name, new in desired.items():
            actual = worktree_entry(src, name, git)
            if actual == new:
                continue
            if actual != original[name]:
                raise ValueError(f"{src / name}: local contents differ from both recipe revisions")
            pending.append(name)
        if not pending:
            print("Chromium already matches the requested Bark recipe.")
            return
        files = [name for name in pending if desired[name] is not None]
        directories = replaced_directories(src, files, desired)
        print(f"{src}: {len(pending)} recipe file(s) to update", flush=True)
        if dry_run:
            for name in pending:
                print(f"  {name}")
            return

        def require_original(name):
            if worktree_entry(src, name, git) != original[name]:
                raise ValueError(f"{src / name}: changed during the recipe update")

        # Stage outside src on its filesystem. After interruption every touched
        # entry is an exact old or new blob and the same command can resume.
        with tempfile.TemporaryDirectory(prefix=".bark-update-", dir=src.parent) as scratch:
            stage = Path(scratch)
            for name in files:
                mode, blob = desired[name]
                staged = stage / name
                staged.parent.mkdir(parents=True, exist_ok=True)
                staged.write_bytes(git("cat-file", "blob", blob, binary=True))
                staged.chmod(0o755 if mode == "100755" else 0o644)
            for name in pending:
                require_original(name)
            for name in pending:
                if desired[name] is None:
                    require_original(name)
                    (src / name).unlink()
            for directory in directories:
                directory.rmdir()
            for name in files:
                path = src / name
                path.parent.mkdir(parents=True, exist_ok=True)
                require_original(name)
                if original[name] is None:
                    os.link(stage / name, path)  # An unexpected new file wins.
                else:
                    (stage / name).replace(path)
        remaining = differences(git)
        if remaining:
            raise ValueError("Updated checkout differs from the recipe: " + ", ".join(sorted(remaining)))


def update_from_revision(src, revision, dry_run):
    repo = HERE.parents[1]
    rev = subprocess.check_output(["git", "-C", repo, "rev-parse", "--verify", "--end-of-options",
                                   revision + "^{commit}"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="bark-previous-recipe-") as directory:
        snapshot = Path(directory)
        # Mounted symlinks also depend on files in Packages/ and Nook/.
        with tempfile.TemporaryFile() as archive:
            subprocess.run(["git", "-C", repo, "archive", rev], stdout=archive, check=True)
            archive.seek(0)
            subprocess.run(["/usr/bin/tar", "-xf", "-", "-C", snapshot], stdin=archive, check=True)
        previous = snapshot / "Runtime/Chromium"
        pins = json.loads((previous / "PINS.json").read_text())
        if (any(pins[key] != PINS[key] for key in ("chromium", "depot_tools"))
                or (previous / "checkout.gclient").read_bytes() != (HERE / "checkout.gclient").read_bytes()):
            raise ValueError("The starting recipe uses different Chromium, depot_tools or dependency pins")
        advance(src, previous, HERE, dry_run)
