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
    
    # Try testFailureSummaries (common in Xcode 15+)
    for block in deep_find_all(json_obj, "testFailureSummaries"):
        block = unwrap(block)
        if isinstance(block, list):
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
            block = unwrap(block)
            if isinstance(block, list):
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


def load_xcresult(bundle_path: str) -> dict:
    """Load and parse xcresult bundle using xcresulttool."""
    
    # Xcode 16+: try `get test-results summary` first
    cmd_new = [
        "xcrun", "xcresulttool", "get", "test-results", "summary",
        "--path", bundle_path,
        "--format", "json",
    ]
    data = try_json(cmd_new)
    if data is not None:
        return data
    
    # Xcode 15+: try legacy object graph
    cmd_legacy = [
        "xcrun", "xcresulttool", "get", "object", "--legacy",
        "--path", bundle_path,
        "--format", "json",
    ]
    data = try_json(cmd_legacy)
    if data is not None:
        return data
    
    # Oldest fallback: object without --legacy
    cmd_old = [
        "xcrun", "xcresulttool", "get", "object",
        "--path", bundle_path,
        "--format", "json",
    ]
    data = try_json(cmd_old)
    if data is not None:
        return data
    
    raise RuntimeError("Failed to read xcresult via xcresulttool")


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: xcresult_summary.py <path/to/TestResults.xcresult>", file=sys.stderr)
        return 2
    
    bundle = sys.argv[1]
    if not Path(bundle).exists():
        print(f"Missing xcresult bundle: {bundle}", file=sys.stderr)
        return 2
    
    try:
        data = load_xcresult(bundle)
    except RuntimeError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 2
    
    # Extract counts
    tests_count = first_int(deep_find_all(data, "testsCount"), default=0)
    tests_failed = first_int(deep_find_all(data, "testsFailedCount"), default=0)
    
    # Fallback: try alternative key names
    if tests_count == 0:
        tests_count = first_int(deep_find_all(data, "totalTestCount"), default=0)
    if tests_failed == 0:
        tests_failed = first_int(deep_find_all(data, "failedTestCount"), default=0)
    
    passed = max(0, tests_count - tests_failed)
    
    if tests_failed == 0:
        print(f"✅ Tests: {passed}/{tests_count} passed")
        return 0
    
    print(f"❌ Tests: {passed}/{tests_count} passed ({tests_failed} failed)")
    
    failures = collect_failures(data)
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
