import json
import os
import stat
import tempfile
import unittest

from pihx import runtime


class InstallDockerConfigTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.source = os.path.join(tmp.name, "config.json")
        self.home = os.path.join(tmp.name, "home")

    def write_source(self, text):
        with open(self.source, "w") as f:
            f.write(text)

    def test_credential_helpers_are_removed_and_auths_kept(self):
        self.write_source(json.dumps({
            "auths": {"ghcr.io": {"auth": "ZmFrZTpmYWtl"}},
            "credsStore": "desktop",
            "credHelpers": {"gcr.io": "gcloud"},
        }))
        runtime.install_docker_config(self.source, self.home)
        target = os.path.join(self.home, ".docker", "config.json")
        with open(target) as f:
            config = json.load(f)
        self.assertEqual(config, {"auths": {"ghcr.io": {"auth": "ZmFrZTpmYWtl"}}})
        self.assertEqual(stat.S_IMODE(os.stat(target).st_mode), 0o600)

    def test_unreadable_config_is_an_error_without_its_contents(self):
        self.write_source('{"auths": {"ghcr.io": {"auth": "c2VjcmV0"}}, oops')
        with self.assertRaises(runtime.SetupError) as raised:
            runtime.install_docker_config(self.source, self.home)
        self.assertNotIn("c2VjcmV0", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
