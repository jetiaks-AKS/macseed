"""Transient application input for the existing SSH importer; no secret storage."""
import errno
import json
import os
import pty
import select
import socket
import signal
import tempfile
import struct
import subprocess
import termios
import time
import uuid

MAX_FRAME = 2048
MAX_SECRET = 128  # Fits the smallest supported terminal canonical input limit.
WAIT_SECONDS = 120
TOOL_SECONDS = 30
KINDS = {'bundle_unlock', 'ssh_key_unlock', 'import_confirmation'}


class SecureError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


class PrivateTemporaryDirectory(tempfile.TemporaryDirectory):
    """Do not let cancellation interrupt removal of the importer's own staging."""
    def __exit__(self, *arguments):
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        try:
            return super().__exit__(*arguments)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def inherited_socket(fd):
    if fd <= 2:
        raise ValueError('descriptor')
    channel = socket.socket(fileno=fd)
    try:
        if channel.family != socket.AF_UNIX or channel.type != socket.SOCK_STREAM:
            raise ValueError('descriptor')
        if channel.getsockname() or channel.getpeername():
            raise ValueError('named channel')
        os.set_inheritable(fd, False)
        channel.setblocking(False)
        return channel
    except BaseException:
        channel.close()
        raise


def receive(channel, deadline):
    def exact(size):
        data = bytearray()
        while len(data) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SecureError('secure_channel_timeout')
            if not select.select([channel], [], [], remaining)[0]:
                raise SecureError('secure_channel_timeout')
            try:
                chunk = channel.recv(size - len(data))
            except ConnectionResetError:
                raise SecureError('secure_cancelled') from None
            if not chunk:
                raise SecureError('secure_cancelled')
            data.extend(chunk)
        return bytes(data)
    size = struct.unpack('!I', exact(4))[0]
    if not 0 < size <= MAX_FRAME:
        raise SecureError('secure_channel_invalid')
    return exact(size)


def send(channel, body):
    if not 0 < len(body) <= MAX_FRAME:
        raise SecureError('secure_channel_invalid')
    data = memoryview(struct.pack('!I', len(body)) + body)
    deadline = time.monotonic() + WAIT_SECONDS
    try:
        while data:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([], [channel], [], remaining)[1]:
                raise SecureError('secure_channel_timeout')
            written = channel.send(data)
            if not written:
                raise SecureError('secure_cancelled')
            data = data[written:]
    except (BrokenPipeError, ConnectionResetError):
        raise SecureError('secure_cancelled') from None


def metadata(channel, value):
    send(channel, json.dumps(value, separators=(',', ':')).encode('ascii'))


def response(body, challenge):
    # Binary: 16-byte challenge nonce, one-byte action, optional UTF-8 secret.
    if len(body) < 17 or body[:16] != bytes.fromhex(challenge['challenge_id']):
        raise SecureError('secure_channel_invalid')
    action, secret = body[16:17], body[17:]
    if action == b'C' and not secret:
        raise SecureError('secure_cancelled')
    if challenge['kind'] == 'import_confirmation':
        if action != b'Y' or secret:
            raise SecureError('secure_channel_invalid')
        return b''
    if action != b'S' or not 1 <= len(secret) <= MAX_SECRET:
        raise SecureError('secure_channel_invalid')
    try:
        decoded = secret.decode('utf-8')
    except UnicodeError:
        raise SecureError('secure_channel_invalid') from None
    if any(ord(c) < 32 or ord(c) == 127 for c in decoded):
        raise SecureError('secure_channel_invalid')
    return secret


class Input:
    def __init__(self, fd, operation_id):
        self.channel = inherited_socket(fd)
        self.operation_id = operation_id

    def ask(self, kind, attempt=1):
        challenge = dict(type='challenge', protocol_version=1,
                         operation_id=self.operation_id, challenge_id=uuid.uuid4().hex,
                         kind=kind, attempt=attempt)
        metadata(self.channel, challenge)
        return response(receive(self.channel, time.monotonic() + WAIT_SECONDS), challenge)

    def mutation(self):
        metadata(self.channel, {'type': 'mutation'})
        if receive(self.channel, time.monotonic() + WAIT_SECONDS) != b'ACK':
            raise SecureError('secure_channel_invalid')

    def finish(self, code):
        metadata(self.channel, {'type': 'finish', 'code': code})
        self.channel.close()


def tool(command, secret, stdout=None, pass_fds=()):
    """Only this child sees the PTY. No controlling terminal, no prompt forwarding."""
    master, slave = pty.openpty()
    child = None
    output = bytearray()
    diagnostic = bytearray()
    try:
        hidden = termios.tcgetattr(slave)
        hidden[3] &= ~(termios.ECHO | termios.ECHONL)
        termios.tcsetattr(slave, termios.TCSANOW, hidden)
        environment = dict(os.environ, SSH_ASKPASS_REQUIRE='never')
        environment.pop('SSH_ASKPASS', None)
        environment.pop('DISPLAY', None)
        environment.pop('WAYLAND_DISPLAY', None)
        child = subprocess.Popen(command, stdin=slave, stderr=slave,
                                 stdout=stdout if stdout is not None else subprocess.PIPE,
                                 env=environment, pass_fds=pass_fds)
        os.close(slave)
        slave = None
        streams = [master]
        if child.stdout is not None:
            streams.append(child.stdout.fileno())
        sent = False
        deadline = time.monotonic() + TOOL_SECONDS
        while streams:
            if time.monotonic() >= deadline:
                raise SecureError('secure_tool_failed')
            readable = select.select(streams, [], [], min(.1, deadline - time.monotonic()))[0]
            for fd in readable:
                try:
                    chunk = os.read(fd, 4096)
                except OSError as exc:
                    if fd == master and exc.errno == errno.EIO:
                        chunk = b''
                    else:
                        raise
                if not chunk:
                    streams.remove(fd)
                    continue
                target = diagnostic if fd == master else output
                target.extend(chunk)
                if len(target) > 65536:
                    raise SecureError('secure_tool_failed')
                if fd == master and not sent and b': ' in diagnostic:
                    # Write only after the tool installs its terminal input mode.
                    os.write(master, secret + b'\n')
                    sent = True
        return child.wait(timeout=1), bytes(output), bytes(diagnostic)
    finally:
        if child is not None:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            if child.stdout is not None:
                child.stdout.close()
        if slave is not None:
            os.close(slave)
        os.close(master)


def key_public(path, interaction):
    environment = dict(os.environ, SSH_ASKPASS_REQUIRE='never')
    environment.pop('SSH_ASKPASS', None)
    environment.pop('DISPLAY', None)
    environment.pop('WAYLAND_DISPLAY', None)
    try:
        probe = subprocess.run(['ssh-keygen', '-y', '-f', path], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
                               timeout=TOOL_SECONDS)
    except subprocess.TimeoutExpired:
        raise SecureError('secure_tool_failed') from None
    if probe.returncode == 0:
        return probe.stdout
    if b'incorrect passphrase' not in probe.stderr:
        raise SecureError('secure_payload_invalid')
    for attempt in range(1, 4):
        secret = interaction.ask('ssh_key_unlock', attempt)
        try:
            status, public, diagnostic = tool(['ssh-keygen', '-y', '-f', path], secret)
        finally:
            del secret
        if status == 0:
            return public
        if b'incorrect passphrase' not in diagnostic:
            raise SecureError('secure_payload_invalid')
    raise SecureError('secure_key_unlock_rejected')


def decrypt(input_fd, out, interaction):
    for attempt in range(1, 4):
        secret = interaction.ask('bundle_unlock', attempt)
        os.lseek(input_fd, 0, os.SEEK_SET)
        out.seek(0)
        out.truncate()
        try:
            status, _, diagnostic = tool(['age', '-d', '/dev/fd/' + str(input_fd)],
                                         secret, stdout=out, pass_fds=(input_fd,))
        finally:
            del secret
        if status == 0:
            return
        if b'incorrect passphrase' not in diagnostic and b'failed to decrypt' not in diagnostic:
            raise SecureError('secure_tool_failed')
    raise SecureError('secure_unlock_rejected')
