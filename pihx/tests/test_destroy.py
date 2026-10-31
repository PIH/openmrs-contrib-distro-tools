"""destroy, with Docker and Compose faked: two typed confirmations, a full backup before anything is
deleted, and nothing deleted whenever it stops short."""

import json
import stat
import subprocess
from unittest import mock

from pihx import compose, lock
from pihx.commands import archive, destroy
from pihx.tests.fixtures import write
from pihx.tests.test_instance_cmds import run
from pihx.tests.test_lifecycle import LifecycleTest, done


class FakeDocker:
    """Docker's volumes and containers, as the docker command lines destroy runs see them."""

    def __init__(self):
        # name -> labels
        self.volumes = {
            "kz_data": {},                                     # the model's (an adopted volume)
            "kz_logs": {"pihx.instance": "kz"},                # the model's, made by pihx
            "kz_gone-svc": {"pihx.instance": "kz"},            # a removed service's
            "kz_old": {"com.docker.compose.project": "kz"},    # made by Compose before
            "kz2_data": {"pihx.instance": "kz2"},              # another instance's
            "backups": {},                                     # shared, external
        }
        self.containers = ["c1"]
        self.running = []
        self.calls = []
        self.fail = {}

    def labelled(self, label):
        key, value = label.split("=", 1)
        return [v for v, labels in self.volumes.items() if labels.get(key) == value]

    def __call__(self, argv, **kwargs):
        if argv[0] == "tar":
            self.calls.append(argv)
            return done(returncode=self.fail.get("tar-t", 0))
        args = argv[1:]
        self.calls.append(args)
        for prefix, result in self.fail.items():
            if isinstance(prefix, tuple) and args[:len(prefix)] == list(prefix):
                return result
        if args[:3] == ["volume", "ls", "-q"]:
            filters = [args[i + 1] for i, a in enumerate(args) if a == "--filter"]
            names = list(self.volumes)
            for f in filters:
                names = [n for n in names if n in self.labelled(f.removeprefix("label="))]
            return done("".join(f"{n}\n" for n in names))
        if args[:2] == ["volume", "rm"]:
            for name in args[2:]:
                self.volumes.pop(name, None)
            return done()
        if args[:2] == ["ps", "-q"]:
            return done("".join(f"{c}\n" for c in self.running))
        if args[:2] == ["ps", "-aq"]:
            return done("".join(f"{c}\n" for c in self.containers))
        if args[:1] == ["run"] and "du" in args:
            return done("2048\t/v\n")
        if args[:1] == ["run"] and "tar" in args:
            volume = next(a for a in args if a.startswith("type=volume")).split(",")[1]
            kwargs["stdout"].write(f"archive of {volume.removeprefix('source=')}".encode())
            return subprocess.CompletedProcess([], 0, stdout=None, stderr=b"")
        return done()


class DestroyTest(LifecycleTest):
    MODEL = {"volumes": {
        "data": {"external": True, "name": "kz_data"},
        "logs": {"external": True, "name": "kz_logs"},
        # Declared, but never made: not listed, so not "removed".
        "never": {"external": True, "name": "kz_never"},
        "shared": {"external": True, "name": "backups"},
    }}

    def setUp(self):
        super().setUp()
        write(self.tools / "utils" / "lib" / "images.sh", "ALPINE_IMAGE=alpine:3.21\n")
        (self.home / "kz" / "tools").symlink_to(self.tools)
        self.docker = FakeDocker()
        self.set_env({"DISK_SPACE_FREE_KB": "100000000"})
        self.config_result = done(json.dumps(self.MODEL))
        self.down_result = done()

    def failed(self):
        return done(returncode=1)

    def destroy(self, *answers, args=(), name="kz", command="destroy"):
        def fake_run(compose_self, *a, **kwargs):
            self.compose_calls.append(a)
            self.docker.calls.append(["compose", *a])
            if a[-3:] == ("config", "--format", "json"):
                if self.config_result.returncode != 0:
                    raise compose.ComposeError("config failed")
                return self.config_result
            if "down" in a:
                return self.down_result
            return done()
        with mock.patch.object(compose.Compose, "run", fake_run), \
                mock.patch.object(archive.subprocess, "run", self.docker), \
                mock.patch("builtins.input", side_effect=[*answers, EOFError()]):
            return run([name, command, *args])

    def backups(self):
        return sorted(p for p in self.home.iterdir() if ".destroyed-" in p.name)

    def removed(self):
        return [c for c in self.docker.calls if c[:2] == ["volume", "rm"]]

    def assert_nothing_deleted(self):
        self.assertEqual(self.removed(), [])
        self.assertEqual(len(self.docker.volumes), 6)
        self.assertTrue((self.home / "kz" / "instance.env").is_file())
        self.assertTrue((self.home / "kz" / "db.env").is_file())

    def downs(self):
        return [c for c in self.compose_calls if "down" in c]

    # --- refusals ---------------------------------------------------------------------------------

    def test_force_is_refused(self):
        for args in (["--force"], ["--force", "x"], ["x", "--force"]):
            with self.subTest(args=args):
                status, _, err = self.destroy("kz", "delete", args=args)
                self.assertEqual(status, 2)
                self.assertIn("destroy has no --force", err)
        self.assertEqual(self.docker.calls, [])
        self.assert_nothing_deleted()

    def test_an_unknown_option_is_refused(self):
        status, _, err = self.destroy(args=["--yes"])
        self.assertEqual(status, 2)
        self.assertIn("unknown option '--yes' for destroy", err)
        self.assertEqual(self.docker.calls, [])

    def test_a_directory_without_instance_env_is_refused(self):
        (self.home / "kz" / "instance.env").unlink()
        (self.home / "user").mkdir()
        for name in ("kz", "user"):
            with self.subTest(name=name):
                status, _, err = self.destroy(name, "delete", name=name)
                self.assertEqual(status, 1)
                self.assertIn(f"{self.home / name} has no instance.env, so it isn't an instance",
                              err)
                self.assertTrue((self.home / name).is_dir())
        self.assertEqual(self.compose_calls, [])
        self.assertEqual(self.docker.calls, [])

    def test_an_unknown_instance_is_an_error(self):
        status, _, err = self.destroy("nope", "delete", name="nope")
        self.assertEqual(status, 2)
        self.assertIn("no instance 'nope'", err)

    def test_a_held_lock_changes_nothing(self):
        with lock.hold(self.inst(), 0, command="run-service"):
            status, _, err = self.destroy("kz", "delete")
        self.assertEqual(status, 1)
        self.assertIn("kz is busy", err)
        self.assertEqual(self.docker.calls, [])
        self.assert_nothing_deleted()

    # --- the first confirmation -------------------------------------------------------------------

    def test_the_plan_lists_the_directory_and_every_volume_with_its_size(self):
        status, out, _ = self.destroy()
        self.assertEqual(status, 1)
        self.assertIn(f"directory {self.home / 'kz'}", out)
        for volume in ("kz_data", "kz_logs", "kz_gone-svc", "kz_old"):
            self.assertRegex(out, rf"volume +{volume} +2\.0M")
        for volume in ("kz2_data", "backups", "kz_never"):
            self.assertNotIn(volume, out)
        self.assertIn("development and test instances", out)

    def test_anything_but_the_name_changes_nothing(self):
        for answers in ([], ["y"], ["yes"], ["KZ"], [" kz"], ["kz2"], ["delete"]):
            with self.subTest(answers=answers):
                self.compose_calls.clear()
                status, _, err = self.destroy(*answers)
                self.assertEqual(status, 1)
                self.assertIn("destroy stopped: nothing was changed", err)
                self.assertEqual(self.downs(), [])
                self.assertEqual(self.backups(), [])
                self.assert_nothing_deleted()
        # Only reading: listings and sizes.
        self.assertFalse([c for c in self.docker.calls
                          if c[:1] == ["rm"] or c[:2] in (["volume", "rm"], ["volume", "create"])
                          or (c[:1] == ["run"] and "tar" in c)])

    # --- the backup -------------------------------------------------------------------------------

    def test_without_delete_the_instance_stays_stopped_with_its_backup_and_volumes(self):
        for second in ([], ["no"], ["DELETE"], ["kz"]):
            with self.subTest(second=second):
                for b in self.backups():
                    for f in b.iterdir():
                        f.unlink()
                    b.rmdir()
                status, _, err = self.destroy("kz", *second)
                self.assertEqual(status, 1)
                self.assertIn("nothing was deleted", err)
                self.assertIn("pihx kz start", err)
                self.assertIn("archive is kept", err)
                self.assertEqual(len(self.backups()), 1)
                self.assert_nothing_deleted()
        # Stopped, never with -v.
        self.assertTrue(self.downs())
        self.assertFalse([c for c in self.downs() if "-v" in c or "--volumes" in c])

    def test_a_full_run_backs_up_every_volume_then_removes_exactly_those(self):
        status, out, err = self.destroy("kz", "delete")
        self.assertEqual(status, 0, err)
        [backup] = self.backups()
        self.assertRegex(backup.name, r"^kz\.destroyed-\d{8}T\d{6}Z$")
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o700)
        listed = ["kz_data", "kz_gone-svc", "kz_logs", "kz_old"]
        names = sorted(p.name for p in backup.iterdir())
        self.assertEqual(names, sorted([f"{v}.tar.gz" for v in listed]
                                       + ["RESTORE.txt", "app.env", "app.override.yaml", "db.env",
                                          "instance.env"]))
        for v in listed:
            self.assertEqual((backup / f"{v}.tar.gz").read_text(), f"archive of {v}")
        # Copies of the instance's files, owner-only.
        self.assertEqual((backup / "db.env").read_text(), "DB_PASSWORD='secret $x'\n")
        for f in backup.iterdir():
            self.assertEqual(stat.S_IMODE(f.stat().st_mode), 0o600, f.name)
        # Each volume read-only, in a throwaway container; each archive read back.
        tars = [c for c in self.docker.calls if c[:1] == ["run"] and "tar" in c]
        self.assertEqual(len(tars), 4)
        for c in tars:
            self.assertIn("--rm", c)
            self.assertTrue(any(a.startswith("type=volume") and a.endswith(",readonly")
                                for a in c))
        checks = [c for c in self.docker.calls if c[:1] == ["tar"]]
        self.assertEqual(checks, [["tar", "-tzf", str(backup / f"{v}.tar.gz")] for v in listed])
        restore = (backup / "RESTORE.txt").read_text()
        self.assertIn(f"mkdir -m 700 {self.home / 'kz'}", restore)
        self.assertIn(f"cp -p {backup / 'db.env'} {self.home / 'kz'}/", restore)
        self.assertIn(f"ln -s {self.tools} {self.home / 'kz'}/tools", restore)
        for v in listed:
            self.assertIn(f"docker volume create --label pihx.instance=kz {v}\n", restore)
            self.assertIn(f"tar -xzpf - --numeric-owner -C /v < {backup / f'{v}.tar.gz'}", restore)
        self.assertIn("pihx kz start", restore)
        # Then exactly the listed volumes, and the directory, but not the tools it linked.
        self.assertEqual(self.removed(), [["volume", "rm", *listed]])
        self.assertEqual(sorted(self.docker.volumes), ["backups", "kz2_data"])
        self.assertFalse((self.home / "kz").exists())
        self.assertTrue((self.tools / "services").is_dir())
        self.assertIn(f"The archive is in {backup}/", out)
        # The backup is written before the second question.
        self.assertIn("Archived kz to", out)

    def test_the_backup_comes_after_the_stop(self):
        status, _, err = self.destroy("kz", "no")
        self.assertEqual(status, 1)
        calls = self.docker.calls
        down = next(i for i, c in enumerate(calls) if c[:1] == ["compose"] and "down" in c)
        first_tar = next(i for i, c in enumerate(calls) if c[:1] == ["run"] and "tar" in c)
        self.assertLess(down, first_tar)

    def test_an_unwritable_backup_directory_changes_nothing(self):
        with mock.patch.object(archive.os, "mkdir", side_effect=PermissionError(13, "Permission denied")):
            status, _, err = self.destroy("kz", "delete")
        self.assertEqual(status, 1)
        self.assertIn("can't write the archive", err)
        self.assertIn("nothing was changed", err)
        self.assertEqual(self.downs(), [])
        self.assert_nothing_deleted()

    def test_not_enough_space_changes_nothing(self):
        self.set_env({"DISK_SPACE_FREE_KB": "9000"})  # 4 x 2048 KiB, plus 10%, is 9011
        status, _, err = self.destroy("kz", "delete")
        self.assertEqual(status, 1)
        self.assertIn("not enough disk space for the archive", err)
        self.assertIn("Nothing was changed", err)
        self.assertEqual(self.downs(), [])
        self.assertEqual(self.backups(), [])
        self.assert_nothing_deleted()

    def test_a_volume_that_cannot_be_measured_changes_nothing(self):
        self.docker.fail[("run", "--rm", "--mount", "type=volume,source=kz_logs,target=/v,readonly",
                          "alpine:3.21", "du")] = done(returncode=1)
        status, _, err = self.destroy("kz", "delete")
        self.assertEqual(status, 1)
        self.assertIn("couldn't measure the volume kz_logs, so nothing was changed", err)
        self.assertEqual(self.downs(), [])
        self.assert_nothing_deleted()

    def test_a_failed_volume_listing_changes_nothing(self):
        self.docker.fail[("volume", "ls")] = done(returncode=1)
        status, _, err = self.destroy("kz", "delete")
        self.assertEqual(status, 1)
        self.assertIn("couldn't list Docker's volumes", err)
        self.assertEqual(self.downs(), [])
        self.assert_nothing_deleted()

    def test_a_failed_archive_deletes_nothing_and_removes_the_incomplete_backup(self):
        self.docker.fail[("run", "--rm", "--mount", "type=volume,source=kz_logs,target=/v,readonly",
                          "alpine:3.21", "tar")] = done(returncode=1)
        status, _, err = self.destroy("kz", "delete")
        self.assertEqual(status, 1)
        self.assertIn("couldn't archive the volume kz_logs", err)
        self.assertIn("Nothing was deleted", err)
        self.assertIn("pihx kz start", err)
        self.assertEqual(self.backups(), [])
        self.assert_nothing_deleted()

    def test_an_archive_that_does_not_read_back_deletes_nothing(self):
        self.docker.fail["tar-t"] = 1
        status, _, err = self.destroy("kz", "delete")
        self.assertEqual(status, 1)
        self.assertIn("doesn't read back", err)
        self.assertEqual(self.backups(), [])
        self.assert_nothing_deleted()

    # --- removal ----------------------------------------------------------------------------------

    def test_a_volume_that_is_not_removed_keeps_the_directory(self):
        self.docker.fail[("volume", "rm")] = done(returncode=1)
        status, _, err = self.destroy("kz", "delete")
        self.assertEqual(status, 1)
        self.assertIn("couldn't remove the volume(s) kz_data, kz_gone-svc, kz_logs, kz_old", err)
        self.assertIn("'pihx kz destroy' can be run again", err)
        self.assertTrue((self.home / "kz" / "instance.env").is_file())
        self.assertEqual(len(self.backups()), 1)

    def test_unreadable_compose_files_fall_back_to_the_labels(self):
        self.config_result = done(returncode=1)
        self.down_result = done(returncode=1)
        status, _, err = self.destroy("kz", "delete")
        self.assertEqual(status, 0, err)
        self.assertIn("found by their labels only", err)
        self.assertIn(["rm", "-f", "c1"], self.docker.calls)
        # The model's adopted volume (no label) can't be found then: kept.
        self.assertEqual(self.removed(), [["volume", "rm", "kz_gone-svc", "kz_logs", "kz_old"]])
        self.assertIn("kz_data", self.docker.volumes)

    def test_a_failed_container_listing_in_the_fallback_deletes_nothing(self):
        self.down_result = done(returncode=1)
        self.docker.fail[("ps",)] = done(returncode=1)
        status, _, err = self.destroy("kz", "delete")
        self.assertEqual(status, 1)
        self.assertIn("nothing was deleted", err)
        self.assertEqual(self.backups(), [])
        self.assert_nothing_deleted()

    def test_a_tools_directory_is_kept(self):
        (self.home / "kz" / "tools").unlink()
        (self.home / "kz" / "tools").mkdir()
        status, _, err = self.destroy("kz", "delete")
        self.assertEqual(status, 0, err)
        self.assertEqual([p.name for p in (self.home / "kz").iterdir()], ["tools"])
        [backup] = self.backups()
        self.assertIn("ln -s <tools directory>", (backup / "RESTORE.txt").read_text())

    def test_a_symlinked_instance_directory_is_only_unlinked(self):
        real = self.root / "real"
        (self.home / "kz").rename(real)
        (self.home / "kz").symlink_to(real)
        status, _, err = self.destroy("kz", "delete")
        self.assertEqual(status, 0, err)
        self.assertFalse((self.home / "kz").is_symlink())
        self.assertTrue((real / "db.env").is_file())

    def test_root_owned_files_are_reclaimed_without_touching_a_kept_tools_directory(self):
        (self.home / "kz" / "tools").unlink()
        (self.home / "kz" / "tools").mkdir()
        (self.home / "kz" / "out").mkdir()
        original = destroy.shutil.rmtree
        calls = []

        def rmtree(path, *a, **k):
            if not calls and path.name == "out":
                calls.append(path)
                raise PermissionError("root-owned")
            return original(path, *a, **k)
        with mock.patch.object(destroy.shutil, "rmtree", rmtree):
            status, _, err = self.destroy("kz", "delete")
        self.assertEqual(status, 0, err)
        chown = next(c for c in self.docker.calls if c[:1] == ["run"] and "chown" in c)
        self.assertIn("find", chown)
        self.assertIn("tools", chown)
        self.assertEqual(chown[chown.index("alpine:3.21") + 1:][:2], ["find", "/target"])
        self.assertEqual([p.name for p in (self.home / "kz").iterdir()], ["tools"])

    def test_a_removal_that_still_fails_names_the_backup(self):
        (self.home / "kz" / "out").mkdir()
        original = destroy.shutil.rmtree

        def rmtree(path, *a, **k):
            if path.name == "out":
                raise PermissionError("denied")
            return original(path, *a, **k)
        with mock.patch.object(destroy.shutil, "rmtree", rmtree):
            status, _, err = self.destroy("kz", "delete")
        self.assertEqual(status, 1)
        self.assertIn("error: couldn't remove", err)
        self.assertIn("the archive is in", err)
