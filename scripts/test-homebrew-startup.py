#!/usr/bin/env python3
"""Focused real Debug-app startup gate. Never installs or changes host Homebrew.

The DEBUG-only driver invokes the app's native accessibility actions. Browser,
clipboard and Terminal side effects are injected and recorded, not executed.
Screenshots capture only the owned application's window IDs. Run serially in an
unlocked macOS GUI session after building Debug; no build or CI is triggered here.
"""
import json
import ctypes
from pathlib import Path
import subprocess
import time
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'desktop/Macseed/build/Debug/Macseed.app'
OUTPUT = ROOT / 'desktop/Macseed/build/Debug/HomebrewStartup'
OUTPUT.mkdir(parents=True, exist_ok=True)
SUITE = 'org.macseed.homebrew-test.native.' + str(uuid.uuid4())
REPORT = []
LIMITATIONS = []
LIVE = []


def write(path, value):
    temporary = path.with_suffix('.next')
    temporary.write_text(json.dumps(value))
    temporary.replace(path)


class Launch:
    def __init__(self, name, state='absent', **values):
        self.directory = OUTPUT / name
        self.directory.mkdir(mode=0o700, exist_ok=True)
        self.directory.chmod(0o700)
        for path in ['state.json', 'command.json', 'trace.json']:
            (self.directory / path).unlink(missing_ok=True)
        write(self.directory / 'config.json', dict(suite=SUITE, state=state, **values))
        self.process = subprocess.Popen(['/usr/bin/open', '-n', '-W', str(APP), '--args', '--homebrew-setup-test', str(self.directory / 'config.json')])
        LIVE.append(self)
        self.wait(lambda row: bool(row['windows']), 'initial native window')

    def state(self):
        try:
            return json.loads((self.directory / 'state.json').read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    def wait(self, condition, label, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            row = self.state()
            if row and condition(row):
                return row
            time.sleep(.05)
        raise AssertionError(f'{self.directory.name}: {label}: {self.state()}')

    def command(self, action, value=None):
        token = str(uuid.uuid4())
        write(self.directory / 'command.json', dict(id=token, action=action, value=value or ''))
        return self.wait(lambda row: row['command'] == token, action)

    def ax(self, identifier, press=False):
        # Public macOS accessibility actions, scoped to the one owned Debug app.
        source = r'''tell application "System Events"
            set apps to every application process whose bundle identifier is "org.macseed.desktop"
            if (count of apps) is not 1 then error "Expected one isolated Macseed test app"
            tell item 1 of apps
                set frontmost to true
                repeat with win in windows
                    set children to entire contents of win
                    repeat with child in children
                        set element to contents of child
                        try
                            set identifier to get value of attribute "AXIdentifier" of element
                            if identifier is "IDENTIFIER" then
                                ACTION
                                return "found"
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            return "not found"
        end tell'''
        source = source.replace('IDENTIFIER', identifier).replace('ACTION', 'perform action "AXPress" of element' if press else 'get role of element')
        result = subprocess.run(['/usr/bin/osascript', '-e', source], text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        return result.stdout.strip()

    def press(self, name):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.ax('homebrew.' + name, press=True) == 'found':
                return self.state()
            time.sleep(.1)
        raise AssertionError('Native accessibility control not found: ' + name)

    def elements(self, title):
        source = '''tell application "System Events" to tell application process "Macseed"
            set win to window "WINDOW_TITLE"
            set output to ""
            set children to {win} & (entire contents of win)
            repeat with child in children
                set element to contents of child
                try
                    set identifier to ""
                    try
                        set identifier to value of attribute "AXIdentifier" of element
                    end try
                    set elementRole to role of element
                    if elementRole is "AXWindow" then set identifier to "window"
                    if identifier starts with "homebrew." or elementRole is "AXStaticText" or elementRole is "AXWindow" then
                        set labelText to ""
                        try
                            if elementRole is "AXStaticText" then
                                set labelText to value of element as text
                            else
                                set labelText to description of element as text
                            end if
                        end try
                        set pos to position of element
                        set extent to size of element
                        set output to output & identifier & tab & labelText & tab & elementRole & tab & (item 1 of pos) & tab & (item 2 of pos) & tab & (item 1 of extent) & tab & (item 2 of extent) & linefeed
                    end if
                end try
            end repeat
            return output
        end tell'''.replace('WINDOW_TITLE', title)
        output = subprocess.check_output(['/usr/bin/osascript', '-e', source], text=True)
        rows = []
        for line in output.splitlines():
            fields = line.split('\t')
            if len(fields) == 7:
                rows.append(dict(id=fields[0], label=fields[1], role=fields[2],
                                 frame=dict(zip(['x', 'y', 'width', 'height'], map(float, fields[3:])))))
        return rows

    def key(self, code):
        assert code in [48, 49, 36, 53]
        pid = subprocess.check_output(['/usr/bin/osascript', '-e',
            '''tell application "System Events"
                set apps to every application process whose bundle identifier is "org.macseed.desktop"
                if (count of apps) is not 1 then error "Expected one isolated Macseed test app"
                set frontmost of item 1 of apps to true
                return unix id of item 1 of apps
            end tell'''], text=True).strip()
        assert pid.isdigit(), 'Expected exactly one owned test app'
        graphics = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        foundation = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        graphics.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
        graphics.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
        graphics.CGEventPostToPid.argtypes = [ctypes.c_int, ctypes.c_void_p]
        foundation.CFRelease.argtypes = [ctypes.c_void_p]
        for down in [True, False]:
            event = graphics.CGEventCreateKeyboardEvent(None, code, down)
            assert event
            graphics.CGEventPostToPid(int(pid), event)
            foundation.CFRelease(event)
            time.sleep(.05)

    def focused_identifier(self):
        source = '''tell application "System Events" to tell application process "Macseed"
            set focusedElement to value of attribute "AXFocusedUIElement"
            try
                return value of attribute "AXIdentifier" of focusedElement
            on error
                return role of focusedElement
            end try
        end tell'''
        return subprocess.check_output(['/usr/bin/osascript', '-e', source], text=True).strip()

    def focus(self):
        source = '''tell application "System Events" to tell application process "Macseed"
            set focusedElement to value of attribute "AXFocusedUIElement"
            return role of focusedElement
        end tell'''
        result = subprocess.run(['/usr/bin/osascript', '-e', source], text=True, capture_output=True, check=True)
        return result.stdout.strip()

    def setup(self):
        row = self.wait(lambda row: len(row['windows']) == 1 and row['windows'][0]['title'] == 'Set Up Homebrew' and row['windows'][0]['key'] and row['active'], 'focused setup only')
        assert row['homeWindowsCreated'] == 0, row
        row = self.wait(lambda row: not row['windows'][0]['occluded'], 'visible GUI session')
        return row

    def home(self):
        row = self.wait(lambda row: any(window['title'] == 'Macseed' for window in row['windows']) and not any(window['title'] == 'Set Up Homebrew' for window in row['windows']), 'Home without setup')
        return row

    def screenshot(self, name, title):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            row = self.wait(lambda row: any(window['title'] == title for window in row['windows']), 'screenshot window')
            window = next(window for window in row['windows'] if window['title'] == title)
            result = subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l' + str(window['id']), str(OUTPUT / (name + '.png'))], capture_output=True)
            if result.returncode == 0:
                return
            time.sleep(.1)
        raise AssertionError('Window capture did not become available: ' + title)

    def close(self, cleanup=False):
        if cleanup:
            self.command('cleanup')
        self.wait(lambda row: not row['coreActive'], 'read-only Core completion')
        write(self.directory / 'command.json', dict(id=str(uuid.uuid4()), action='quit'))
        self.process.wait(timeout=10)
        LIVE.remove(self)


def record(message):
    REPORT.append(message)
    if message.startswith('LIMITATION:'):
        LIMITATIONS.append(message)
    report_name = 'package-report.json' if '--package-only' in sys.argv else 'ux-polish-report.json' if '--ux-polish-only' in sys.argv else 'keyboard-report.json' if '--keyboard-only' in sys.argv else 'report.json'
    (OUTPUT / report_name).write_text(json.dumps(REPORT, indent=2))
    print('UNQUALIFIED:' if message.startswith('LIMITATION:') else 'PASS:', message, flush=True)


def keyboard_only():
    # Enable macOS Keyboard Navigation before this explicit check. This runner
    # never changes the system preference; use a suitable test session.
    app = Launch('keyboard-enabled', reminders=True)
    app.setup()
    seen = []
    for _ in range(12):
        app.key(48)
        identifier = app.focused_identifier()
        seen.append(identifier)
        if identifier == 'homebrew.check':
            break
    assert {'homebrew.suppress', 'homebrew.notNow', 'homebrew.check'} <= set(seen), seen
    app.command('state', 'usable')
    app.key(36)
    assert app.home()['status'] == 'Available'
    (OUTPUT / 'keyboard-result.json').write_text(json.dumps(dict(tab_controls=seen, return_rechecks=True), indent=2))
    app.close(cleanup=True)
    record('Native keyboard: Tab traverses checkbox and buttons; Return runs Check Again, verifies usable and opens Home')


def ux_polish_only():
    def window(app, title):
        row = app.wait(lambda row: sum(w['title'] == title for w in row['windows']) == 1
                       and any(w['title'] == title and w['key'] and not w['occluded'] for w in row['windows']), title + ' focused')
        win = next(w for w in row['windows'] if w['title'] == title)
        win['elements'] = app.elements(title)
        win['setupText'] = [e['label'] for e in win['elements'] if e['role'] == 'AXStaticText']
        return win

    def layout(app, expected=(), hidden=(), manual=False):
        # Let the native scene settle its content-driven size before checking AX frames.
        time.sleep(.35)
        win = window(app, 'Set Up Homebrew')
        ids = {element['id'] for element in win['elements']}
        assert set('homebrew.' + name for name in expected) <= ids, (expected, ids)
        assert not set('homebrew.' + name for name in hidden) & ids, (hidden, ids)
        assert ('homebrew.suppress' in ids) != manual, ids
        assert win['setupText'].count('Set Up Homebrew') == 1, win['setupText']  # Native title only.
        content = dict(win['contentFrame'])
        native = next(e['frame'] for e in win['elements'] if e['id'] == 'window')
        # Public AX uses a top-left screen origin; AppKit uses bottom-left.
        content['x'] = native['x']
        content['y'] = native['y'] + native['height'] - content['height']
        assert 650 <= content['width'] <= 750, content
        for element in win['elements']:
            if element['id'] == 'window':
                continue
            frame = element['frame']
            if element['label'] == 'Set Up Homebrew' and frame['y'] < content['y']:
                continue  # Standard native title bar, outside content.
            assert frame['width'] > 0 and frame['height'] > 0, element
            for origin, extent in [('x', 'width'), ('y', 'height')]:
                assert frame[origin] >= content[origin] - 1 and frame[origin] + frame[extent] <= content[origin] + content[extent] + 1, (element, content)
        return content['height']

    def settings(app):
        assert app.command('settings')['commandResult'] == 'opened'
        return window(app, 'General')

    app = Launch('polish-missing', reminders=True, macOS=27)
    app.setup()
    for appearance in ['light', 'dark']:
        app.command('appearance', appearance)
        initial = layout(app, ['warning', 'packageMethod', 'terminalMethod'], ['command', 'package', 'packageState'])
        assert initial < 400
        app.screenshot('polish-01-missing-' + appearance, 'Set Up Homebrew')
        app.press('terminalMethod')
        terminal = layout(app, ['command', 'copy', 'openTerminal', 'terminalInstructions'], ['package', 'packageState'])
        assert initial < terminal < 550
        app.screenshot('polish-02-terminal-' + appearance, 'Set Up Homebrew')
        app.press('copy'); app.wait(lambda row: any(a.startswith('copy:') for a in row['actions']), 'Copy Command intent')
        app.press('openTerminal'); app.wait(lambda row: 'terminal' in row['actions'], 'Open Terminal intent')
        app.press('packageMethod')
        package = layout(app, ['package', 'packageState'], ['command', 'copy', 'openTerminal', 'terminalInstructions'])
        assert initial < package < 600
        assert not any('Command copied' in text or 'Terminal opened' in text for text in window(app, 'Set Up Homebrew')['setupText'])
        app.screenshot('polish-03-installer-' + appearance, 'Set Up Homebrew')
        app.press('package'); app.wait(lambda row: any(a.startswith('page:') for a in row['actions']), 'official-page intent')
        app.press('terminalMethod')
        layout(app, ['command'], ['package', 'packageState'])
        assert not any('Download Homebrew.pkg' in text for text in window(app, 'Set Up Homebrew')['setupText'])
        # Finish this launch and reopen a fresh automatic session for the other appearance.
        if appearance == 'light':
            app.press('notNow'); assert app.home()['reminders']
            app.close()
            app = Launch('polish-missing-dark', reminders=True, appearance='dark', macOS=27)
            app.setup()
    record('Actual Debug setup: 700pt compact initial scene before Home; no duplicate heading; exclusive Installer/Terminal content and feedback; native height expands/contracts; all tagged controls inside content in Light/Dark')
    app.key(48)
    focus = app.focused_identifier()
    if app.focus() == 'AXWindow':
        record('LIMITATION: Tab focus remains on the native window in this GUI session; full keyboard traversal was not requalified')
    else:
        seen = {focus}
        for _ in range(16):
            app.key(48); seen.add(app.focused_identifier())
        assert {'homebrew.suppress', 'homebrew.notNow', 'homebrew.check'} <= seen, seen
        record('Native Tab traversal includes startup reminder and footer controls')
    app.key(53); assert app.home()['reminders']
    # Same-session Home reopening uses the existing native app path.
    subprocess.run(['/usr/bin/osascript', '-e', '''tell application "System Events" to tell application process "Macseed"
        set closeControl to value of attribute "AXCloseButton" of window "Macseed"
        perform action "AXPress" of closeControl
    end tell'''], check=True, stdout=subprocess.DEVNULL)
    app.wait(lambda row: not row['windows'], 'Home closed')
    subprocess.run(['/usr/bin/open', str(APP)], check=True)
    app.home()
    app.command('appearance', 'light')
    win = settings(app)
    assert any(e['id'] == 'homebrew.settingsSetup' for e in win['elements'])
    time.sleep(.35); app.screenshot('polish-06-settings-missing', 'General')
    app.press('settingsCheck'); app.wait(lambda row: row['status'] == 'Not Installed', 'Settings missing Check Again')
    home_ids = {w['id'] for w in app.state()['windows'] if w['title'] == 'Macseed'}
    # Exercise manual close with reminders both enabled and disabled.
    for reminders in [True, False]:
        if not reminders:
            app.press('reminders'); app.wait(lambda row: not row['reminders'], 'disable reminders in Settings')
        app.press('settingsSetup')
        layout(app, ['warning', 'packageMethod'], ['command', 'package'], manual=True)
        app.press('check')
        app.wait(lambda row: row['status'] == 'Not Installed', 'manual missing Check Again')
        app.press('notNow')
        window(app, 'General')
        assert app.state()['reminders'] == reminders
        assert {w['id'] for w in app.state()['windows'] if w['title'] == 'Macseed'} == home_ids
    app.press('settingsSetup')
    for state, status in [('broken', 'Broken'), ('unknown', 'Unknown'), ('usable', 'Available')]:
        app.command('state', state); app.press('check')
        app.wait(lambda row: row['status'] == status, 'manual ' + status)
        layout(app, ['check'], ['warning', 'packageMethod', 'terminalMethod', 'command', 'package'], manual=True)
        assert not app.state()['reminders']
    app.command('close'); window(app, 'General')
    app.press('settingsSetup'); window(app, 'Set Up Homebrew')
    # The scene is reused when requested again while already open.
    setup_id = window(app, 'Set Up Homebrew')['id']
    settings(app); app.press('settingsSetup')
    assert window(app, 'Set Up Homebrew')['id'] == setup_id
    app.command('close'); window(app, 'General')
    assert not app.state()['reminders']
    assert {w['id'] for w in app.state()['windows'] if w['title'] == 'Macseed'} == home_ids
    assert app.state()['coreOperation'] not in ['restore_prepare', 'restore_execute']
    app.close()
    record('Settings Missing → Install and Available → Setup reuse one focused scene; manual Done/native close returns focus to Settings, preserves Home and both reminder values; manual Check Again stays open through Broken/Unknown/Available; no Rebuild')

    app = Launch('polish-check-success', reminders=True)
    app.setup(); app.command('state', 'usable'); app.press('check')
    assert app.home()['status'] == 'Available'
    app.close()
    record('Not Now/Escape → Home; successful automatic Check Again → Home; same-session reopening does not repeat setup')

    app = Launch('polish-real-installed', state='real', reminders=True)
    assert app.home()['status'] == 'Available'
    assert not any(w['title'] == 'Set Up Homebrew' for row in json.loads((app.directory / 'trace.json').read_text()) for w in row['windows'])
    win = settings(app)
    assert any(e['id'] == 'homebrew.settingsSetup' for e in win['elements'])
    time.sleep(.35); app.screenshot('polish-04-settings-available', 'General')
    app.press('settingsCheck'); app.wait(lambda row: row['status'] == 'Available', 'Settings available Check Again')
    app.press('settingsSetup')
    layout(app, ['status', 'check'], ['warning', 'packageMethod', 'terminalMethod'], manual=True)
    app.screenshot('polish-05-manual-available', 'Set Up Homebrew')
    app.press('check'); app.wait(lambda row: row['status'] == 'Available', 'real manual recheck')
    window(app, 'Set Up Homebrew')
    app.press('notNow'); window(app, 'General')
    assert app.state()['reminders']
    app.close(cleanup=True)
    record('Real installed Homebrew: read-only observation → normal Home startup; Available Setup and Check Again remain interactive; healthy manual setup has Done and no missing warning/install actions; six requested views captured')
    if LIMITATIONS:
        raise SystemExit(2)


def package_only():
    def setup_window(app):
        row = app.setup()
        return row['windows'][0]

    def capture(app, name, expected):
        app.wait(lambda row: row['packageState'] == expected, expected or 'initial setup')
        time.sleep(.35)
        win = setup_window(app)
        elements = app.elements('Set Up Homebrew')
        buttons = [next(e for e in elements if e['id'] == 'homebrew.' + identifier)
                   for identifier in ['packageMethod', 'terminalMethod']]
        assert all(e['frame']['width'] >= 640 for e in buttons), buttons
        assert buttons[0]['frame']['y'] + buttons[0]['frame']['height'] < buttons[1]['frame']['y'], buttons
        assert win['contentFrame']['width'] == 700 and win['contentFrame']['height'] < 600
        assert not any('installer:' in action for action in app.state()['actions'])
        app.screenshot(name, 'Set Up Homebrew')

    for appearance in ['light', 'dark']:
        app = Launch('package-' + appearance, appearance=appearance, reminders=True, macOS=27,
                     packagePhase='downloading', packageScenario='verification-failed')
        capture(app, 'package-01-initial-' + appearance, '')
        assert app.ax('homebrew.packageState') == 'not found'
        app.press('packageMethod')
        capture(app, 'package-02-downloading-' + appearance, 'Downloading Homebrew.pkg…')
        assert app.ax('homebrew.cancelDownload') == 'found'
        assert app.ax('homebrew.downloadProgress') == 'found'
        assert app.ax('homebrew.command') == 'not found'
        app.command('packagePhase', 'verifying')
        capture(app, 'package-03-verifying-' + appearance, 'Verifying package…')
        app.command('packagePhase', 'finish')
        capture(app, 'package-04-safe-fallback-' + appearance, 'Verification failed')
        assert app.ax('homebrew.package') == 'found'
        app.press('package'); app.wait(lambda row: any(a.startswith('page:') for a in row['actions']), 'explicit fallback intent')
        app.press('terminalMethod')
        assert app.ax('homebrew.packageState') == 'not found'
        assert app.ax('homebrew.command') == 'found'
        app.screenshot('package-05-terminal-' + appearance, 'Set Up Homebrew')
        app.press('copy'); app.press('openTerminal')
        app.command('packagePhase', 'downloading'); app.press('packageMethod')
        app.wait(lambda row: row['packageState'] == 'Downloading Homebrew.pkg…', 'retry download')
        app.press('cancelDownload'); app.wait(lambda row: row['packageState'] == 'Cancelled', 'cancellation')
        app.press('retryDownload'); app.wait(lambda row: row['packageState'] == 'Downloading Homebrew.pkg…', 'retry after cancellation')
        app.press('terminalMethod'); app.wait(lambda row: row['packageState'] == 'Cancelled', 'Terminal cancels pending pkg handoff')
        assert app.ax('homebrew.command') == 'found' and app.ax('homebrew.packageState') == 'not found'
        app.press('notNow'); assert app.home()['reminders']
        app.close(cleanup=True)
        record('Actual Debug ' + appearance + ': stacked full-width native buttons; responsive download/progress/cancel/retry; verification and safe fallback; independent Terminal; Not Now and reminders preserved. Package/network/launch outcomes are injected; no actual Installer launch')


def main():
    app = Launch('missing-light', reminders=True)
    app.setup()
    assert app.state()['reminders']
    app.screenshot('setup-light', 'Set Up Homebrew')
    app.press('terminalMethod')
    assert app.ax('homebrew.copy') == 'found'
    app.screenshot('setup-methods-light', 'Set Up Homebrew')
    app.press('copy'); app.wait(lambda row: any(action.startswith('copy:/bin/bash -c') for action in row['actions']), 'official command copy')
    app.press('openTerminal'); app.wait(lambda row: 'terminal' in row['actions'], 'Terminal launch intent')
    app.press('packageMethod'); app.press('package'); app.wait(lambda row: 'page:https://github.com/Homebrew/brew/releases/latest' in row['actions'], 'explicit official-page fallback')
    app.press('check'); app.setup()
    app.key(48)
    assert app.setup()['windows'][0]['key']
    focus = app.focus()
    assert focus in ['AXWindow', 'AXGroup', 'AXButton', 'AXCheckBox', 'AXTextArea', 'AXTextField'], focus
    if focus == 'AXWindow':
        record('LIMITATION: Tab leaves focus on the window in this GUI session; full keyboard traversal is not qualified. Escape and native accessibility actions are tested separately')
    else:
        seen = {app.focused_identifier()}
        for _ in range(12):
            if {'homebrew.suppress', 'homebrew.notNow', 'homebrew.check'} <= seen:
                break
            app.key(48); seen.add(app.focused_identifier())
        assert {'homebrew.suppress', 'homebrew.notNow', 'homebrew.check'} <= seen, seen
        record('Native Tab traverses the reminder checkbox and continuation/check buttons')
    record('Missing starts with one visible, key, accessible setup window; no Home exists; both explicit methods, command copy, external-action intents, Check Again stays missing and focus work; Tab traversal qualification is recorded separately')
    app.key(53); row = app.home(); assert row['reminders']
    app.screenshot('home-after-not-now', 'Macseed')
    subprocess.run(['/usr/bin/osascript', '-e', '''tell application "System Events" to tell application process "Macseed"
        set closeControl to value of attribute "AXCloseButton" of window "Macseed"
        perform action "AXPress" of closeControl
    end tell'''], check=True, stdout=subprocess.DEVNULL)
    app.wait(lambda row: not row['windows'], 'Home closed')
    subprocess.run(['/usr/bin/open', str(APP)], check=True)
    app.home()
    record('Closing Home and reopening the app in the same launch does not repeat setup')
    app.close()
    record('Escape activates Not Now unchecked, opens Home and retains reminders')

    app = Launch('missing-dark', appearance='dark')
    app.setup(); app.press('terminalMethod'); app.screenshot('setup-methods-dark', 'Set Up Homebrew')
    app.press('suppress'); app.press('notNow'); assert not app.home()['reminders']
    app.close()
    app = Launch('suppressed')
    assert not app.home()['reminders']
    app.command('settings')
    app.wait(lambda row: any(window['title'] == 'General' for window in row['windows']), 'real General Settings')
    settings = 'General'
    app.screenshot('settings-general', settings)
    app.press('settingsSetup')
    app.wait(lambda row: any(window['title'] == 'Set Up Homebrew' for window in row['windows']), 'shared setup from Settings despite suppression')
    app.press('notNow')
    app.press('reminders'); app.wait(lambda row: row['reminders'], 'Settings re-enables reminders')
    app.close()
    record('Checked Not Now persists suppression across relaunch; Settings opens the shared setup and re-enables reminders; Light/Dark screenshots captured')

    app = Launch('reenabled')
    app.setup(); app.press('suppress'); app.command('close'); assert app.home()['reminders']
    app.close()
    record('Re-enabled reminder offers setup next launch; native close ignores draft checkbox and opens Home')
    app = Launch('verified')
    app.setup(); app.command('state', 'usable'); app.press('check')
    assert app.home()['status'] == 'Available'
    app.close()
    record('Fresh Check Again becoming usable closes setup and opens Home')

    for state in ['usable', 'broken', 'unknown', 'timeout']:
        app = Launch('state-' + state, state=state, reminders=True)
        app.home()
        assert not any(window['title'] == 'Set Up Homebrew' for row in json.loads((app.directory / 'trace.json').read_text()) for window in row['windows'])
        app.close()
    record('Usable, Broken, Unknown and simulated timeout open Home without a missing/setup claim or setup flash')
    for architecture, version in [('appleSilicon', 15), ('appleSilicon', 27), ('appleSilicon', 14), ('intel', 26), ('unknown', 26), ('appleSilicon', 28)]:
        app = Launch(f'platform-{architecture}-{version}', architecture=architecture, macOS=version, reminders=True)
        if architecture == 'appleSilicon' and 15 <= version < 28:
            app.setup(); assert app.state()['canInstall']; app.press('notNow'); app.home()
        else:
            assert not app.home()['canInstall']
        app.close()
    record('Real app with simulated architecture/OS follows upstream 15–27 Apple Silicon policy; Intel, older, unknown and unqualified future versions do not offer installers')

    app = Launch('real-installed', state='real', reminders=True)
    row = app.home()
    assert row['status'] == 'Available', 'Real installed Homebrew must pass native usability checks'
    app.screenshot('home-real-homebrew', 'Macseed')
    app.command('settings')
    app.wait(lambda row: any(window['title'] == 'General' for window in row['windows']), 'real healthy Settings')
    settings = 'General'
    app.screenshot('settings-real-homebrew', settings)
    app.close(cleanup=True)
    record('Real installed Homebrew passes read-only checks; actual Debug startup opens Home without setup; healthy Settings captured; test preferences removed')
    if LIMITATIONS:
        raise SystemExit(2)


if __name__ == '__main__':
    try:
        if '--package-only' in sys.argv:
            package_only()
        elif '--ux-polish-only' in sys.argv:
            ux_polish_only()
        elif '--keyboard-only' in sys.argv:
            keyboard_only()
        else:
            main()
    finally:
        for app in list(LIVE):
            app.close(cleanup=True)
