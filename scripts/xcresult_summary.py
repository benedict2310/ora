#!/usr/bin/env python3
"""Token-optimized Xcode test summary.

Parses .xcresult bundles and outputs minimal, agent-friendly summaries:
- Success: ✅ Tests: 30/30 passed
- Failure: ❌ Tests: 28/30 passed (2 failed) + failure details

Compatible with Xcode 15+ (tries modern commands first, falls back to legacy).
"""

import json
import subprocess
import sys
from pathlib import Path


def run_cmd(cmd: list[str]) -> str:
    """Run a command and return stdout."""
    return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()


def try_json(cmd: list[str]) -> dict | None:
    """Try to run a command and parse JSON output."""
    try:
        out = run_cmd(cmd)
        return json.loads(out)
    except Exception:
        return None


def deep_find_all(obj, key: str) -> list:
    """Recursively find all values for a given key in nested dicts/lists."""
    found = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key:
                found.append(v)
            found.extend(deep_find_all(v, key))
    elif isinstance(obj, list):
        for item in obj:
            found.extend(deep_find_all(item, key))
    return found


def unwrap(x):
    """Unwrap xcresult JSON primitives (often wrapped as {"_value": ...})."""
    if isinstance(x, dict) and "_value" in x:
        return x["_value"]
    return x


def first_int(values: list, default: int = 0) -> int:
    """Get the first integer from a list of values."""
    for v in values:
        v = unwrap(v)
        if isinstance(v, int):
            return v
        if isinstance(v, str) and v.isdigit():
            return int(v)
    return default


def collect_failures(json_obj: dict) -> list[tuple[str, str, str, str]]:
    """Extract failure details from xcresult JSON."""
    failures = []

    def normalize_list(block):
        block = unwrap(block)
        if isinstance(block, dict) and "_values" in block:
            return block["_values"]
        if isinstance(block, list):
            return block
        return None
    
    # Try testFailureSummaries (common in Xcode 15+)
    for block in deep_find_all(json_obj, "testFailureSummaries"):
        block = normalize_list(block)
        if block is None:
            continue
        for item in block:
            item = unwrap(item)
            if isinstance(item, dict):
                test = unwrap(item.get("testCaseName", ""))
                msg = unwrap(item.get("message", ""))
                file = unwrap(item.get("fileName", ""))
                line = unwrap(item.get("lineNumber", ""))
                failures.append((str(test), str(msg), str(file), str(line)))
    
    # Try failureSummaries as fallback
    if not failures:
        for block in deep_find_all(json_obj, "failureSummaries"):
            block = normalize_list(block)
            if block is None:
                continue
            for item in block:
                item = unwrap(item)
                if isinstance(item, dict):
                    msg = unwrap(item.get("message", ""))
                    file = unwrap(item.get("fileName", ""))
                    line = unwrap(item.get("lineNumber", ""))
                    failures.append(("", str(msg), str(file), str(line)))
    
    # Deduplicate
    seen = set()
    unique = []
    for f in failures:
        if f not in seen:
            seen.add(f)
            unique.append(f)
    return unique


def load_summary(bundle_path: str) -> dict | None:
    """Load xcresult summary (Xcode 16+)."""
    cmd_new = [
        "xcrun", "xcresulttool", "get", "test-results", "summary",
        "--path", bundle_path,
        "--format", "json",
    ]
    return try_json(cmd_new)


def load_legacy_object(bundle_path: str) -> dict | None:
    """Load xcresult legacy object graph (Xcode 15+)."""
    cmd_legacy = [
        "xcrun", "xcresulttool", "get", "object", "--legacy",
        "--path", bundle_path,
        "--format", "json",
    ]
    return try_json(cmd_legacy)


def load_old_object(bundle_path: str) -> dict | None:
    """Load xcresult object graph without --legacy."""
    cmd_old = [
        "xcrun", "xcresulttool", "get", "object",
        "--path", bundle_path,
        "--format", "json",
    ]
    return try_json(cmd_old)


def extract_counts(json_obj: dict) -> tuple[int, int, bool, bool]:
    """Extract tests/failed counts with flags for presence."""
    tests_count_values = deep_find_all(json_obj, "testsCount")
    tests_failed_values = deep_find_all(json_obj, "testsFailedCount")
    tests_count = first_int(tests_count_values, default=0)
    tests_failed = first_int(tests_failed_values, default=0)
    count_found = len(tests_count_values) > 0
    failed_found = len(tests_failed_values) > 0

    if tests_count == 0:
        total_values = deep_find_all(json_obj, "totalTestCount")
        count_found = count_found or len(total_values) > 0
        tests_count = first_int(total_values, default=0)
    if tests_failed == 0:
        failed_values = deep_find_all(json_obj, "failedTestCount")
        failed_found = failed_found or len(failed_values) > 0
        tests_failed = first_int(failed_values, default=0)

    return tests_count, tests_failed, count_found, failed_found


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: xcresult_summary.py <path/to/TestResults.xcresult>", file=sys.stderr)
        return 2
    
    bundle = sys.argv[1]
    if not Path(bundle).exists():
        print(f"Missing xcresult bundle: {bundle}", file=sys.stderr)
        return 2
    
    data = load_summary(bundle)
    if data is None:
        data = load_legacy_object(bundle)
    if data is None:
        data = load_old_object(bundle)
    if data is None:
        print("Error: Failed to read xcresult via xcresulttool", file=sys.stderr)
        return 2

    tests_count, tests_failed, _, failed_found = extract_counts(data)
    if tests_count == 0 or not failed_found:
        legacy = load_legacy_object(bundle)
        if legacy is not None:
            data = legacy
            tests_count, tests_failed, _, failed_found = extract_counts(data)
    
    failures = collect_failures(data)
    if failures:
        tests_failed = max(tests_failed, len(failures))
    passed = max(0, tests_count - tests_failed)
    
    if tests_failed == 0:
        print(f"✅ Tests: {passed}/{tests_count} passed")
        return 0
    
    print(f"❌ Tests: {passed}/{tests_count} passed ({tests_failed} failed)")
    
    if failures:
        print("Failures:")
        for test, msg, file, line in failures[:10]:  # Limit to first 10
            loc = ""
            if file and line and line not in ("", "0"):
                # Shorten path for readability
                file_short = Path(file).name if "/" in file else file
                loc = f" @ {file_short}:{line}"
            
            if test:
                # Truncate long messages
                msg_short = msg[:80] + "..." if len(msg) > 80 else msg
                print(f"  - {test}: {msg_short}{loc}")
            else:
                msg_short = msg[:100] + "..." if len(msg) > 100 else msg
                print(f"  - {msg_short}{loc}")
        
        if len(failures) > 10:
            print(f"  ... and {len(failures) - 10} more failures")
    else:
        print("  (failure details not extracted; open .xcresult for context)")
    
    return 1


if __name__ == "__main__":
    sys.exit(main())
