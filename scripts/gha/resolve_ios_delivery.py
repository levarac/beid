#!/usr/bin/env python3

import argparse


EXPECTED = {
    "internal": ("Beid-Internal", "Internal"),
    "release": ("Beid", "Release"),
}


def resolve(channel: str, scheme: str, configuration: str) -> tuple[str, str]:
    expected = EXPECTED.get(channel)
    if expected is None or (scheme, configuration) != expected:
        raise ValueError("iOS delivery channel, scheme, and configuration do not match")
    return expected


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("channel")
    parser.add_argument("scheme")
    parser.add_argument("configuration")
    args = parser.parse_args()
    scheme, configuration = resolve(args.channel, args.scheme, args.configuration)
    print(scheme, configuration)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
