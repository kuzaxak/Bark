# Licensed under GPL-3.0. See LICENSE.
"""Coordinate Bark app and Chromium test runs on the same idle macOS console."""

import contextlib
import ctypes
import os
from pathlib import Path
import stat
import time


SCREEN_LOCK = Path("/private/tmp/nook-screen-lock")
SCREEN_UNAVAILABLE = 3


class ScreenUnavailable(Exception):
    pass


def directory_identity(info):
    return info.st_dev, info.st_ino


@contextlib.contextmanager
def screen_lock(path, wait):
    deadline = time.monotonic() + wait
    while True:
        try:
            path.mkdir(mode=0o700)
            break
        except FileExistsError:
            if time.monotonic() >= deadline:
                raise ScreenUnavailable(f"Screen mutex is already held at {path}")
            time.sleep(min(0.5, max(0, deadline - time.monotonic())))

    directory = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    identity = directory_identity(os.fstat(directory))

    def owned():
        try:
            current = path.lstat()
        except FileNotFoundError:
            return False
        return stat.S_ISDIR(current.st_mode) and directory_identity(current) == identity

    owner = None
    try:
        owner = os.open(
            "pid", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600, dir_fd=directory,
        )
        with os.fdopen(owner, "w") as record:
            record.write(f"{os.getpid()}\n")
        yield owned
    finally:
        try:
            if owner is not None:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink("pid", dir_fd=directory)
            if owned():
                with contextlib.suppress(FileNotFoundError):
                    path.rmdir()
        finally:
            os.close(directory)


class QuartzConsole:
    class Point(ctypes.Structure):
        _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]

    def __init__(self):
        core = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        quartz = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        self.core = ctypes.CDLL(core)
        self.quartz = ctypes.CDLL(quartz)

        ptr = ctypes.c_void_p
        self.core.CFRelease.argtypes = [ptr]
        self.core.CFRelease.restype = None
        self.core.CFStringCreateWithCString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_uint32]
        self.core.CFStringCreateWithCString.restype = ptr
        self.core.CFDictionaryGetValue.argtypes = [ptr, ptr]
        self.core.CFDictionaryGetValue.restype = ptr
        self.core.CFBooleanGetValue.argtypes = [ptr]
        self.core.CFBooleanGetValue.restype = ctypes.c_bool
        self.quartz.CGSessionCopyCurrentDictionary.argtypes = []
        self.quartz.CGSessionCopyCurrentDictionary.restype = ptr
        self.quartz.CGEventSourceSecondsSinceLastEventType.argtypes = [
            ctypes.c_int32, ctypes.c_uint32,
        ]
        self.quartz.CGEventSourceSecondsSinceLastEventType.restype = ctypes.c_double
        self.quartz.CGEventCreate.argtypes = [ptr]
        self.quartz.CGEventCreate.restype = ptr
        self.quartz.CGEventGetLocation.argtypes = [ptr]
        self.quartz.CGEventGetLocation.restype = self.Point

    def session_flag(self, session, name):
        utf8 = 0x08000100
        key = self.core.CFStringCreateWithCString(None, name, utf8)
        try:
            value = self.core.CFDictionaryGetValue(session, key)
            return bool(value and self.core.CFBooleanGetValue(value))
        finally:
            self.core.CFRelease(key)

    def available(self):
        session = self.quartz.CGSessionCopyCurrentDictionary()
        if not session:
            return False
        try:
            return (
                self.session_flag(session, b"kCGSSessionOnConsoleKey")
                and self.session_flag(session, b"kCGSessionLoginDoneKey")
                and not self.session_flag(session, b"CGSSessionScreenIsLocked")
            )
        finally:
            self.core.CFRelease(session)

    def pointer(self):
        event = self.quartz.CGEventCreate(None)
        if not event:
            raise ScreenUnavailable("Quartz pointer is unavailable")
        try:
            point = self.quartz.CGEventGetLocation(event)
            return point.x, point.y
        finally:
            self.core.CFRelease(event)

    def idle(self):
        hid_system_state = 1
        any_event = 0xffffffff
        return self.quartz.CGEventSourceSecondsSinceLastEventType(
            hid_system_state, any_event
        )


def require_idle_console(console, owns_screen, pointer, min_idle):
    if not owns_screen():
        raise ScreenUnavailable("Screen mutex ownership changed")
    if not console.available():
        raise ScreenUnavailable("The Mac console is locked or unavailable")
    if console.pointer() != pointer or console.idle() < min_idle:
        raise ScreenUnavailable("The user is active on the Mac console")


def interrupted(_signal, _frame):
    raise KeyboardInterrupt
