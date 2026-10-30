"""archive, with Docker and Compose faked: only of a stopped instance, every volume, the env copies
and RESTORE.txt, and nothing left behind that looks complete when it fails."""

import stat

from pihx import lock
from pihx.tests.test_destroy import DestroyTest


class ArchiveTest(DestroyTest):
    """DestroyTest's fixture: the instance kz with volumes of its model, of a removed service and
    Compose-made, and other instances' and shared volumes."""

    LISTED = ["kz_data", "kz_gone-svc", "kz_logs", "kz_old"]

    def archive(self, *args):
        return self.destroy(args=args, command="archive")

    def archives(self):
        return sorted(p for p in self.home.iterdir() if ".archive-" in p.name)

    def test_a_running_instance_is_refused(self):
        self.docker.running = ["c1"]
        status, _, err = self.archive()
        self.assertEqual(status, 1)
        self.assertIn("kz is running", err)
        self.assertIn("stop it first: pihx kz stop", err)
        self.assertEqual(self.archives(), [])
        self.assertFalse([c for c in self.docker.calls if c[:1] == ["run"]])
        self.assertEqual(self.downs(), [])

    def test_it_writes_every_volume_the_env_copies_and_restore_txt(self):
        status, out, err = self.archive()
        self.assertEqual(status, 0, err)
        [folder] = self.archives()
        self.assertRegex(folder.name, r"^kz\.archive-\d{8}T\d{6}Z$")
        self.assertEqual(stat.S_IMODE(folder.stat().st_mode), 0o700)
        self.assertEqual(sorted(p.name for p in folder.iterdir()),
                         sorted([f"{v}.tar.gz" for v in self.LISTED]
                                + ["RESTORE.txt", "app.env", "app.override.yaml", "db.env",
                                   "instance.env"]))
        for f in folder.iterdir():
            self.assertEqual(stat.S_IMODE(f.stat().st_mode), 0o600, f.name)
        self.assertIn("taken by 'pihx kz archive'", (folder / "RESTORE.txt").read_text())
        self.assertIn(f"Archived kz to {folder}/", out)
        # Nothing stopped, removed or deleted.
        self.assertEqual(self.downs(), [])
        self.assert_nothing_deleted()

    def test_to_names_an_empty_directory(self):
        to = self.root / "out"
        to.mkdir()
        self.set_env({"PIHX_TO": str(to), "DISK_SPACE_FREE_KB": "100000000"})
        status, out, err = self.archive("--to", "out")
        self.assertEqual(status, 0, err)
        self.assertTrue((to / "RESTORE.txt").is_file())
        self.assertEqual(self.archives(), [])

    def test_to_refuses_a_directory_that_is_not_empty(self):
        to = self.root / "out"
        to.mkdir()
        (to / "keep").write_text("mine")
        self.set_env({"PIHX_TO": str(to), "DISK_SPACE_FREE_KB": "100000000"})
        status, _, err = self.archive("--to=out")
        self.assertEqual(status, 1)
        self.assertIn("isn't empty", err)
        self.assertEqual(sorted(p.name for p in to.iterdir()), ["keep"])

    def test_a_failure_removes_what_it_wrote_and_nothing_else(self):
        to = self.root / "out"
        to.mkdir()
        self.set_env({"PIHX_TO": str(to), "DISK_SPACE_FREE_KB": "100000000"})
        self.docker.fail["tar-t"] = 1
        status, _, err = self.archive("--to=out")
        self.assertEqual(status, 1)
        self.assertIn("doesn't read back", err)
        # The caller's directory stays, empty.
        self.assertEqual(list(to.iterdir()), [])
        self.assert_nothing_deleted()

    def test_a_failure_removes_a_directory_of_its_own(self):
        self.docker.fail[("run", "--rm", "--mount", "type=volume,source=kz_old,target=/v,readonly",
                          "alpine:3.21", "tar")] = self.failed()
        status, _, err = self.archive()
        self.assertEqual(status, 1)
        self.assertIn("couldn't archive the volume kz_old", err)
        self.assertEqual(self.archives(), [])
        self.assert_nothing_deleted()

    def test_not_enough_space_writes_nothing(self):
        self.set_env({"DISK_SPACE_FREE_KB": "9000"})
        status, _, err = self.archive()
        self.assertEqual(status, 1)
        self.assertIn("not enough disk space for the archive", err)
        self.assertEqual(self.archives(), [])
        self.assertFalse([c for c in self.docker.calls if c[:1] == ["run"] and "tar" in c])

    def test_it_holds_the_lock(self):
        with lock.hold(self.inst(), 0, command="start"):
            status, _, err = self.archive()
        self.assertEqual(status, 1)
        self.assertIn("kz is busy", err)
        self.assertEqual(self.archives(), [])

    def test_options_are_checked(self):
        for args in (["--force"], ["--to"], ["--to="], ["x"]):
            with self.subTest(args=args):
                status, _, _ = self.archive(*args)
                self.assertEqual(status, 2)
        self.assertEqual(self.docker.calls, [])



for _name in [n for n in vars(DestroyTest) if n.startswith("test_")]:
    if _name not in vars(ArchiveTest):
        setattr(ArchiveTest, _name, None)
