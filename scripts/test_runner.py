"""Planning and bounded sequential execution behind the canonical Bash inventory."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time

from test_unittest import load, write_json

ROOT = Path(__file__).resolve().parent.parent
CASE_SHARDED = frozenset({
    'scripts/test-restore-prepare.py',
    'scripts/test-capture-api.py',
    'scripts/test-workspace-topology-execute.py',
})
QUICK = {
    'scripts/test-test-runner.py': (),
    'scripts/test-dry-run-cli.sh': (),
    'scripts/test-bs-launcher.sh': (),
    'scripts/test-bootstrap-startup.sh': (),
    'scripts/test-core-lifecycle.sh': (),
    'scripts/test-core-application-interface.py': (),
    'scripts/test-restore-prerequisites.py': (
        'test_restore_prerequisites.RestorePrerequisites.test_homebrew_activation_in_parent_and_downstream_process',),
}


def verify_partitions(units, partitions):
    expected = {(row['suite'], case) for row in units for case in row['ids'] or ['*']}
    assigned = [(row['suite'], case) for part in partitions for row in part for case in row['ids'] or ['*']]
    if (not all(partitions) or set(assigned) != expected
            or len(assigned) != len(expected)):
        raise ValueError('incomplete, overlapping or empty partitions')


def case_weights(suite, ids, weights):
    seconds = max(1, weights.get('suites', {}).get(suite, weights['unknown_suite_seconds']))
    known = weights.get('cases', {})
    missing = sum(key not in known for key in ids)
    default = max(weights.get('unknown_case_seconds', 60),
                  (seconds - sum(known.get(key, 0) for key in ids)) / max(1, missing))
    estimates = {key: max(1, known.get(key, default)) for key in ids}
    # Preserve measured suite startup/collection overhead when splitting a
    # fully measured suite. New cases never dilute measured case times.
    overhead = max(0, seconds - sum(estimates.values())) / len(ids)
    return {key: value + overhead for key, value in estimates.items()}


def plan(inventory, weights, total=1):
    if len(set(inventory)) != len(inventory) or not inventory:
        raise ValueError('invalid canonical inventory')
    units = []
    for suite in inventory:
        if not (ROOT / suite).is_file():
            raise ValueError('missing mandatory suite: ' + suite)
        seconds = max(1, weights.get('suites', {}).get(suite, weights['unknown_suite_seconds']))
        if suite in CASE_SHARDED:
            ids = list(load(ROOT / suite))
            estimates = case_weights(suite, ids, weights)
            units.extend(dict(suite=suite, ids=[key], seconds=estimates[key]) for key in ids)
        else:
            units.append(dict(suite=suite, ids=[], seconds=seconds))
    bins, costs = [[] for _ in range(total)], [0] * total
    for unit in sorted(units, key=lambda row: (-row['seconds'], row['suite'], row['ids'])):
        index = min(range(total), key=lambda i: (costs[i], i))
        bins[index].append(unit)
        costs[index] += unit['seconds']
    # One interpreter per assigned suite; preserve unittest loader method order.
    for index, part in enumerate(bins):
        grouped = {}
        for row in part:
            group = grouped.setdefault(row['suite'], dict(suite=row['suite'], ids=[], seconds=0))
            group['ids'].extend(row['ids'])
            group['seconds'] += row['seconds']
        for row in grouped.values():
            row['ids'].sort()
        bins[index] = sorted(grouped.values(), key=lambda row: (
            row['suite'] not in QUICK, row['seconds'], inventory.index(row['suite'])))
    verify_partitions(units, bins)
    return bins


def reproduction(row, case=None):
    command = ['./scripts/test.sh', '--suite', row['suite']]
    if case:
        command += ['--case', case]
    elif row['ids']:
        for key in row['ids']:
            command += ['--case', key]
    return shlex.join(command)


def classify(code, report, dirty=False):
    if dirty or code < 0 or code in (124, 130, 143):
        return 'ERROR', False
    if report is not None:
        ids = [row['id'] for row in report['cases']]
        if (not report['complete'] or report['cleanup_error'] or not ids
                or len(set(ids)) != len(ids) or ids != report['expected']):
            return 'ERROR', False
        statuses = {row['status'] for row in report['cases']}
        if not statuses <= {'PASS', 'FAIL', 'ERROR', 'SKIP'}:
            return 'ERROR', False
        if 'ERROR' in statuses:
            return 'ERROR', False
        if 'FAIL' in statuses:
            return 'FAIL', code == 1
        if code != 0:
            return 'ERROR', False
        return ('SKIP' if statuses == {'SKIP'} else 'PASS'), True
    return ('PASS', True) if code == 0 else ('FAIL', True) if code == 1 else ('ERROR', False)


class Cancelled(Exception):
    def __init__(self, code):
        self.code = code


def execute(row, directory, number):
    sys.path.insert(0, str(ROOT / 'modules/core/application-interface'))
    from item_execution import ProcessTree, process_table
    stem = f'{number:02d}-{Path(row["suite"]).stem}'
    destination = directory / 'safe' / (stem + '.json')
    report_path = directory / 'raw' / (stem + '.json')
    output = directory / 'raw' / (stem + '.log')
    command = ['bash', row['suite']]
    if row['suite'].endswith('.py'):
        command = [sys.executable, '-B', 'scripts/test_unittest.py', row['suite'],
                   str(report_path), *row['ids']]
    started, code, dirty, cancelled = time.monotonic(), 2, False, 0
    child = tree = None
    report, reason = None, None
    seen, active, announced = 0, None, time.monotonic()
    temporary = tempfile.TemporaryDirectory(prefix='macseed-suite-')
    try:
        process_table()  # Fail before launch if ownership observation is unavailable.
        with output.open('wb') as stream:
            # Hold the same PID until its birth/session has been observed. Even
            # a very short harness cannot exit before initial ownership capture.
            read_fd, write_fd = os.pipe()
            gate = ('import os,sys; fd=int(sys.argv[1]); token=os.read(fd,1); os.close(fd); '
                    'token == b"1" or sys.exit(2); os.execvp(sys.argv[2],sys.argv[2:])')
            try:
                child = subprocess.Popen([sys.executable, '-B', '-c', gate, str(read_fd), *command],
                                         pass_fds=(read_fd,), cwd=ROOT, stdout=stream,
                                         stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                         start_new_session=True,
                                         env=dict(os.environ, TMPDIR=temporary.name,
                                                  PYTHONDONTWRITEBYTECODE='1'))
                tree = ProcessTree(child.pid)
                os.write(write_fd, b'1')
            finally:
                os.close(read_fd)
                os.close(write_fd)
            # Three measured suite budgets plus startup, minimum five minutes.
            # Individual unittest bodies also have a fifteen-minute ceiling.
            deadline = started + max(300, row['seconds'] * 3 + 60)
            case_at = time.monotonic()
            while child.poll() is None:
                tree.scan()
                if report_path.exists():
                    current = json.loads(report_path.read_text())
                    if len(current['cases']) != seen:
                        for case in current['cases'][seen:]:
                            print('  {status} {id} {seconds:.3f}s'.format(**case), flush=True)
                        seen, case_at = len(current['cases']), time.monotonic()
                    if current.get('active') != active:
                        active = current.get('active')
                        if active:
                            print('  CASE ' + active, flush=True)
                    if time.monotonic() - announced >= 60:
                        print(f'  RUNNING {active or row["suite"]} {time.monotonic() - started:.1f}s', flush=True)
                        announced = time.monotonic()
                if time.monotonic() >= deadline or time.monotonic() - case_at >= 900:
                    code, dirty, reason = 124, True, 'deadline'
                    break
                time.sleep(.25)
            else:
                code = child.returncode
    except Cancelled as exc:
        code = cancelled = exc.code
        dirty, reason = True, 'cancelled'
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, subprocess.SubprocessError):
        dirty, reason = True, 'runner_or_observation_error'
    finally:
        handlers = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
        # Do not resume on an unknown or dirty boundary, even if cleanup succeeds.
        try:
            if child is not None:
                tree = tree or ProcessTree(child.pid)
                if tree.scan():
                    dirty = True
                    reason = reason or 'surviving_processes'
                    if not tree.stop():
                        reason = 'unconfirmed_cleanup'
                child.wait(timeout=3)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            dirty, reason = True, 'unconfirmed_cleanup'
        try:
            if any(Path(temporary.name).iterdir()):
                dirty, reason = True, reason or 'fixture_cleanup_incomplete'
            if reason != 'unconfirmed_cleanup':
                temporary.cleanup()
            else:
                # Preserve the owned directory when a process may still use it.
                temporary._finalizer.detach()
        except OSError:
            dirty, reason = True, 'fixture_cleanup_failed'
            temporary._finalizer.detach()
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
    if report_path.exists():
        try:
            report = json.loads(report_path.read_text())
        except (OSError, ValueError):
            dirty, reason = True, 'invalid_worker_report'
    elif row['suite'].endswith('.py'):
        dirty, reason = True, 'missing_worker_report'
    try:
        if report is not None and row['ids'] and report['expected'] != row['ids']:
            dirty, reason = True, 'worker_selection_mismatch'
        status, isolated = classify(code, report, dirty)
    except (KeyError, TypeError, ValueError):
        report, reason, status, isolated = None, 'invalid_worker_report', 'ERROR', False
    result = dict(suite=row['suite'], ids=row['ids'], status=status, code=code,
                  seconds=round(time.monotonic() - started, 3), reason=reason,
                  reproduce=reproduction(row), cases=report['cases'] if report else [])
    for case in result['cases'][seen:]:
        print('  {status} {id} {seconds:.3f}s'.format(**case), flush=True)
    if report:
        finished = {case['id'] for case in result['cases']}
        result['cases'].extend(dict(id=key, status='NOT RUN', seconds=0, timings={}, diagnostics=[])
                               for key in report['expected'] if key not in finished)
    if row['suite'].endswith('.sh') and code != 0 and output.exists():
        # Match only fixed, repository-authored assertion labels. Never copy the
        # dynamic part of a shell failure (which may include fixture contents).
        raw = output.read_text(errors='replace')
        checks = []
        for line, source in enumerate((ROOT / row['suite']).read_text().splitlines(), 1):
            match = re.search(r'\bfail "([^"$`\\]+)', source)
            if match and 'FAIL: ' + match[1] in raw:
                checks.append(dict(line=line, label=match[1][:120]))
        result['checks'] = checks
        if status == 'FAIL' and not re.search(r'^FAIL:', raw, re.M):
            status, isolated = 'ERROR', False
            result.update(status=status, reason='unclassified_shell_failure')
    write_json(destination, result)
    lines = [f'{status} {row["suite"]} {result["seconds"]}s', result['reproduce']]
    lines += [json.dumps(check) for check in result.get('checks', [])]
    for case in result['cases']:
        lines.append('{status} {id} {seconds:.3f}s'.format(**case))
        if case['status'] in ('FAIL', 'ERROR'):
            lines += [reproduction(row, case['id']), json.dumps(case['diagnostics'])]
    (directory / 'safe' / (stem + '.log')).write_text('\n'.join(lines) + '\n')
    return result, isolated, cancelled


def summarize(directory, rows, display=True):
    counts = Counter(row['status'] for row in rows)
    lines = ['Regression results', '', ' | '.join(f'{name}: {counts[name]}' for name in
             ('PASS', 'FAIL', 'ERROR', 'SKIP', 'NOT RUN')), '', '| Suite | Result | Seconds |',
             '| --- | --- | ---: |']
    lines += [f'| {row["suite"]} | {row["status"]} | {row["seconds"]:.3f} |' for row in rows]
    lines += ['', 'Slow suites:']
    lines += [f'- {row["suite"]}: {row["seconds"]:.3f}s' for row in
              sorted(rows, key=lambda row: -row['seconds'])[:5]]
    cases = [(row, case) for row in rows for case in row.get('cases', [])]
    case_counts = Counter(case['status'] for _, case in cases)
    lines += ['', 'Cases: ' + ' | '.join(f'{name}: {case_counts[name]}' for name in
              ('PASS', 'FAIL', 'ERROR', 'SKIP', 'NOT RUN'))]
    lines += ['', 'Slow cases:']
    lines += [f'- {case["id"]}: {case["seconds"]:.3f}s' for _, case in
              sorted(cases, key=lambda pair: -pair[1]['seconds'])[:10]]
    for row in rows:
        if row['status'] in ('FAIL', 'ERROR', 'NOT RUN'):
            lines += ['', f'{row["status"]}: `{row["reproduce"]}`']
            for case in row.get('cases', []):
                if case['status'] in ('FAIL', 'ERROR'):
                    lines += [f'Case: `{reproduction(row, case["id"])}`']
    summary = '\n'.join(lines) + '\n'
    (directory / 'safe/summary.md').write_text(summary)
    write_json(directory / 'safe/summary.json', rows)
    if display:
        print(summary, flush=True)


def main(inventory, argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shard', default='1/1')
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--quick', action='store_true')
    parser.add_argument('--suite', choices=inventory)
    parser.add_argument('--case', action='append', default=[])
    parser.add_argument('--ci', action='store_true', help='continue only after isolated assertion failures')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args(argv)
    if args.case and not args.suite or args.quick and (args.suite or args.shard != '1/1'):
        parser.error('--case requires --suite; --quick cannot be combined with suite/shard')
    try:
        index, total = map(int, args.shard.split('/'))
        if not 1 <= index <= total <= len(inventory):
            raise ValueError('invalid shard')
        weights = json.loads((ROOT / 'scripts/test-timings.json').read_text())
        partitions = plan(inventory, weights, total)
        selected = [dict(row, ids=list(row['ids'])) for row in partitions[index - 1]]
        if args.quick:
            selected = [dict(suite=suite, ids=list(ids), seconds=60) for suite, ids in QUICK.items()]
        elif args.suite:
            if args.shard != '1/1':
                raise ValueError('--suite cannot be combined with --shard')
            selected = [row for row in selected if row['suite'] == args.suite]
            if args.case:
                if not args.suite.endswith('.py'):
                    raise ValueError('--case requires a Python unittest suite')
                tests = load(ROOT / args.suite)
                ids = []
                for value in args.case:
                    matches = [key for key in tests if key == value or key.endswith('.' + value)]
                    if len(matches) != 1 or matches[0] in ids:
                        raise ValueError('unknown, ambiguous or duplicate case')
                    ids.append(matches[0])
                selected[0]['ids'] = ids
                estimates = case_weights(args.suite, list(tests), weights)
                selected[0]['seconds'] = sum(estimates[key] for key in ids)
        if args.list:
            print(json.dumps(dict(partitions=partitions, selected=selected), indent=2))
            return 0
    except (OSError, ValueError, ImportError) as exc:
        parser.error(str(exc))
    directory = (args.output or ROOT / 'logs/regression' / str(time.time_ns())).resolve()
    directory.mkdir(parents=True, exist_ok=False, mode=0o700)
    (directory / 'raw').mkdir(mode=0o700)
    (directory / 'safe').mkdir(mode=0o700)
    write_json(directory / 'safe/plan.json', dict(partitions=partitions, selected=selected))
    def cancel(sig, frame):
        raise Cancelled(130 if sig == signal.SIGINT else 143)
    signal.signal(signal.SIGINT, cancel)
    signal.signal(signal.SIGTERM, cancel)
    rows, stopped, cancelled, active_row = [], False, 0, None
    try:
        for number, row in enumerate(selected, 1):
            if stopped:
                break
            print(f'[{number}/{len(selected)}] {row["suite"]}', flush=True)
            active_row = row
            result, isolated, cancelled = execute(row, directory, number)
            rows.append(result)
            active_row = None
            stopped = not isolated or (not args.ci and result['status'] in ('FAIL', 'ERROR'))
            print(f'{result["status"]} {row["suite"]} {result["seconds"]:.3f}s', flush=True)
            summarize(directory, rows, display=False)
    except Cancelled as exc:
        cancelled = exc.code
        if active_row is not None:
            rows.append(dict(active_row, status='ERROR', seconds=0, reason='cancelled',
                             code=cancelled, reproduce=reproduction(active_row)))
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, signal.SIG_IGN)
        for row in selected[len(rows):]:
            rows.append(dict(row, status='NOT RUN', seconds=0, reproduce=reproduction(row)))
        summarize(directory, rows)
    print('Diagnostics: ' + str(directory / 'safe'), flush=True)
    if cancelled:
        return cancelled
    return int(any(row['status'] in ('FAIL', 'ERROR', 'NOT RUN') for row in rows))


if __name__ == '__main__':
    boundary = sys.argv.index('--')
    sys.exit(main(sys.argv[1:boundary], sys.argv[boundary + 1:]))
