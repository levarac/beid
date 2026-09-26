#!/usr/bin/env python3
"""Keep iOS test selection complete and require every current-head result."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET

GROUPS = {
    "unit": ("-only-testing:BeidTests",),
    "ipad": ("-only-testing:BeidUITests/BeidIPadLayoutTests",),
    "interface": ("-only-testing:BeidUITests", "-skip-testing:BeidUITests/BeidIPadLayoutTests"),
}
FIELDS = dict(total="totalTestCount", passed="passedTests", failed="failedTests",
              skipped="skippedTests", expected_failures="expectedFailures")


def arguments(group):
    if group not in GROUPS:
        raise ValueError(f"unknown iOS test group: {group}")
    return GROUPS[group]


def verify_scheme(path):
    targets = {node.attrib["BlueprintName"] for node in
               ET.parse(path).findall(".//Testables/TestableReference/BuildableReference")}
    if targets != {"BeidTests", "BeidUITests"}:
        raise ValueError(f"test groups do not cover scheme targets: {sorted(targets)}")


def counts(summary):
    try:
        result = {name: summary[field] for name, field in FIELDS.items()}
        if any(isinstance(n, bool) or not isinstance(n, int) or n < 0 for n in result.values()):
            raise ValueError("test counts must be nonnegative integers")
        if sum(n for key, n in result.items() if key != "total") != result["total"]:
            raise ValueError("test categories do not account for total")
        if result["passed"] <= 0 or result["failed"] or summary["result"] != "Passed":
            raise ValueError(f"tests did not pass with executed evidence: {result}")
        return result
    except (KeyError, TypeError) as error:
        raise ValueError("incomplete test summary") from error


def aggregate(directory, head):
    if {p.name for p in directory.glob("*.json")} != {group + ".json" for group in GROUPS}:
        raise ValueError("expected exactly one result for every iOS test group")
    total = dict.fromkeys(FIELDS, 0)
    for group in GROUPS:
        record = json.loads((directory / (group + ".json")).read_text())
        if record.get("group") != group or record.get("head") != head:
            raise ValueError(f"wrong group or commit in {group} evidence")
        for key, value in counts(record.get("summary", {})).items():
            total[key] += value
    return total


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    arguments_parser = commands.add_parser("arguments")
    arguments_parser.add_argument("group", choices=GROUPS)
    scheme_parser = commands.add_parser("check-scheme")
    scheme_parser.add_argument("path", type=Path)
    record_parser = commands.add_parser("record")
    record_parser.add_argument("group", choices=GROUPS)
    record_parser.add_argument("summary", type=Path)
    record_parser.add_argument("output", type=Path)
    record_parser.add_argument("head")
    aggregate_parser = commands.add_parser("aggregate")
    aggregate_parser.add_argument("directory", type=Path)
    aggregate_parser.add_argument("head")
    args = parser.parse_args()
    if args.command == "arguments":
        print("\n".join(arguments(args.group)))
    elif args.command == "check-scheme":
        verify_scheme(args.path)
        print("All scheme test targets are covered by disjoint test groups")
    elif args.command == "record":
        summary = json.loads(args.summary.read_text())
        result = counts(summary)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(dict(group=args.group, head=args.head, summary=summary)))
        print(f"iOS {args.group} tests: " + json.dumps(result, sort_keys=True))
    else:
        print("iOS complete suite: " + json.dumps(aggregate(args.directory, args.head), sort_keys=True))


if __name__ == "__main__":
    main()
