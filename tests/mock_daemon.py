#!/usr/bin/env python3
import os
import sys

PROTOCOL = 1


def encode(value: str) -> str:
    return value.replace('%', '%25').replace('\t', '%09').replace('\r', '%0D').replace('\n', '%0A')


def emit(line: str) -> None:
    sys.stdout.write(line + '\n')
    sys.stdout.flush()


emit(f'READY\t{PROTOCOL}')
crash_once = os.environ.get('SIMPLEMINIMAP_TEST_CRASH_ONCE', '')
if crash_once:
    try:
        descriptor = os.open(crash_once, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        pass
    else:
        os.close(descriptor)
        sys.exit(23)

pending = None
for raw in sys.stdin:
    line = raw.rstrip('\n')
    if not line:
        continue
    fields = line.split('\t')
    command = fields[0]
    if command == 'B':
        pending = {
            'id': int(fields[1]),
            'width': int(fields[2]),
            'source_lines': int(fields[7]),
            'groups': [],
        }
    elif command == 'G' and pending is not None:
        pending['groups'].append((int(fields[2]), int(fields[3])))
    elif command == 'E' and pending is not None:
        request_id = int(fields[1])
        if request_id != pending['id']:
            emit(f'X\t{request_id}\t{encode("ID mismatch")}')
            pending = None
            continue
        emit(f'B\t{request_id}\t{pending["source_lines"]}\t{len(pending["groups"])}')
        for index, (start, end) in enumerate(pending['groups']):
            marker = str((index + 1) % 10)
            text = marker * pending['width']
            emit(f'R\t{request_id}\t{start}\t{end}\t{encode(text)}')
        emit(f'E\t{request_id}')
        pending = None
    elif command == 'P':
        emit(f'PONG\t{fields[1]}\t{PROTOCOL}')
    else:
        emit(f'X\t0\t{encode("unknown command")}')
