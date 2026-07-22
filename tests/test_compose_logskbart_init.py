import json
import subprocess
import unittest
from pathlib import Path


REPO_DIR = Path(__file__).resolve().parents[1]


def render_compose(*, profile: str | None = None) -> dict:
    command = [
        "docker",
        "compose",
        "--env-file",
        ".env-dist",
        "--env-file",
        "tests/compose.env",
    ]
    if profile:
        command.extend(["--profile", profile])
    command.extend(["config", "--format", "json"])

    completed = subprocess.run(
        command,
        cwd=REPO_DIR,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


class LogskbartInitComposeTest(unittest.TestCase):
    def test_init_service_is_excluded_by_default(self) -> None:
        model = render_compose()
        self.assertNotIn("logskbart-init", model["services"])

    def test_init_profile_has_ephemeral_service_contract(self) -> None:
        model = render_compose(profile="init")
        service = model["services"]["logskbart-init"]

        self.assertEqual(["init"], service["profiles"])
        self.assertNotIn("container_name", service)
        self.assertEqual(
            "service_healthy",
            service["depends_on"]["logskbart-elasticsearch"]["condition"],
        )
        self.assertEqual(
            ["/bin/sh", "/logskbart-init/init.sh"],
            service["entrypoint"],
        )

        init_volume = next(
            volume
            for volume in service["volumes"]
            if volume["target"] == "/logskbart-init"
        )
        self.assertTrue(init_volume["read_only"])


if __name__ == "__main__":
    unittest.main()
