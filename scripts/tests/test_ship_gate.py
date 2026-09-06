from __future__ import annotations

import importlib.util
import pathlib
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "ship-gate.py"
SPEC = importlib.util.spec_from_file_location("ship_gate", SCRIPT)
assert SPEC and SPEC.loader
ship_gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ship_gate)


def run_payload(sha: str, **overrides: object) -> dict[str, object]:
    result: dict[str, object] = {
        "databaseId": 123,
        "headSha": sha,
        "status": "completed",
        "conclusion": "success",
        "createdAt": "2026-09-06T12:00:00Z",
    }
    result.update(overrides)
    return result


class ShipGateTests(unittest.TestCase):
    def test_selects_newest_successful_run_for_exact_sha(self) -> None:
        sha = "a" * 40
        selected = ship_gate.select_exact_run(
            [
                run_payload(sha, databaseId=1, createdAt="2026-09-05T12:00:00Z"),
                run_payload(sha, databaseId=2, createdAt="2026-09-06T12:00:00Z"),
                run_payload("b" * 40, databaseId=3),
            ],
            sha,
        )
        self.assertEqual(selected["databaseId"], 2)

    def test_latest_exact_run_failure_blocks_even_with_older_success(self) -> None:
        sha = "a" * 40
        with self.assertRaisesRegex(ValueError, "not successful"):
            ship_gate.select_exact_run(
                [
                    run_payload(sha, databaseId=1, createdAt="2026-09-05T12:00:00Z"),
                    run_payload(sha, databaseId=2, conclusion="failure"),
                ],
                sha,
            )

    def test_platform_aggregates_require_all_four_successes(self) -> None:
        jobs = [
            {"name": f"Full suite ({platform})", "status": "completed", "conclusion": "success"}
            for platform in ship_gate.PLATFORMS
        ]
        ship_gate.verify_platform_jobs(jobs)
        jobs[-1]["conclusion"] = "skipped"
        with self.assertRaisesRegex(ValueError, "did not succeed"):
            ship_gate.verify_platform_jobs(jobs)

    def test_queued_platform_job_blocks(self) -> None:
        jobs = [
            {"name": f"Full suite ({platform})", "status": "completed", "conclusion": "success"}
            for platform in ship_gate.PLATFORMS
        ]
        jobs[0]["status"] = "queued"
        with self.assertRaisesRegex(ValueError, "did not succeed"):
            ship_gate.verify_platform_jobs(jobs)

    def test_duplicate_platform_job_blocks(self) -> None:
        jobs = [
            {"name": f"Full suite ({platform})", "status": "completed", "conclusion": "success"}
            for platform in ship_gate.PLATFORMS
        ]
        with self.assertRaisesRegex(ValueError, "duplicate"):
            ship_gate.verify_platform_jobs(jobs + [jobs[0].copy()])

    def test_malformed_run_created_at_blocks(self) -> None:
        with self.assertRaisesRegex(ValueError, "createdAt"):
            ship_gate.select_exact_run([run_payload("a" * 40, createdAt=None)], "a" * 40)

    def test_platform_aggregates_reject_missing_job(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing"):
            ship_gate.verify_platform_jobs([])


if __name__ == "__main__":
    unittest.main()
