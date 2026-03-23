#!/usr/bin/env python3
"""Generate a Markdown checklist report from Goss JSON + pytest JUnit XML."""

import json
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

RESULTS_DIR = Path(__file__).parent.parent / "results"
REPORT_PATH = RESULTS_DIR / "report.md"


def parse_goss_json(path: Path) -> dict:
    """Parse Goss JSON output into a summary."""
    if not path.exists():
        return {"host": path.stem, "total": 0, "passed": 0, "failed": 0, "tests": []}

    data = json.loads(path.read_text())
    results = data.get("results", [])
    passed = sum(1 for r in results if r.get("successful"))
    failed = sum(1 for r in results if not r.get("successful"))

    tests = []
    for r in results:
        status = "x" if r.get("successful") else " "
        tests.append(f"- [{status}] {r.get('resource-type', '?')}: {r.get('resource-id', '?')}")

    return {
        "host": path.stem.replace("goss-", ""),
        "total": len(results),
        "passed": passed,
        "failed": failed,
        "tests": tests,
    }


def parse_junit_xml(path: Path) -> dict:
    """Parse pytest JUnit XML into a summary."""
    if not path.exists():
        return {"total": 0, "passed": 0, "failed": 0, "skipped": 0, "tests": []}

    tree = ET.parse(path)
    root = tree.getroot()

    tests = []
    total = passed = failed = skipped = 0

    for suite in root.iter("testsuite"):
        for tc in suite.iter("testcase"):
            total += 1
            name = f"{tc.get('classname', '')}.{tc.get('name', '')}"
            name = name.replace("tests.", "").replace("test_", "")

            if tc.find("failure") is not None:
                failed += 1
                tests.append(f"- [ ] {name}")
            elif tc.find("skipped") is not None:
                skipped += 1
                tests.append(f"- [~] {name} (skipped)")
            else:
                passed += 1
                tests.append(f"- [x] {name}")

    return {"total": total, "passed": passed, "failed": failed, "skipped": skipped, "tests": tests}


def generate_report():
    """Generate the combined Markdown report."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    lines = [
        "# IRL Infrastructure Validation Report",
        f"Generated: {now}",
        "",
    ]

    # Goss results
    goss_total = goss_passed = 0
    goss_files = sorted(RESULTS_DIR.glob("goss-*.json"))

    if goss_files:
        lines.append("## Node Validation (Goss)")
        lines.append("")
        for gf in goss_files:
            result = parse_goss_json(gf)
            goss_total += result["total"]
            goss_passed += result["passed"]
            status = "PASS" if result["failed"] == 0 else "FAIL"
            lines.append(f"### {result['host']} -- {result['passed']}/{result['total']} passed ({status})")
            lines.extend(result["tests"])
            lines.append("")

    # pytest results
    pytest_path = RESULTS_DIR / "pytest.xml"
    pytest_result = parse_junit_xml(pytest_path)

    if pytest_result["total"] > 0:
        lines.append("## Service Tests (pytest)")
        lines.append(f"### {pytest_result['passed']}/{pytest_result['total']} passed")
        lines.extend(pytest_result["tests"])
        lines.append("")

    # Summary
    total = goss_total + pytest_result["total"]
    passed = goss_passed + pytest_result["passed"]
    failed = (goss_total - goss_passed) + pytest_result["failed"]
    status_emoji = "PASS" if failed == 0 else "FAIL"

    lines.append("---")
    lines.append(f"## Summary: {passed}/{total} passed ({status_emoji})")
    if pytest_result["skipped"] > 0:
        lines.append(f"Skipped: {pytest_result['skipped']}")
    lines.append("")

    report = "\n".join(lines)
    REPORT_PATH.write_text(report)
    print(report)


if __name__ == "__main__":
    generate_report()
