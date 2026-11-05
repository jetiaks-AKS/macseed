"""Own Stage 12 import/export processes and relay transient input challenges."""
import json
import os
import re
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys

sys.dont_write_bytecode = True
import tempfile
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'migration'))
from evidence import read_evidence
from secret_input import (WAIT_SECONDS, SecureError, inherited_socket,
                          metadata, receive, response, send, valid_challenge, unique_fields)


def launch_channel(arguments):
    if (len(arguments) != 2 or arguments[0] != '--secure-fd' or
            not arguments[1].isascii() or not arguments[1].isdigit() or len(arguments[1]) > 10 or int(arguments[1]) > 2147483647):
        return None
    try:
        channel = inherited_socket(int(arguments[1]))
        if select.select([channel], [], [], 0)[0]:
            channel.close()  # EOF or unsolicited input is not a valid launch channel.
            return None
        return channel
    except (ValueError, OSError, OverflowError):
        fd = int(arguments[1])
        if fd > 2:
            try:
                os.close(fd)
            except OSError:
                pass
        return None


def terminate(child):
    if child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=1)


def import_records(raw):
    """Project a validated importer receipt as one selected package requirement.

    read_evidence owns validation. Names and identity counts never cross this
    adapter; the original receipt still drives production Verification.
    """
    rows = [line.split('\t') for line in raw.decode('ascii').splitlines()]
    _, _, _, selection, _, outcome, reason = rows[0]
    identities = rows[1:-1]
    verified = selection == 'validated' and outcome in ('success', 'noop') and all(row[2] == 'verified' for row in identities)
    mismatch = any(row[2] == 'mismatch' for row in identities)
    base = {'domain': 'secure-ssh-identities', 'item_id': 'encrypted_identity_set'}
    yield 'operation', dict(base, record_id='o:0', action='validate_and_import', outcome=outcome, reason=reason)
    yield 'coverage', dict(base, record_id='c:0', disposition='resolved' if selection == 'validated' else 'unresolved',
                           source_status='observed_present' if selection == 'validated' else 'unobserved')
    yield 'verification', dict(base, record_id='v:0', predicate='identity_set_matches_package',
                               conformity='verified' if verified else 'mismatch' if mismatch else 'unverified',
                               support='supported', observed_at=max((row[3] for row in identities if row[3] != '-'), default=None))


def _run_secure(root, package, channel, operation_id, event, mutation, export_selection=None, record=None,
                  *, compare=False, expected_target_state=None):
    child = None
    parent, endpoint = socket.socketpair()
    parent.setblocking(False)
    attempt = uuid.uuid4().hex
    failure_code = 'secure_comparison_failed' if compare else 'secure_import_failed' if export_selection is None else 'secure_export_failed'
    try:
        with tempfile.TemporaryDirectory(prefix='macseed-evidence-', dir='/private/tmp') as temporary:
            os.chmod(temporary, 0o700)
            evidence = str(Path(temporary) / 'terminal')
            try:
                command = ['./scripts/ssh-identity-migrate.sh', 'import', '--input', str(package.parent.resolve() / package.name),
                           '--internal-evidence', evidence, '--attempt', attempt,
                           '--application-channel-fd', str(endpoint.fileno()), '--operation-id', operation_id]
                if export_selection is not None:
                    command = ['./scripts/ssh-identity-migrate.sh', 'application-export', '--output', str(package),
                               '--selection', str(export_selection), '--application-channel-fd', str(endpoint.fileno()),
                               '--operation-id', operation_id]
                elif compare:
                    # Like Import, normalize Core's private staging parent (macOS
                    # /var and /tmp aliases), never the package entry itself.
                    command = ['./scripts/ssh-identity-migrate.sh', 'application-compare', '--input', str(package.parent.resolve() / package.name),
                               '--application-channel-fd', str(endpoint.fileno()), '--operation-id', operation_id]
                elif expected_target_state is not None:
                    command += ['--expected-target-state', expected_target_state]
                environment = dict(os.environ)
                # Launch metadata cannot leak into secret consumer or ordinary child setup.
                for name in ('MACSEED_APPLICATION_SECURE_READY', 'MACSEED_SECURE_EVIDENCE_FD'):
                    environment.pop(name, None)
                child = subprocess.Popen(command, cwd=root, env=environment,
                                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE if compare else subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL, start_new_session=True,
                                         pass_fds=(endpoint.fileno(),))
                endpoint.close()
                code = None
                seen_challenges = set()
                previous_challenge = None
                deadline = time.monotonic() + WAIT_SECONDS
                phase = 'secure_compare' if compare else 'secure_packaging' if export_selection is not None else 'secure_import'
                event('phase_started', {'phase': phase})
                while code is None:
                    if time.monotonic() >= deadline:
                        raise SecureError('secure_channel_timeout')
                    ready = select.select([parent, channel], [], [], .1)[0]
                    if channel in ready:
                        # Responses are legal only while a challenge is outstanding.
                        if not channel.recv(1, socket.MSG_PEEK):
                            raise SecureError('secure_cancelled')
                        raise SecureError('secure_channel_invalid')
                    if parent not in ready:
                        if child.poll() is not None:
                            raise SecureError(failure_code)
                        continue
                    try:
                        message = json.loads(receive(parent, deadline).decode('ascii'), object_pairs_hook=unique_fields)
                    except SecureError as exc:
                        if exc.code == 'secure_cancelled':
                            raise SecureError(failure_code) from None
                        raise
                    except (ValueError, UnicodeError):
                        raise SecureError('secure_channel_invalid') from None
                    if message == {'type': 'mutation'}:
                        if compare:
                            raise SecureError('secure_channel_invalid')
                        mutation()
                        send(parent, b'ACK')
                    elif isinstance(message, dict) and message.get('type') == 'challenge':
                        kinds = {'bundle_encrypt', 'ssh_key_unlock'} if export_selection is not None else {'bundle_unlock'} if compare else {'bundle_unlock', 'ssh_key_unlock', 'import_confirmation'}
                        if (not valid_challenge(message, operation_id, kinds) or message['challenge_id'] in seen_challenges
                                or len(seen_challenges) >= 32 * 3 + 3 + 1
                                or (message['attempt'] > 1 and (previous_challenge is None
                                    or message['kind'] != previous_challenge['kind']
                                    or message.get('identity') != previous_challenge.get('identity')
                                    or message['attempt'] != previous_challenge['attempt'] + 1))):
                            raise SecureError('secure_channel_invalid')
                        seen_challenges.add(message['challenge_id'])
                        previous_challenge = message
                        event('secure_challenge_waiting', {'kind': message['kind'], 'attempt': message['attempt']})
                        if message['attempt'] > 1:
                            event('secure_retry_required', {'kind': message['kind'], 'attempt': message['attempt']})
                        metadata(channel, message)
                        body = receive(channel, time.monotonic() + WAIT_SECONDS)
                        response(body, message)  # Validate before forwarding; never JSON encode a response.
                        send(parent, body)
                        del body
                        deadline = time.monotonic() + WAIT_SECONDS
                    elif (isinstance(message, dict) and set(message) == {'type', 'code'} and
                          message['type'] == 'finish' and message['code'] in
                          {'success', 'secure_cancelled', 'secure_target_conflict', 'secure_payload_invalid',
                           'secure_import_failed', 'secure_tool_failed', 'secure_unlock_rejected',
                           'secure_key_unlock_rejected', 'secure_channel_timeout', 'secure_channel_invalid',
                           'secure_export_failed', 'secure_target_changed', 'secure_comparison_failed'} and
                          (message['code'] != 'secure_comparison_failed' or compare) and
                          (message['code'] != 'secure_export_failed' or export_selection is not None)):
                        code = message['code']
                    else:
                        raise SecureError('secure_channel_invalid')
                try:
                    status = child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    raise SecureError(failure_code) from None
                raw = None if export_selection is not None or compare else read_evidence(evidence, attempt, status)
                if raw is not None and record is not None:
                    for kind, value in import_records(raw):
                        record(kind, value)
                if code != 'success':
                    error = SecureError(code)
                    if export_selection is None and not compare:
                        error.evidence = (raw, attempt, status)
                    raise error
                if status != 0:
                    raise SecureError(failure_code)
                if compare:
                    raw_result = child.stdout.read(1025)
                    if len(raw_result) > 1024:
                        raise SecureError('secure_comparison_failed')
                    value = json.loads(raw_result)
                    if (not isinstance(value, dict) or set(value) != {'decision', 'target_state'} or
                            value['decision'] not in ('all_match', 'import_required', 'conflict') or
                            (value['decision'] == 'conflict' and value['target_state'] is not None) or
                            (value['decision'] != 'conflict' and (not isinstance(value['target_state'], str) or
                             not re.fullmatch('[0-9a-f]{64}', value['target_state'])))):
                        raise SecureError('secure_comparison_failed')
                    event('phase_completed', {'phase': phase})
                    return value
                event('phase_completed', {'phase': phase})
                return None if export_selection is not None else (raw, attempt, status)
            finally:
                if child is not None:
                    terminate(child)
                    if child.stdout is not None:
                        child.stdout.close()
    except (OSError, ValueError):
        raise SecureError(failure_code) from None
    finally:
        if child is not None:
            terminate(child)
        parent.close()
        endpoint.close()
        channel.close()


def import_secure(root, package, channel, operation_id, event, mutation, export_selection=None, record=None,
                  *, expected_target_state=None):
    return _run_secure(root, package, channel, operation_id, event, mutation, export_selection, record,
                       expected_target_state=expected_target_state)


def export_secure(root, package, selection, channel, operation_id, event):
    def unexpected_mutation():
        raise SecureError('secure_channel_invalid')
    return _run_secure(root, package, channel, operation_id, event, unexpected_mutation, selection)


def compare_secure(root, package, channel, operation_id, event):
    def unexpected_mutation():
        raise SecureError('secure_channel_invalid')
    return _run_secure(root, package, channel, operation_id, event, unexpected_mutation, compare=True)
