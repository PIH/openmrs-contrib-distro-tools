"""The services in this checkout (services/): every one loads, and they follow the conventions the
core and the other services rely on.

The container env convention: a service's containers get only its own env.defaults and its
<svc>.env (and what its compose file passes under `environment:`). instance.env holds
instance-wide values such as TZ, which a compose file passes explicitly. Another service's values
reach a container only through `environment:` or a with-file: services/<a>/with-<b>.yaml is added
to the compose files only when the instance has both a and b (after every service's compose.yaml,
before the instance's override files), so a service names another's variables in its own with-file,
never in the other service's files. env.defaults holds literal defaults, no references to other
variables."""

import re
import unittest
from pathlib import Path

import yaml

from pihx import envfile, services

TOOLS = Path(__file__).resolve().parents[2]
SERVICES = services.all(TOOLS)
PLAIN_LINE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=[^\n]*")
# (A `$$` is a literal $, for the shell in the container.)
VARIABLE = re.compile(r"(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)([^}]*)\}")
# What pihx sets for Compose, and instance.env.defaults gives every instance.
PROVIDED = {"SERVICE_NAME", "PIHX_TOOLS", "PIHX_INSTANCE_DIR", "PIHX_INSTANCE", "TZ"}


def compose(svc):
    return yaml.safe_load(svc.compose_file.read_text())


def containers(svc):
    return compose(svc)["services"].items()


def closure(name):
    """<name> and the services it requires, recursively."""
    found = []
    for n in [name] + SERVICES[name].manifest.requires:
        for c in (closure(n) if n != name else [name]):
            if c not in found:
                found.append(c)
    return found


class ServiceTreeTest(unittest.TestCase):
    def test_every_service_loads(self):
        self.assertEqual(
            set(SERVICES),
            {"openmrs-db", "openmrs", "openmrs-smoke-tests", "openhim", "openhim-advapacs-mediator",
             "advapacs-gateway", "modality-simulator", "biometrics", "sqlserver", "petl"})

    def test_manifests_follow_the_old_directives(self):
        self.assertEqual(SERVICES["openmrs-db"].manifest.setup, ["openmrs-db-accounts"])
        self.assertEqual(SERVICES["openmrs-db"].manifest.capture_env, ["OPENMRS_DB_OPT_"])
        self.assertEqual(SERVICES["openmrs"].manifest.capture_env, ["OMRS_EXTRA_"])
        self.assertEqual(SERVICES["openmrs"].manifest.requires, ["openmrs-db"])
        self.assertEqual(SERVICES["sqlserver"].manifest.setup, ["sqlserver-setup"])
        self.assertTrue(SERVICES["petl"].manifest.job)
        self.assertEqual([n for n, s in SERVICES.items() if s.manifest.job], ["petl"])

    def test_setup_names_are_containers_of_the_service(self):
        for name, svc in SERVICES.items():
            for setup in svc.manifest.setup:
                self.assertIn(setup, compose(svc)["services"], f"{name}: setup {setup}")

    def test_env_defaults_are_plain_key_value_lines(self):
        for name, svc in SERVICES.items():
            for number, line in enumerate((svc.dir / "env.defaults").read_text().splitlines(), 1):
                if line.strip() and not line.startswith("#"):
                    self.assertRegex(line, PLAIN_LINE, f"{name}/env.defaults:{number}")
                    value = line.split("=", 1)[1]
                    # literal only: a single-quoted `${...}` is for the application (e.g. PETL's
                    # ${user.timezone}), anything else would be a reference Compose expands
                    if not (value.startswith("'") and value.endswith("'")):
                        self.assertNotIn("$", value, f"{name}/env.defaults:{number}: a reference "
                                         "to another variable (defaults are literals)")
                    self.assertNotRegex(line, r"=\s*[\"']?\$\{[A-Za-z_]+:?[-?]",
                                        f"{name}/env.defaults:{number}: a ${{VAR:-default}} wrapper")

    def test_no_variable_is_defined_by_two_services(self):
        owner = {}
        for name, svc in SERVICES.items():
            for var in svc.defaults:
                self.assertNotIn(var, owner, f"{var} is defined by {owner.get(var)} and {name}")
                owner[var] = name
        instance_defaults = envfile.parse((TOOLS / "instance.env.defaults").read_text())
        self.assertEqual(list(instance_defaults), ["TZ"])
        self.assertFalse(set(instance_defaults) & set(owner))

    def test_each_container_has_its_service_defaults_and_instance_file(self):
        for name, svc in SERVICES.items():
            expected = [
                {"path": f"${{PIHX_TOOLS}}/services/{name}/env.defaults"},
                {"path": f"${{PIHX_INSTANCE_DIR}}/{name}.env", "required": False}]
            for container, spec in containers(svc):
                self.assertEqual(spec.get("env_file"), expected, f"{name}: {container}")

    def test_no_relative_paths(self):
        for name, svc in SERVICES.items():
            for container, spec in containers(svc):
                for volume in spec.get("volumes", []):
                    source = volume.split(":")[0] if isinstance(volume, str) else volume.get("source", "")
                    self.assertFalse(source.startswith((".", "~")),
                                     f"{name}: {container}: relative volume {volume} (Compose "
                                     "resolves it against the instance directory)")
                self.assertNotIn("build", spec, f"{name}: {container}")
                for entry in spec.get("env_file", []):
                    path = entry["path"] if isinstance(entry, dict) else entry
                    self.assertTrue(path.startswith(("${PIHX_TOOLS}/", "${PIHX_INSTANCE_DIR}/")),
                                    f"{name}: {container}: env_file {path}")

    def test_every_variable_has_a_default_or_says_what_happens_when_unset(self):
        """${VAR} alone is for variables the service's own defaults, those of a service it
        requires, instance.env.defaults or pihx give; the others use :- or :? (Compose blanks a
        bare unset one with only a warning)."""
        for name, svc in SERVICES.items():
            known = set(PROVIDED)
            for n in closure(name):
                known |= set(SERVICES[n].defaults)
            # (A bare reference is fine once the file requires the variable elsewhere.)
            known |= set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*):\?", svc.compose_file.read_text()))
            files = [svc.compose_file, *svc.with_files.values()]
            lines = [(f, n, line) for f in files for n, line in enumerate(f.read_text().splitlines(), 1)]
            for file, number, line in lines:
                if line.lstrip().startswith("#"):
                    continue
                for var, rest in VARIABLE.findall(line):
                    if not rest:
                        self.assertIn(var, known, f"{file.name}:{number}: bare ${{{var}}} "
                                      "with no default in this service or one it requires")
                    else:
                        self.assertRegex(rest, r"^:[-?]", f"{file.name}:{number}: ${{{var}}}")

    def test_variables_without_a_default_keep_a_guard(self):
        """A value the instance must set stays out of env.defaults and is required (:?) in
        compose.yaml, so a missing one fails `docker compose config` with a message."""
        for name, svc in SERVICES.items():
            guarded = set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*):\?", svc.compose_file.read_text()))
            self.assertFalse(guarded & set(svc.defaults), f"{name}: guarded and defaulted: "
                             f"{sorted(guarded & set(svc.defaults))}")
        self.assertEqual(
            {n: sorted(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*):\?", s.compose_file.read_text()))
             for n, s in SERVICES.items()} | {"x": []},
            {"openmrs-db": [], "openmrs": ["OPENMRS_IMAGE_NAME"], "openmrs-smoke-tests": [],
             "openhim": [], "openhim-advapacs-mediator": [],
             "advapacs-gateway": ["ADVAPACS_GATEWAY_ACCESS_KEY_ID", "ADVAPACS_GATEWAY_ACCESS_KEY_SECRET",
                                  "ADVAPACS_GATEWAY_REGION"],
             "modality-simulator": ["MODALITY_SIMULATOR_GATEWAY_AE"],
             "biometrics": ["BIOMETRICS_LICENSE_BASE64"],
             "sqlserver": ["SQLSERVER_SA_PASSWORD"], "petl": ["PETL_MYSQL_PASSWORD"], "x": []})

    def test_a_service_does_not_name_another_services_variables_outside_a_with_file(self):
        for name in ("openmrs-db", "sqlserver"):
            for f in (SERVICES[name].dir / "compose.yaml", SERVICES[name].dir / "env.defaults"):
                self.assertNotIn("PETL", f.read_text(), f"{f}: PETL belongs in petl/with-{name}.yaml")
        self.assertEqual(sorted(SERVICES["petl"].with_files), ["openmrs-db", "sqlserver"])

    def test_with_files_name_services_that_exist_and_add_only_to_their_services(self):
        for name, svc in SERVICES.items():
            for other, f in svc.with_files.items():
                self.assertIn(other, SERVICES, f)
                added = yaml.safe_load(f.read_text())["services"]
                for container in added:
                    self.assertIn(container, compose(SERVICES[other])["services"], f"{f}: {container}")

    def test_openmrs_waits_for_health_and_fails_on_unhealthy(self):
        labels = compose(SERVICES["openmrs"])["services"]["openmrs"]["labels"]
        self.assertEqual(labels["pihx.wait"], "fail-on-unhealthy")

    def test_container_names_are_the_instance_name_and_the_service(self):
        for name, svc in SERVICES.items():
            for container, spec in containers(svc):
                if container != "openmrs-smoke-tests":   # never had one: it's run, not kept
                    self.assertEqual(spec.get("container_name"), f"${{SERVICE_NAME}}-{container}",
                                     f"{name}: {container}")

    def test_scripts_the_compose_files_mount_exist(self):
        for name, svc in SERVICES.items():
            text = svc.compose_file.read_text()
            for mounted in re.findall(r"\$\{PIHX_TOOLS\}/(services/[^:\s]+):", text):
                self.assertTrue((TOOLS / mounted).is_file(), f"{name}: {mounted} doesn't exist")
                self.assertTrue(mounted.startswith(f"services/{name}/scripts/"), f"{name}: {mounted}")

    def test_restore_entries_are_named_after_their_service(self):
        restore = {name: [(r.names, r.overlay, r.after) for r in svc.manifest.restore]
                   for name, svc in SERVICES.items() if svc.manifest.restore}
        self.assertEqual(restore, {
            "openmrs-db": [
                (["openmrs-db.sql", "openmrs-db.sql.gz"], "restore/dump.yaml", None),
                (["openmrs-db.sql.7z", "openmrs-db.sql.zip"], "restore/dump-archive.yaml", None),
                (["openmrs-db.percona/", "openmrs-db.percona.7z", "openmrs-db.percona.zip",
                  "openmrs-db.percona.tar.gz", "openmrs-db.percona.tgz", "openmrs-db.percona.tar"],
                 "restore/percona.yaml", "restore/reset-accounts.yaml"),
                (["openmrs-db.datadir/"], "restore/datadir.yaml", "restore/reset-accounts.yaml")],
            "openmrs": [
                (["openmrs.7z", "openmrs.tar.gz", "openmrs.tgz", "openmrs.tar", "openmrs.zip"],
                 "restore/archive.yaml", None),
                (["openmrs/"], "restore/directory.yaml", None)]})
        for name, svc in SERVICES.items():
            for restore in svc.manifest.restore:
                for entry in restore.names:
                    self.assertRegex(entry, rf"^{re.escape(name)}(\.|/|$)", f"{name}: {entry}")

    def test_restore_overlays_name_their_containers_and_mount_what_exists(self):
        for name, svc in SERVICES.items():
            for overlay in svc.restore_overlays():
                data = services.read_overlay(overlay)
                text = overlay.read_text()
                for container, spec in data.get("services", {}).items():
                    if "image" in spec:
                        self.assertEqual(spec.get("container_name"),
                                         f"${{SERVICE_NAME}}-{container}", f"{overlay}: {container}")
                for mounted in re.findall(r"\$\{PIHX_TOOLS\}/([^:\s]+):", text):
                    self.assertTrue((TOOLS / mounted).is_file(), f"{overlay}: {mounted}")
                self.assertNotIn("DISTRO_TOOLS_UTILS_DIR", text, overlay)
                # Its service's own volumes, and the staging volumes it declares.
                declared, used = services.overlay_volumes(data)
                own = set((compose(svc).get("volumes") or {}).keys())
                self.assertLessEqual(used - declared, own, overlay)
                self.assertFalse(declared & own, overlay)

    def test_no_comment_directives_are_left(self):
        for name, svc in SERVICES.items():
            text = (svc.dir / "env.defaults").read_text()
            self.assertNotRegex(text, r"(?m)^# (container-env|setup-services|run-service|capture-env)")


if __name__ == "__main__":
    unittest.main()
