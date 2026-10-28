"""Record local Gradle cache entry identities without unpacking build outputs.

GitHub's cache size/hit lines cannot establish which task entries were restored
or stored. Retain a before/after inventory alongside the per-task timings.
"""
import argparse
import json
from pathlib import Path
import re
import tarfile


def inventory(directory):
    entries = []
    for path in sorted(directory.glob('*')):
        if not re.fullmatch(r'[0-9a-f]{32}', path.name) or not path.is_file():
            continue
        entry = {'key': path.name, 'bytes': path.stat().st_size}
        try:
            with tarfile.open(path, 'r|gz') as archive:
                for member in archive:
                    if member.name == 'METADATA':
                        if not member.isfile() or member.size > 65536:
                            raise ValueError('invalid METADATA')
                        metadata = archive.extractfile(member).read().decode('utf-8')
                        break
                else:
                    raise KeyError('missing METADATA')
            # Gradle's Java Properties metadata escapes task colons. Select
            # fields explicitly: do not retain host names or invocation IDs.
            for line in metadata.splitlines():
                name, separator, value = line.partition('=')
                if separator and name in ('identity', 'executionTime', 'gradleVersion'):
                    entry[name] = value.replace('\\:', ':')
        except (OSError, tarfile.TarError, KeyError, UnicodeError, ValueError) as error:
            entry['error'] = type(error).__name__
        entries.append(entry)
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(inventory(args.directory), indent=2) + '\n')


if __name__ == '__main__':
    main()
