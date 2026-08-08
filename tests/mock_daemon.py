#!/usr/bin/env python3
import os
import sys

PROTOCOL = 3


def encode(value: str) -> str:
    return value.replace('%', '%25').replace('\t', '%09').replace('\r', '%0D').replace('\n', '%0A')


def emit(line: str) -> None:
    sys.stdout.write(line + '\n')
    sys.stdout.flush()


# A daemon left behind by a plugin update that never rebuilt lib/ announces an
# older protocol; the plugin has to say so and name the fix.
PROTOCOL = int(os.environ.get('SIMPLEMINIMAP_TEST_PROTOCOL', '') or PROTOCOL)

# The diagnostic flags the whole simple* suite shares.  They answer and exit
# without touching any of the failure modes below -- the plugin probes
# --version in a separate process, and a probe that consumed the one-shot crash
# marker would quietly disarm the crash it was meant to leave for the daemon.
if len(sys.argv) > 1:
    if sys.argv[1] == '--version':
        emit(f'simpleminimap-daemon (mock) protocol {PROTOCOL}')
    elif sys.argv[1] == '--self-test':
        emit('ok')
    else:
        emit('usage: mock_daemon.py [--version|--help|--self-test]')
    sys.exit(0)

# One line per real daemon start, so a test can assert how many processes a
# failure mode forked.  Written below the diagnostic flags above, which exit
# first, so the plugin's --version probe is never counted as a daemon.
spawn_log = os.environ.get('SIMPLEMINIMAP_TEST_SPAWN_LOG', '')
if spawn_log:
    with open(spawn_log, 'a') as handle:
        handle.write(f'{os.getpid()}\n')

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

# Serve one render, then die -- every time.  This is the crash loop a restart
# budget reset by "the last render succeeded" can never break out of, because
# progress is exactly what it keeps making.
crash_after_render = os.environ.get('SIMPLEMINIMAP_TEST_CRASH_AFTER_RENDER', '') != ''

# Accept input and answer nothing: the wedged daemon that request timeouts
# exist for.  READY was already sent, so the plugin considers the backend
# healthy and job_status() keeps reporting "run" -- exactly the state that used
# to leave a minimap stale for ever behind a green :SimpleMinimapHealth.
wedged = os.environ.get('SIMPLEMINIMAP_TEST_WEDGE', '') != ''

pending = None
for raw in sys.stdin:
    line = raw.rstrip('\n')
    if not line or wedged:
        continue
    fields = line.split('\t')
    command = fields[0]
    if command == 'B':
        if pending is not None:
            emit(f'X\t{pending["id"]}\t{encode("superseded by a newer request")}')
        pending = {
            'id': int(fields[1]),
            'width': int(fields[2]),
            'source_lines': int(fields[7]),
            'groups': [],
        }
    elif command == 'G' and pending is not None:
        # Field 8 is the per-sample syntax class.  The mock draws synthetic
        # text, so it cannot work out which sample inked which cell -- it
        # reports the first sample's class for the whole row, which is enough
        # for a test to prove the class survives the round trip.
        classes = fields[8] if len(fields) > 8 and fields[8] else 'nnnn'
        pending['groups'].append((int(fields[2]), int(fields[3]), classes[0]))
    elif command == 'E' and pending is not None:
        request_id = int(fields[1])
        if request_id != pending['id']:
            emit(f'X\t{request_id}\t{encode("ID mismatch")}')
            pending = None
            continue
        emit(f'B\t{request_id}\t{pending["source_lines"]}\t{len(pending["groups"])}')
        for index, (start, end, sample_class) in enumerate(pending['groups']):
            marker = str((index + 1) % 10)
            text = marker * pending['width']
            shade = '2' * pending['width']
            classes = sample_class * pending['width']
            emit(f'R\t{request_id}\t{start}\t{end}\t{encode(text)}\t{shade}\t{classes}')
        emit(f'E\t{request_id}')
        if crash_after_render:
            sys.exit(23)
        pending = None
    elif command == 'P':
        emit(f'PONG\t{fields[1]}\t{PROTOCOL}')
    else:
        emit(f'X\t0\t{encode("unknown command")}')
