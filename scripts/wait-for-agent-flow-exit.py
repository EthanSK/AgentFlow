#!/usr/bin/env python3
"""Wait for one verified Agent Flow PID to exit; never poll or terminate it.

A guarded installer first warns and requests normal quit. If the all-session
veto refuses, the persistent "I've finished" button retries normal quit. Darwin
kqueue wakes this waiter only on process exit, after which the installer must
still recheck identity, absence of another app instance, signature and settings.
This is a task-bounded waiter, not a login agent or an updater.
"""
import argparse
import ctypes
from contextlib import closing
import errno
import math
import select

EXECUTABLE = "/Applications/AgentFlow.app/Contents/MacOS/AgentFlow"


def executable_path(pid):
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    lib.proc_pidpath.restype = ctypes.c_int
    result = ctypes.create_string_buffer(4096)
    if lib.proc_pidpath(pid, result, len(result)) <= 0:
        error = ctypes.get_errno()
        if error == errno.ESRCH:
            return None
        raise OSError(error, "Cannot verify the expected process")
    return result.value.decode("utf-8")


def wait_for_exit(pid, timeout):
    if not 1 < pid <= 2_147_483_647 or not math.isfinite(timeout) or not 0 < timeout <= 86400:
        raise ValueError("Invalid process or bounded timeout")
    with closing(select.kqueue()) as queue:
        event = select.kevent(pid, filter=select.KQ_FILTER_PROC,
            flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT,
            fflags=select.KQ_NOTE_EXIT)
        try:
            queue.control([event], 0, 0)
        except ProcessLookupError:
            return  # Exited between identity check and registration.
        # One kernel wait, no kill(0) loop or periodic Accessibility read.
        events = queue.control(None, 1, timeout)
        if not events:
            raise TimeoutError("App remains open; preserve the app and candidate")
        event = events[0]
        if (event.ident != pid or event.filter != select.KQ_FILTER_PROC
                or not event.fflags & select.KQ_NOTE_EXIT or event.flags & select.KQ_EV_ERROR):
            raise RuntimeError("Unexpected process event; do not install")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int)
    parser.add_argument("--timeout", type=float, default=1200)
    args = parser.parse_args()
    if not 1 < args.pid <= 2_147_483_647:
        parser.error("Invalid PID")
    path = executable_path(args.pid)
    if path is not None and path != EXECUTABLE:
        raise ValueError("Expected Agent Flow executable does not own this PID")
    if path is not None:
        wait_for_exit(args.pid, args.timeout)
    print("Expected Agent Flow process exited; installer must revalidate")


if __name__ == "__main__":
    main()
