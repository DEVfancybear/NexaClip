"""Drive the test-only Windows fixture; never read or modify the clipboard.

Build the fixture with CLOSE_TEST_DIRECTORY set to an empty temporary directory,
then pass the built executable and that directory as arguments.
"""
import ctypes
from ctypes import wintypes
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

exe, directory = Path(sys.argv[1]), Path(sys.argv[2])
user = ctypes.WinDLL('user32', use_last_error=True)
callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
user.EnumWindows.restype = wintypes.BOOL
user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user.PostMessageW.restype = wintypes.BOOL


def wait_for(predicate, process, description, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'Process exited before {description}: {process.returncode}')
        result = predicate()
        if result:
            return result
        time.sleep(0.05)
    raise TimeoutError(description)


def find_window(pid):
    found = []
    @callback_type
    def visit(hwnd, _):
        owner = wintypes.DWORD()
        user.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        name = ctypes.create_unicode_buffer(256)
        user.GetClassNameW(hwnd, name, len(name))
        if owner.value == pid and name.value == 'FLUTTER_RUNNER_WIN32_WINDOW':
            found.append(hwnd)
        return True
    if not user.EnumWindows(visit, 0):
        raise ctypes.WinError(ctypes.get_last_error())
    return found[0] if len(found) == 1 else None


if any(directory.iterdir()):
    raise RuntimeError('Fixture directory must be empty')
process = subprocess.Popen([str(exe.resolve())], cwd=exe.resolve().parent)
try:
    wait_for(lambda: (directory / 'write_started').exists(), process, 'pending write')
    if not (directory / 'mock_start').is_file():
        raise AssertionError('Start did not reach the mock channel')
    hwnd = wait_for(lambda: find_window(process.pid), process, 'fixture window')
    if not user.PostMessageW(hwnd, 0x0010, 0, 0):  # WM_CLOSE
        raise ctypes.WinError(ctypes.get_last_error())
    wait_for(lambda: (directory / 'exit_started').exists(), process, 'exit request')
    wait_for(lambda: (directory / 'mock_stop').is_file(), process, 'mock stop')
    with sqlite3.connect(directory / 'history.db') as db:
        count = db.execute('SELECT count(*) FROM text_history').fetchone()[0]
        if count != 0:
            raise AssertionError('Write committed before release')
    (directory / 'release').write_text('release', encoding='utf-8')
    code = process.wait(timeout=30)
    if code != 0:
        raise RuntimeError(f'Fixture exited with code {code}')
    with sqlite3.connect(directory / 'history.db') as db:
        values = db.execute('SELECT text FROM text_history').fetchall()
        if values != [('NexaClip-close-pending-synthetic',)]:
            raise AssertionError('Synthetic write was not committed exactly once')
    print('PASS: WM_CLOSE waited for the synthetic pending write')
finally:
    if process.poll() is None:
        process.kill()
        process.wait(timeout=10)
