import ctypes
import sys
import time
from ctypes import wintypes

user = ctypes.WinDLL('user32', use_last_error=True)
kernel = ctypes.WinDLL('kernel32', use_last_error=True)
user.GetDesktopWindow.restype = wintypes.HWND
user.OpenClipboard.argtypes = [wintypes.HWND]
user.RegisterClipboardFormatW.argtypes = [wintypes.LPCWSTR]
user.RegisterClipboardFormatW.restype = wintypes.UINT
user.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
user.SetClipboardData.restype = wintypes.HANDLE
kernel.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
kernel.GlobalAlloc.restype = wintypes.HANDLE
kernel.GlobalLock.argtypes = [wintypes.HANDLE]
kernel.GlobalLock.restype = ctypes.c_void_p
kernel.GlobalUnlock.argtypes = [wintypes.HANDLE]
kernel.GlobalFree.argtypes = [wintypes.HANDLE]


def put(fmt, data):
    handle = kernel.GlobalAlloc(2, len(data))
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    address = kernel.GlobalLock(handle)
    if not address:
        kernel.GlobalFree(handle)
        raise ctypes.WinError(ctypes.get_last_error())
    ctypes.memmove(address, data, len(data))
    kernel.GlobalUnlock(handle)
    if not user.SetClipboardData(fmt, handle):
        kernel.GlobalFree(handle)
        raise ctypes.WinError(ctypes.get_last_error())


kind = sys.argv[1]
text = {'normal': 'NexaClip-test-unicode-đ-😀', 'long': 'NexaClip-long-' + 'x' * 40000,
        'exclude': 'NexaClip-private-exclude', 'zero': 'NexaClip-private-zero',
        'both': 'NexaClip-private-both', 'sentinel-both': 'NexaClip-sentinel-both',
        'sentinel-exclude': 'NexaClip-sentinel-exclude', 'sentinel-zero': 'NexaClip-sentinel-zero',
        'one': 'NexaClip-allowed-one', 'stopped': 'NexaClip-stopped',
        'restart': 'NexaClip-restarted'}[kind]
for attempt in range(20):
    if user.OpenClipboard(user.GetDesktopWindow()):
        break
    if attempt == 19:
        raise ctypes.WinError(ctypes.get_last_error())
    time.sleep(0.05)
try:
    if not user.EmptyClipboard():
        raise ctypes.WinError(ctypes.get_last_error())
    put(13, (text + '\0').encode('utf-16-le'))
    if kind == 'both':
        for marker in ('ExcludeClipboardContentFromMonitorProcessing', 'CanIncludeInClipboardHistory'):
            fmt = user.RegisterClipboardFormatW(marker)
            if not fmt:
                raise ctypes.WinError(ctypes.get_last_error())
            put(fmt, (1).to_bytes(4, 'little'))
    if kind in ('exclude', 'zero', 'one'):
        marker = 'ExcludeClipboardContentFromMonitorProcessing' if kind == 'exclude' else 'CanIncludeInClipboardHistory'
        fmt = user.RegisterClipboardFormatW(marker)
        if not fmt:
            raise ctypes.WinError(ctypes.get_last_error())
        put(fmt, (0 if kind in ('exclude', 'zero') else 1).to_bytes(4, 'little'))
finally:
    user.CloseClipboard()
