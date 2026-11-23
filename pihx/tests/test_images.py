"""This repo's images, as an instance runs them: found, pulled, or built when not published yet."""

import json
from unittest import mock

from pihx import compose, images, instance
from pihx.tests.fixtures import TempDirTest, two_service_instance, write
from pihx.tests.test_lifecycle import done

NO_TAG = ('manifest for partnersinhealth/backup-tools:abc123 not found: manifest unknown: '
          'manifest unknown')


def not_published(stderr=NO_TAG):
    """A failed pull, with what docker says when the registry has no such image."""
    result = done(returncode=1)
    result.stderr = stderr
    return result


class EnsureTest(TempDirTest):
    def setUp(self):
        super().setUp()
        self.home, self.tools = two_service_instance(self.root)
        write(self.tools / "images" / "backup-tools" / "Dockerfile", "FROM alpine\n")
        hasher = write(self.tools / "utils" / "hash-directory.sh", "#!/bin/sh\necho abc123\n")
        hasher.chmod(0o755)
        self.results = {}
        self.calls = []

    def ensure(self, compose_text):
        write(self.tools / "services" / "app" / "compose.yaml", compose_text)
        inst = instance.open(self.home, "kz", tools=self.tools)
        model = {"services": {"app": {"image": "partnersinhealth/backup-tools:abc123"}}}

        def fake_docker(argv, **kwargs):
            self.calls.append(argv[1:])
            return self.results.get(argv[1], done())

        def fake_run(compose_self, *args, **kwargs):
            self.calls.append(["compose", *args])
            return done(json.dumps(model))
        with mock.patch.object(compose, "docker", fake_docker), \
                mock.patch.object(compose.Compose, "run", fake_run):
            images.ensure(compose.Compose(inst))

    def test_an_instance_naming_no_image_of_this_repo_is_left_alone(self):
        self.ensure("services:\n  app:\n    image: alpine\n")
        self.assertEqual(self.calls, [])

    def test_an_image_that_is_here_is_used(self):
        self.ensure("services:\n  app:\n    image: ${PIHX_IMAGE_BACKUP_TOOLS:?}\n")
        self.assertEqual([c for c in self.calls if c[0] != "compose"],
                         [["image", "inspect", "partnersinhealth/backup-tools:abc123"]])

    def test_a_published_image_is_pulled(self):
        self.results["image"] = done(returncode=1)
        self.ensure("services:\n  app:\n    image: ${PIHX_IMAGE_BACKUP_TOOLS:?}\n")
        self.assertIn(["pull", "-q", "partnersinhealth/backup-tools:abc123"], self.calls)
        self.assertFalse([c for c in self.calls if c[0] == "build"])

    def test_an_unpublished_image_is_built_from_the_checkout(self):
        self.results["image"] = done(returncode=1)
        self.results["pull"] = not_published()
        self.ensure("services:\n  app:\n    image: ${PIHX_IMAGE_BACKUP_TOOLS:?}\n")
        self.assertIn(["build", "-q", "-t", "partnersinhealth/backup-tools:abc123",
                       str(self.tools / "images" / "backup-tools")], self.calls)

    def test_a_failed_build_is_an_error(self):
        self.results = {"image": done(returncode=1), "pull": not_published(),
                        "build": done(returncode=1)}
        with self.assertRaises(images.ImageError):
            self.ensure("services:\n  app:\n    image: ${PIHX_IMAGE_BACKUP_TOOLS:?}\n")

    def test_an_image_for_other_platforms_is_not_built_here(self):
        write(self.tools / "images" / "backup-tools" / "platforms", "linux/amd64\n")
        self.results = {"image": done(returncode=1), "pull": not_published()}
        with mock.patch.object(images, "host_platform", return_value="linux/arm64"), \
                self.assertRaises(images.ImageError) as raised:
            self.ensure("services:\n  app:\n    image: ${PIHX_IMAGE_BACKUP_TOOLS:?}\n")
        self.assertIn("built for linux/amd64 only, and this host is linux/arm64", str(raised.exception))
        self.assertFalse([c for c in self.calls if c[0] == "build"])

    def test_an_image_for_this_platform_is_built(self):
        write(self.tools / "images" / "backup-tools" / "platforms", "linux/amd64\n")
        self.results = {"image": done(returncode=1), "pull": not_published()}
        with mock.patch.object(images, "host_platform", return_value="linux/amd64"):
            self.ensure("services:\n  app:\n    image: ${PIHX_IMAGE_BACKUP_TOOLS:?}\n")
        self.assertTrue([c for c in self.calls if c[0] == "build"])

    def test_an_image_whose_repository_is_not_published_yet_is_built(self):
        self.results = {"image": done(returncode=1), "pull": not_published(
            "pull access denied for partnersinhealth/backup-tools, repository does not exist or may "
            "require 'docker login': denied: requested access to the resource is denied")}
        self.ensure("services:\n  app:\n    image: ${PIHX_IMAGE_BACKUP_TOOLS:?}\n")
        self.assertTrue([c for c in self.calls if c[0] == "build"])

    def test_a_pull_that_fails_for_another_reason_is_an_error_not_a_build(self):
        self.results = {"image": done(returncode=1), "pull": not_published(
            "Get \"https://registry-1.docker.io/v2/\": net/http: request canceled while waiting "
            "for connection")}
        with self.assertRaises(images.ImageError) as raised:
            self.ensure("services:\n  app:\n    image: ${PIHX_IMAGE_BACKUP_TOOLS:?}\n")
        self.assertIn("couldn't pull partnersinhealth/backup-tools:abc123", str(raised.exception))
        self.assertFalse([c for c in self.calls if c[0] == "build"])


class PlatformsTest(TempDirTest):
    def test_the_platforms_file_is_comma_separated_as_ci_reads_it(self):
        write(self.root / "img" / "platforms", "linux/amd64, linux/arm64,linux/s390x\n")
        self.assertEqual(images.platforms(self.root / "img"),
                         ["linux/amd64", "linux/arm64", "linux/s390x"])
        self.assertIsNone(images.platforms(self.root / "none"))

    def test_the_host_platform_is_docker_s_name_for_it(self):
        for machine, expected in [("x86_64", "linux/amd64"), ("aarch64", "linux/arm64")]:
            with mock.patch.object(images.platform, "machine", return_value=machine):
                self.assertEqual(images.host_platform(), expected)
