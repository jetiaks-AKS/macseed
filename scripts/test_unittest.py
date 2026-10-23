"""Sequential unittest loading and safe timing records for scripts/test.sh."""
import importlib.util
import json
from pathlib import Path
import sys
import time
import traceback
import unittest


def load(path):
    path = Path(path).resolve()
    sys.path.insert(0, str(path.parent))
    name = path.stem.replace('-', '_')
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(module)
    if loader.errors:
        raise ValueError('unittest discovery failed')
    def flatten(suite):
        for test in suite:
            if isinstance(test, unittest.TestSuite):
                yield from flatten(test)
            else:
                yield test
    tests = list(flatten(suite))
    ids = [test.id() for test in tests]
    if not ids or len(set(ids)) != len(ids):
        raise ValueError('empty or duplicate unittest IDs')
    return dict(zip(ids, tests))


def write_json(path, value):
    path = Path(path)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


class TimedResult(unittest.TestResult):
    def __init__(self, destination, expected):
        super().__init__()
        self.destination, self.expected = destination, expected
        self.rows, self.cleanup_error = [], False
        self.current = None
        self.phase = None

    def save(self, complete=False):
        write_json(self.destination, dict(complete=complete, expected=self.expected,
                   cases=self.rows, cleanup_error=self.cleanup_error,
                   active=self.current['id'] if self.current else None))

    def wrap(self, test, method, label):
        original = getattr(test, method)
        def measured(*args, **kwargs):
            started, previous = time.monotonic(), self.phase
            self.phase = label
            try:
                return original(*args, **kwargs)
            except BaseException:
                self.failed_phase = label
                raise
            finally:
                self.phase = previous
                metric = self.current['timings'].setdefault(label, {'seconds': 0, 'count': 0})
                metric['seconds'] += time.monotonic() - started
                metric['count'] += 1
        setattr(test, method, measured)

    def startTest(self, test):
        super().startTest(test)
        self.current = dict(id=test.id(), status='PASS', timings={}, diagnostics=[])
        self.failed_phase = None
        self.started = time.monotonic()
        for method, label in (('_callSetUp', 'setup'), ('_callTestMethod', 'body'),
                              ('_callTearDown', 'teardown'), ('doCleanups', 'cleanup'),
                              ('_callCleanup', 'cleanup_callback')):
            self.wrap(test, method, label)
        # Helpers are timed, never memoized; nested times must not be summed.
        for method in ('invoke', 'execute', 'plan_result'):
            if hasattr(test, method):
                self.wrap(test, method, method)
        print('CASE ' + test.id(), flush=True)
        self.save()

    def diagnostic(self, err):
        # No exception values, source lines, locals, environment or operation logs.
        root = Path(__file__).resolve().parent.parent
        frames = []
        for frame, line in traceback.walk_tb(err[2]):
            try:
                relative = Path(frame.f_code.co_filename).resolve().relative_to(root)
            except ValueError:
                continue
            if relative != Path('scripts/test_unittest.py'):
                frames.append(dict(file=relative.as_posix(), line=line))
        return dict(error=err[0].__name__, frames=frames)

    def failure(self, test, status, err=None):
        if self.current is None:
            self.rows.append(dict(id=test.id(), status='ERROR', seconds=0,
                                  timings={}, diagnostics=[self.diagnostic(err)] if err else []))
            self.cleanup_error = True
        else:
            self.current['status'] = status
            if err:
                self.current['diagnostics'].append(self.diagnostic(err))
            if (self.phase in ('setup', 'teardown', 'cleanup')
                    or self.failed_phase in ('setup', 'teardown', 'cleanup', 'cleanup_callback')):
                self.cleanup_error = True

    def addFailure(self, test, err):
        # unittest may truncate traceback links during formatting. Preserve the
        # assertion location first; full exceptions stay in the runner's raw log.
        self.failure(test, 'FAIL', err)
        traceback.print_exception(*err, file=sys.stderr)
        super().addFailure(test, err)

    def addError(self, test, err):
        self.failure(test, 'ERROR', err)
        traceback.print_exception(*err, file=sys.stderr)
        super().addError(test, err)

    def addSubTest(self, test, subtest, err):
        if err:
            self.failure(test, 'FAIL' if issubclass(err[0], test.failureException) else 'ERROR', err)
            traceback.print_exception(*err, file=sys.stderr)
        super().addSubTest(test, subtest, err)

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        if self.current and self.current['status'] == 'PASS':
            self.current['status'] = 'SKIP'

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        self.failure(test, 'FAIL')

    def stopTest(self, test):
        self.current['seconds'] = round(time.monotonic() - self.started, 3)
        self.rows.append(self.current)
        print('{status} {id} {seconds:.3f}s'.format(**self.current), flush=True)
        self.current = None
        self.save()
        super().stopTest(test)
        if self.cleanup_error:
            self.stop()


def run(path, destination, ids=()):
    tests = load(path)
    selected = list(ids) or list(tests)
    if not selected or len(set(selected)) != len(selected) or set(selected) - tests.keys():
        raise ValueError('invalid case selection')
    result = TimedResult(destination, selected)
    result.save()
    unittest.TestSuite(tests[key] for key in selected).run(result)
    complete = [row['id'] for row in result.rows] == selected
    result.save(complete)
    return 0 if complete and result.wasSuccessful() and not result.cleanup_error else 1


if __name__ == '__main__':
    sys.exit(run(sys.argv[1], sys.argv[2], sys.argv[3:]))
