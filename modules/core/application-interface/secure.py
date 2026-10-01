"""Own the existing Stage 12 importer and relay its transient input challenges."""
import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'migration'))
from evidence import read_evidence
from secret_input import (KINDS, WAIT_SECONDS, SecureError, inherited_socket,
                          metadata, receive, response, send)


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
            child.wait()


def import_secure(root, package, channel, operation_id, event, mutation):
    child = None
    parent, endpoint = socket.socketpair()
    parent.setblocking(False)
    attempt = uuid.uuid4().hex
    try:
        with tempfile.TemporaryDirectory(prefix='macseed-evidence-', dir='/private/tmp') as temporary:
            os.chmod(temporary, 0o700)
            evidence = str(Path(temporary) / 'terminal')
            try:
                command = ['./scripts/ssh-identity-migrate.sh', 'import', '--input', str(package.parent.resolve() / package.name),
                           '--internal-evidence', evidence, '--attempt', attempt,
                           '--application-channel-fd', str(endpoint.fileno()), '--operation-id', operation_id]
                environment = dict(os.environ)
                # Launch metadata cannot leak into secret consumer or ordinary child setup.
                for name in ('MACSEED_APPLICATION_SECURE_READY', 'MACSEED_SECURE_EVIDENCE_FD'):
                    environment.pop(name, None)
                child = subprocess.Popen(command, cwd=root, env=environment,
                                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL, start_new_session=True,
                                         pass_fds=(endpoint.fileno(),))
                endpoint.close()
                code = None
                deadline = time.monotonic() + WAIT_SECONDS
                event('phase_started', {'phase': 'secure_import'})
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
                            raise SecureError('secure_import_failed')
                        continue
                    try:
                        message = json.loads(receive(parent, deadline).decode('ascii'))
                    except SecureError as exc:
                        if exc.code == 'secure_cancelled':
                            raise SecureError('secure_import_failed') from None
                        raise
                    except (ValueError, UnicodeError):
                        raise SecureError('secure_channel_invalid') from None
                    if message == {'type': 'mutation'}:
                        mutation()
                        send(parent, b'ACK')
                    elif isinstance(message, dict) and message.get('type') == 'challenge':
                        if (set(message) != {'type', 'protocol_version', 'operation_id', 'challenge_id', 'kind', 'attempt'} or
                                type(message['protocol_version']) is not int or message['protocol_version'] != 1 or message['operation_id'] != operation_id or
                                message['kind'] not in KINDS or type(message['attempt']) is not int or
                                not 1 <= message['attempt'] <= 3 or
                                not isinstance(message['challenge_id'], str) or len(message['challenge_id']) != 32):
                            raise SecureError('secure_channel_invalid')
                        try:
                            bytes.fromhex(message['challenge_id'])
                        except ValueError:
                            raise SecureError('secure_channel_invalid') from None
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
                           'secure_key_unlock_rejected', 'secure_channel_timeout', 'secure_channel_invalid'}):
                        code = message['code']
                    else:
                        raise SecureError('secure_channel_invalid')
                try:
                    status = child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    raise SecureError('secure_import_failed') from None
                raw = read_evidence(evidence, attempt, status)
                if code != 'success':
                    error = SecureError(code)
                    error.evidence = (raw, attempt, status)
                    raise error
                if status != 0:
                    raise SecureError('secure_import_failed')
                event('phase_completed', {'phase': 'secure_import'})
                return raw, attempt, status
            finally:
                if child is not None:
                    terminate(child)
    except (OSError, ValueError):
        raise SecureError('secure_import_failed') from None
    finally:
        if child is not None:
            terminate(child)
        parent.close()
        endpoint.close()
        channel.close()
