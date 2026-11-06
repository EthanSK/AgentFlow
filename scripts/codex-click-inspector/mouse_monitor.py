"""One observable, listen-only mouse tap. Never posts or consumes input."""
import Quartz as Q


class MouseMonitor:
    def __init__(self, on_event, quartz=Q):
        self.q, self.on_event = quartz, on_event
        self.tap = self.source = None
        self.disabled_count = 0

    def start(self):
        self.close()
        q = self.q
        mask = sum(1 << kind for kind in (q.kCGEventLeftMouseDown, q.kCGEventLeftMouseUp,
                                         q.kCGEventRightMouseDown, q.kCGEventOtherMouseDown))
        self.tap = q.CGEventTapCreate(q.kCGSessionEventTap, q.kCGTailAppendEventTap,
                                     q.kCGEventTapOptionListenOnly, mask, self.callback, None)
        if self.tap is None:
            return False  # Never prompt for permissions or run a second observer.
        self.source = q.CFMachPortCreateRunLoopSource(None, self.tap, 0)
        if self.source is None:
            self.close()
            return False
        q.CFRunLoopAddSource(q.CFRunLoopGetMain(), self.source, q.kCFRunLoopCommonModes)
        self.enable()
        return self.enabled()

    def callback(self, proxy, kind, event, context):
        q = self.q
        if self.tap is None:
            return event
        if kind in (q.kCGEventTapDisabledByTimeout, q.kCGEventTapDisabledByUserInput):
            self.disabled_count += 1
            self.on_event(kind, event)  # Cancel work that may have missed input.
            self.enable()
        elif kind in (q.kCGEventLeftMouseDown, q.kCGEventLeftMouseUp,
                      q.kCGEventRightMouseDown, q.kCGEventOtherMouseDown):
            self.on_event(kind, event)
        return event  # Listen-only; even a disabled/error case never swallows it.

    def enabled(self):
        return self.tap is not None and bool(self.q.CGEventTapIsEnabled(self.tap))

    def enable(self):
        if self.tap is not None:
            self.q.CGEventTapEnable(self.tap, True)

    def close(self):
        q = self.q
        if self.source is not None:
            q.CFRunLoopRemoveSource(q.CFRunLoopGetMain(), self.source, q.kCFRunLoopCommonModes)
        if self.tap is not None:
            q.CFMachPortInvalidate(self.tap)
        self.tap = self.source = None
