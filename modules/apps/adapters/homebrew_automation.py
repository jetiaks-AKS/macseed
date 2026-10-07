"""Read-only login-item observation through public Apple Event / OSA APIs.

Permission is checked without prompting before compiling or executing a script.
The check and Apple Events have the same sender process; there is no osascript
identity handoff. Consent is requested only by an explicit Desktop action.
"""
import ctypes as C


class AutomationUnavailable(Exception):
    def __init__(self, condition, authorization=False):
        self.condition, self.authorization = condition, authorization


def fourcc(value):
    return int.from_bytes(value.encode('ascii'), 'big')


class Descriptor(C.Structure):
    _fields_ = [('type', C.c_uint32), ('handle', C.c_void_p)]


class AppleEvents:
    def __init__(self):
        self.api = C.CDLL('/System/Library/Frameworks/Carbon.framework/Carbon')
        descriptor = C.POINTER(Descriptor)
        signatures = {
            'AECreateDesc': (C.c_int16, [C.c_uint32, C.c_void_p, C.c_long, descriptor]),
            'AEDisposeDesc': (C.c_int16, [descriptor]),
            'AEGetDescDataSize': (C.c_long, [descriptor]),
            'AEGetDescData': (C.c_int16, [descriptor, C.c_void_p, C.c_long]),
            'AEDeterminePermissionToAutomateTarget': (C.c_int32, [descriptor, C.c_uint32, C.c_uint32, C.c_ubyte]),
            'OpenDefaultComponent': (C.c_void_p, [C.c_uint32, C.c_uint32]),
            'CloseComponent': (C.c_int16, [C.c_void_p]),
            'OSACompile': (C.c_int32, [C.c_void_p, descriptor, C.c_int32, C.POINTER(C.c_uint32)]),
            'OSAExecute': (C.c_int32, [C.c_void_p, C.c_uint32, C.c_uint32, C.c_int32, C.POINTER(C.c_uint32)]),
            'OSACoerceToDesc': (C.c_int32, [C.c_void_p, C.c_uint32, C.c_uint32, C.c_int32, descriptor]),
            'OSAScriptError': (C.c_int32, [C.c_void_p, C.c_uint32, C.c_uint32, descriptor]),
            'OSADispose': (C.c_int32, [C.c_void_p, C.c_uint32]),
        }
        for name, (returns, arguments) in signatures.items():
            function = getattr(self.api, name)
            function.restype, function.argtypes = returns, arguments

    def descriptor(self, kind, data):
        value = Descriptor()
        self.check(self.api.AECreateDesc(fourcc(kind), data, len(data), C.byref(value)))
        return value

    @staticmethod
    def check(status):
        if status:
            condition = {-1743: 'authorization_denied', -1744: 'authorization_required',
                         -600: 'application_unavailable'}.get(status, 'observation_failed')
            raise AutomationUnavailable(condition, status in (-1743, -1744))

    def permission(self):
        target = self.descriptor('bund', b'com.apple.systemevents')
        try:
            self.check(self.api.AEDeterminePermissionToAutomateTarget(
                C.byref(target), fourcc('core'), fourcc('getd'), False))
        finally:
            self.api.AEDisposeDesc(C.byref(target))

    def data(self, descriptor):
        size = self.api.AEGetDescDataSize(C.byref(descriptor))
        if not 0 <= size <= 1024 * 1024:
            raise AutomationUnavailable('malformed_observation')
        buffer = C.create_string_buffer(size)
        self.check(self.api.AEGetDescData(C.byref(descriptor), buffer, size))
        return buffer.raw

    def evaluate(self, script):
        component = self.api.OpenDefaultComponent(fourcc('osa '), fourcc('ascr'))
        if not component:
            raise AutomationUnavailable('application_unavailable')
        source, output = Descriptor(), Descriptor()
        compiled, value = C.c_uint32(), C.c_uint32()
        try:
            source = self.descriptor('utf8', script.encode('utf-8'))
            self.check(self.api.OSACompile(component, C.byref(source), 0x10, C.byref(compiled)))
            status = self.api.OSAExecute(component, compiled.value, 0, 0x10, C.byref(value))
            if status:
                error = Descriptor()
                try:
                    if self.api.OSAScriptError(component, fourcc('errn'), fourcc('long'), C.byref(error)) == 0:
                        raw = self.data(error)
                        if len(raw) == 4:
                            self.check(C.c_int32.from_buffer_copy(raw).value)
                finally:
                    self.api.AEDisposeDesc(C.byref(error))
                self.check(status)
            self.check(self.api.OSACoerceToDesc(component, value.value, fourcc('utf8'), 0, C.byref(output)))
            return self.data(output).decode('utf-8')
        finally:
            self.api.AEDisposeDesc(C.byref(source))
            self.api.AEDisposeDesc(C.byref(output))
            for identifier in (compiled.value, value.value):
                if identifier:
                    self.api.OSADispose(component, identifier)
            self.api.CloseComponent(component)


SCRIPT = '''with timeout of 15 seconds
    tell application "System Events"
        set pairs to {}
        repeat with x in login items
            set itemName to name of x
            set itemPath to path of x
            if itemPath is missing value or itemPath is "missing value" then
                set end of pairs to itemName & tab & "missing" & tab & "-"
            else
                set end of pairs to itemName & tab & "present" & tab & itemPath
            end if
        end repeat
        set AppleScript's text item delimiters to linefeed
        return pairs as text
    end tell
end timeout'''


def login_items():
    try:
        events = AppleEvents()
        events.permission()
        raw = events.evaluate(SCRIPT)
        pairs = []
        for line in raw.splitlines():
            fields = line.split('\t')
            if len(fields) != 3 or fields[1] not in ('missing', 'present') or (fields[1] == 'missing' and fields[2] != '-'):
                raise AutomationUnavailable('malformed_observation')
            pairs.append((fields[0], None if fields[1] == 'missing' else fields[2]))
        return pairs
    except (OSError, ValueError, AttributeError, UnicodeError):
        raise AutomationUnavailable('observation_failed') from None
