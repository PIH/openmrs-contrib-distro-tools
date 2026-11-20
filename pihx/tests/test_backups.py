"""backup, upload-backups, list-backups and copy-backup, with Docker and Compose faked; and what
the core tells the backups service (the backup plan)."""

import os
import subprocess
from unittest import mock

from pihx import compose, instance, lock, services
from pihx.commands import archive, backups
from pihx.tests.fixtures import add_service, write
from pihx.tests.test_instance_cmds import CommandTest, run
from pihx.tests.test_lifecycle import done

LISTING = """\
kz_20261101T013000Z\t2048\tyes
kz_20261102T013000Z.failed\t4\tno
kz_20261103T013000Z\t3072\tno
kz_20261104T013000Z.partial\t100\tno
lost+found\t4\tno
---
{"backup": {"last_attempt": "2026-11-04T01:30:00Z", "last_result": "failed",
            "last_error": "openmrs failed (exit 2)", "last_success": "2026-11-03T01:31:00Z",
            "not_backed_up": ["biometrics"]},
 "upload": {"last_attempt": "2026-11-04T02:15:00Z", "last_result": "success",
            "last_success": "2026-11-04T02:15:00Z", "last_error": "", "pending_runs": 1,
            "pending_bytes": 3145728}}
"""


class BackupsTest(CommandTest):
    def setUp(self):
        super().setUp()
        add_service(self.tools, "backups", "description: Backups\nbackup: none\n",
                    "BACKUP_UPLOAD=\nBACKUP_ARCHIVE_PASSWORD=x\n")
        write(self.tools / "utils" / "lib" / "images.sh", "ALPINE_IMAGE=alpine:3.21\n")
        for f, text in [("instance.env", "TZ=UTC\n"), ("db.env", ""), ("app.env", ""),
                        ("backups.env", "")]:
            write(self.home / "kz" / f, text)
        self.docker_calls = []
        self.volumes = "kz_backups\nkz_data\n"
        self.listing = LISTING
        self.copy_result = done()
        self.running = "c1\n"
        self.exec_status = 0

    def fake_docker(self, argv, **kwargs):
        args = argv[1:]
        self.docker_calls.append(args)
        if args[:3] == ["volume", "ls", "-q"]:
            return done(self.volumes)
        if args[:1] == ["run"] and "cp -R" in " ".join(args):
            return self.copy_result
        if args[:1] == ["run"]:
            return done(self.listing)
        return done()

    def pihx(self, *argv):
        def fake_run(compose_self, *args, **kwargs):
            self.compose_calls.append(args)
            if args[:2] == ("ps", "-q"):
                return done(self.running)
            if args[:1] == ("exec",):
                # The lock is held while the job runs.
                self.holder = lock.holder(instance.open(self.home, "kz", tools=self.tools))
                return done(returncode=self.exec_status)
            return done()
        with mock.patch.object(compose.Compose, "run", fake_run), \
                mock.patch.object(archive.subprocess, "run", self.fake_docker):
            return run(["kz", *argv])

    def without_backups_service(self):
        (self.home / "kz" / "backups.env").unlink()

    # --- backup, upload-backups -------------------------------------------------------------------

    def test_backup_runs_the_job_in_the_running_container_holding_the_lock(self):
        status, _, err = self.pihx("backup")
        self.assertEqual(status, 0, err)
        self.assertIn(("ps", "-q", "--status", "running", "backups"), self.compose_calls)
        self.assertIn(("exec", "-T", "backups", "bash", "/opt/backup/backup.sh"), self.compose_calls)
        self.assertIn("backup", self.holder)

    def test_backup_exits_with_the_job_s_status(self):
        self.exec_status = 1
        status, _, _ = self.pihx("backup")
        self.assertEqual(status, 1)

    def test_backup_needs_the_container_running(self):
        self.running = ""
        status, _, err = self.pihx("backup")
        self.assertEqual(status, 1)
        self.assertIn("backups container isn't running: start kz first", err)
        self.assertFalse([c for c in self.compose_calls if c[:1] == ("exec",)])

    def test_backup_and_upload_need_the_backups_service(self):
        self.without_backups_service()
        for command in ("backup", "upload-backups"):
            with self.subTest(command=command):
                status, _, err = self.pihx(command)
                self.assertEqual(status, 1)
                self.assertIn("kz doesn't have the backups service", err)
        self.assertEqual(self.compose_calls, [])

    def test_upload_without_a_url_says_so_and_does_nothing(self):
        status, out, err = self.pihx("upload-backups")
        self.assertEqual(status, 0, err)
        self.assertIn("Uploads aren't configured for kz", out)
        self.assertEqual(self.compose_calls, [])

    def test_upload_runs_the_upload_job(self):
        write(self.home / "kz" / "backups.env", "BACKUP_UPLOAD=azure\n")
        status, _, err = self.pihx("upload-backups")
        self.assertEqual(status, 0, err)
        self.assertIn(("exec", "-T", "backups", "bash", "/opt/backup/upload.sh"), self.compose_calls)

    def test_upload_goes_by_the_files_the_container_reads_not_instance_env(self):
        # instance.env wins in the merged config, but the backups container never reads it.
        write(self.home / "kz" / "instance.env", "TZ=UTC\nBACKUP_UPLOAD=azure\n")
        status, out, err = self.pihx("upload-backups")
        self.assertEqual(status, 0, err)
        self.assertIn("Uploads aren't configured for kz", out)
        self.assertEqual(self.compose_calls, [])

    def test_options_are_refused(self):
        for command in ("backup", "upload-backups", "list-backups"):
            with self.subTest(command=command):
                status, _, err = self.pihx(command, "--now")
                self.assertEqual(status, 2)
                self.assertIn(f"unknown option '--now' for {command}", err)

    # --- list-backups -----------------------------------------------------------------------------

    def test_list_shows_the_runs_and_the_jobs_status(self):
        status, out, err = self.pihx("list-backups")
        self.assertEqual(status, 0, err)
        lines = out.splitlines()
        self.assertRegex(lines[0], r"^RUN\s+STATE\s+SIZE\s+UPLOADED$")
        self.assertRegex(lines[1], r"^kz_20261101T013000Z\s+complete\s+2\.0M\s+yes$")
        self.assertRegex(lines[2], r"^kz_20261102T013000Z\.failed\s+failed\s+4K\s+-$")
        self.assertRegex(lines[3], r"^kz_20261103T013000Z\s+complete\s+3\.0M\s+no$")
        self.assertRegex(lines[4], r"^kz_20261104T013000Z\.partial\s+partial\s+100K\s+-$")
        # Not a run: left out.
        self.assertNotIn("lost+found", out)
        self.assertIn("Backup: last failed at 2026-11-04T01:30:00Z; last success at "
                      "2026-11-03T01:31:00Z\n  error: openmrs failed (exit 2)", out)
        self.assertIn("Upload: last success at 2026-11-04T02:15:00Z", out)
        self.assertIn("waiting to upload: 1 run(s), 3.0M", out)
        self.assertIn("Not backed up: biometrics", out)
        # The volume read-only, in a throwaway container.
        [listing] = [c for c in self.docker_calls if c[:1] == ["run"]]
        self.assertIn("type=volume,source=kz_backups,target=/b,readonly", listing)
        self.assertIn("--rm", listing)

    def test_list_works_without_the_service_and_with_no_runs(self):
        self.without_backups_service()
        self.listing = "---\n"
        status, out, err = self.pihx("list-backups")
        self.assertEqual(status, 0, err)
        self.assertIn("No runs yet.", out)
        self.assertIn("Backup: never run", out)

    def test_list_without_the_volume_is_an_error(self):
        self.volumes = "kz_data\n"
        status, _, err = self.pihx("list-backups")
        self.assertEqual(status, 1)
        self.assertIn("kz has no backups volume (kz_backups)", err)

    # --- copy-backup ------------------------------------------------------------------------------

    def copy(self, *args, to="out"):
        dest = self.root / to
        dest.mkdir(exist_ok=True)
        self.set_env({"PIHX_TO": str(dest), "DISK_SPACE_FREE_KB": "100000000"})
        return self.pihx("copy-backup", *args, f"--to={to}"), dest

    def test_copy_copies_a_complete_run_as_the_caller(self):
        (status, out, err), dest = self.copy("kz_20261101T013000Z")
        self.assertEqual(status, 0, err)
        [copy] = [c for c in self.docker_calls if c[:1] == ["run"] and "cp -R" in " ".join(c)]
        self.assertIn("type=volume,source=kz_backups,target=/b,readonly", copy)
        self.assertIn(f'type=bind,"source={dest}",target=/to', copy)
        self.assertEqual(copy[-2:], ["kz_20261101T013000Z", f"{os.getuid()}:"
                                                            f"{os.getgid()}"])
        self.assertIn(f"initialize --from {dest}", out)

    def test_copy_latest_is_the_newest_complete_run(self):
        (status, _, err), _ = self.copy("latest")
        self.assertEqual(status, 0, err)
        [copy] = [c for c in self.docker_calls if c[:1] == ["run"] and "cp -R" in " ".join(c)]
        self.assertEqual(copy[-2], "kz_20261103T013000Z")

    def test_copy_latest_goes_by_the_timestamp_whatever_the_prefix(self):
        # An earlier BACKUP_PREFIX sorts after kz_ by name, but its run is older.
        self.listing = ("zl-test_20250101T013000Z\t1024\tyes\nkz_20261101T013000Z\t2048\tno\n"
                        "kz_20261103T013000Z.failed\t4\tno\n---\n")
        (status, _, err), _ = self.copy("latest")
        self.assertEqual(status, 0, err)
        [copy] = [c for c in self.docker_calls if c[:1] == ["run"] and "cp -R" in " ".join(c)]
        self.assertEqual(copy[-2], "kz_20261101T013000Z")

    def test_copy_without_room_says_what_it_copies(self):
        dest = self.root / "out"
        dest.mkdir()
        self.set_env({"PIHX_TO": str(dest), "DISK_SPACE_FREE_KB": "10"})
        status, _, err = self.pihx("copy-backup", "latest", "--to=out")
        self.assertEqual(status, 1)
        self.assertIn("not enough disk space for kz_20261103T013000Z: it holds 3.0M", err)
        self.assertNotIn("volumes", err)

    def test_copy_script_fails_and_empties_the_destination_when_the_copy_fails(self):
        src, dst = self.root / "b", self.root / "to"
        write(src / "kz_1" / "a.7z", "x")
        dst.mkdir()
        script = backups._COPY_SCRIPT.replace("/b/", f"{src}/").replace("/to", str(dst))
        # chown to an owner that doesn't exist fails after cp has copied.
        result = subprocess.run(["sh", "-c", script, "sh", "kz_1", "no-such-user:x"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(dst.iterdir()), [])
        result = subprocess.run(["sh", "-c", script, "sh", "kz_1", f"{os.getuid()}:{os.getgid()}"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([p.name for p in dst.iterdir()], ["a.7z"])

    def test_copy_refuses_a_run_that_is_not_complete_or_not_there(self):
        for run_name, message in [("kz_20261102T013000Z.failed", "is failed, not a complete backup"),
                                  ("kz_20261104T013000Z.partial", "is partial"),
                                  ("kz_20990101T000000Z", "no run 'kz_20990101T000000Z'")]:
            with self.subTest(run=run_name):
                (status, _, err), _ = self.copy(run_name)
                self.assertEqual(status, 1)
                self.assertIn(message, err)
        self.assertFalse([c for c in self.docker_calls if "cp -R" in " ".join(c)])

    def test_copy_needs_a_run_and_to(self):
        for args in ([], ["kz_20261101T013000Z"], ["--to=out"], ["a", "b", "--to=out"]):
            with self.subTest(args=args):
                status, _, err = self.pihx("copy-backup", *args)
                self.assertEqual(status, 2)
                self.assertIn("usage: pihx kz copy-backup", err)

    def test_copy_into_a_directory_that_is_not_empty_is_refused(self):
        dest = self.root / "out"
        write(dest / "x", "")
        (status, _, err), _ = self.copy("latest")
        self.assertEqual(status, 1)
        self.assertIn("isn't empty", err)

    def test_a_failed_copy_is_an_error(self):
        self.copy_result = subprocess.CompletedProcess([], 1, stdout="", stderr="cp: no space")
        (status, _, err), _ = self.copy("latest")
        self.assertEqual(status, 1)
        self.assertIn("couldn't copy kz_20261103T013000Z", err)
        self.assertIn("cp: no space", err)


class BackupPlanTest(CommandTest):
    def test_each_service_s_kind_by_name_after_what_it_requires(self):
        add_service(self.tools, "cache", "description: c\nbackup: scripts/backup.sh\n",
                    files=["scripts/backup.sh"])
        found = services.all(self.tools)
        self.assertEqual(services.backup_plan(found.values()), "db=none app=unset cache=script")

    def test_a_backup_script_must_exist_inside_the_service(self):
        for manifest, message in [("backup: scripts/nosuch.sh", "scripts/nosuch.sh doesn't exist"),
                                  ("backup: ../db/x.sh", "inside the service directory"),
                                  ("backup: /bin/sh", "inside the service directory"),
                                  ("backup: ''", "'backup' must be"),
                                  ("backup: [a]", "'backup' must be")]:
            with self.subTest(manifest=manifest):
                add_service(self.tools, "x", f"description: x\n{manifest}\n")
                with self.assertRaises(services.ServiceError) as raised:
                    services.load(self.tools, "x")
                self.assertIn(message, str(raised.exception))
