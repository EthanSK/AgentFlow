"""Read-only diagnostic classification, deliberately not production paste routing."""
from __future__ import annotations
from dataclasses import dataclass
from collections import deque
import json
import re


@dataclass(frozen=True)
class Rect:
    x: float
    y: float
    width: float
    height: float

    def contains(self, x, y):
        return self.x <= x < self.x + self.width and self.y <= y < self.y + self.height

    def inside(self, outer):
        return (self.width > 0 and self.height > 0 and self.x >= outer.x - 1
                and self.y >= outer.y - 1
                and self.x + self.width <= outer.x + outer.width + 1
                and self.y + self.height <= outer.y + outer.height + 1)

    def short(self):
        return f"{self.x:.0f}, {self.y:.0f} · {self.width:.0f} × {self.height:.0f}"


@dataclass(frozen=True)
class Node:
    role: str
    identifier: str
    dom_identifier: str
    frame: Rect | None
    focused: bool | None = None
    editable: bool | None = None


@dataclass(frozen=True)
class Sample:
    pid: int
    window_key: int
    window: Rect | None
    x: float
    y: float
    nodes: tuple[Node, ...]
    error: str = ""
    end: str = ""
    elapsed_ms: int = 0
    errors: tuple[str, ...] = ()

    @property
    def layout(self):
        # Never reuse calibration after a different process/window or any resize/move.
        return self.pid, self.window_key, self.window


class PaneModel:
    def __init__(self):
        self.regions = {}

    def learn(self, pane, sample, index):
        if pane not in ("Main chat", "Side chat") or sample.error or sample.window is None:
            return False
        if not 0 <= index < len(sample.nodes):
            return False
        rect = sample.nodes[index].frame
        if rect is None or not rect.inside(sample.window) or rect == sample.window:
            return False
        if not rect.contains(sample.x, sample.y):
            return False
        self.regions[pane] = (sample.layout, sample.nodes[index])
        return True

    def classify(self, sample):
        if sample.error:
            return "Unknown", sample.error
        # Explicit markers are evidence only; no title, message, text value, position
        # heuristic or missing-side-implies-main rule is allowed to identify a pane.
        markers = set()
        for node in sample.nodes:
            for identifier in (node.identifier, node.dom_identifier):
                normalized = re.sub(r"([a-z])([A-Z])", r"\1-\2", identifier).lower()
                for pane, marker in (("Main chat", "main-chat"), ("Side chat", "side-chat")):
                    if re.search(r"(?:^|[-_:])" + marker + r"(?:$|[-_:])", normalized):
                        markers.add(pane)
        if len(markers) == 1:
            return markers.pop(), "Explicit identifier · not proof of input focus"
        if len(markers) > 1:
            return "Unknown", "Conflicting pane identifiers"
        # A saved rectangle alone becomes stale when a divider moves inside an
        # unchanged outer window. Require that exact container in this fresh path.
        matches = [pane for pane, (layout, node) in self.regions.items()
                   if layout == sample.layout and node in sample.nodes
                   and node.frame.contains(sample.x, sample.y)]
        if len(matches) == 1:
            return matches[0], "Learned region · not semantic detection or input focus"
        if len(matches) > 1:
            return "Unknown", "Learned regions overlap here"
        return "Unknown", "No explicit pane identifier or matching learned region"

    def classify_focus(self, sample):
        if sample.error:
            return "Unknown", sample.error
        if not sample.nodes:
            return "Unknown", "Focused element unavailable"
        leaf = sample.nodes[0]
        if leaf.focused is not True:
            return "Unknown", "Element does not confirm keyboard focus"
        if leaf.role not in ("AXTextArea", "AXTextField", "AXComboBox") or leaf.editable is not True:
            return "Unknown", "Focused element is not a confirmed editable input"
        # Do not classify a focused editor by the CLICK location. Its own bounds
        # must fit wholly within a freshly matched user-labelled container.
        if not leaf.frame or not leaf.frame.inside(sample.window or Rect(0, 0, 0, 0)):
            return "Unknown", "Input bounds unavailable or outside its window"
        pane, reason = self.classify(sample)
        if reason.startswith("Learned region"):
            region = self.regions[pane][1].frame
            if not leaf.frame.inside(region):
                return "Unknown", "Input crosses the labelled pane boundary"
            return pane, "Focused input in a user-labelled region; not semantic pane identity"
        if reason.startswith("Explicit identifier"):
            return pane, "Focused editable input with an explicit pane identifier"
        return pane, reason


@dataclass(frozen=True)
class Observation:
    click: Sample
    focus: Sample
    number: int
    delay_ms: int = 90
    host: str = ""
    version: str = ""


def describe(model, observation):
    clicked, click_reason = model.classify(observation.click)
    focused, focus_reason = model.classify_focus(observation.focus)
    if clicked != "Unknown" and focused != "Unknown":
        same_window = observation.click.layout == observation.focus.layout
        status = "Different windows" if not same_window else ("Same pane" if clicked == focused else "Different panes")
        next_check = ("Repeat in the other input, then the chat body." if status == "Same pane" else
                      "The clicked pane and focused input differ. Click that pane's input and compare again.")
    else:
        status = "Not enough evidence"
        if observation.click.error or observation.focus.error:
            next_check = "Check access and read errors below; copy diagnostics if it repeats."
        elif observation.focus.nodes and observation.focus.nodes[0].editable is not True:
            next_check = "Click inside the actual chat input, not just its message area."
        else:
            next_check = "Label a pane container if no marker is exposed, then repeat both inputs."
    return clicked, click_reason, focused, focus_reason, status, next_check


class Diagnostics:
    """Bounded in-memory evidence; exporting is a deliberate user Copy action.

    Never serialize raw AX identifiers: they can contain task IDs or private
    document data even though they are not AXValue. No generic dataclass export.
    """
    def __init__(self):
        self.observations = deque(maxlen=20)

    def append(self, observation, model):
        self.observations.append((observation, describe(model, observation)))

    def report(self, model):
        def metadata(sample):
            return {"error": sample.error, "end": sample.end, "elapsed_ms": sample.elapsed_ms,
                    "errors": list(sample.errors), "nodes": [
                        {"role": n.role if re.fullmatch(r"AX[A-Za-z]+", n.role) else "other",
                         "identifier_chars": len(n.identifier), "dom_identifier_chars": len(n.dom_identifier),
                         "bounds_present": n.frame is not None, "focused": n.focused, "editable": n.editable}
                        for n in sample.nodes[:24]]}
        rows = []
        for o, result in self.observations:
            # Later manual calibration must not rewrite evidence of earlier misses.
            c, cr, f, fr, relation, _ = result
            rows.append({"sample": o.number, "settle_ms": o.delay_ms, "clicked_pane": c,
                         "host": o.host if o.host in ("Codex.app", "ChatGPT.app", "demo") else "unknown",
                         "host_version": o.version if re.fullmatch(r"[0-9. /+-]{1,80}", o.version) else "unknown",
                         "click_reason": cr, "focused_pane": f, "focus_reason": fr,
                         "comparison": relation, "same_window": o.click.layout == o.focus.layout,
                         "click": metadata(o.click), "focus": metadata(o.focus)})
        return json.dumps({"tool": "Codex Focus Inspector", "schema": 2,
                           "scope": "user-click snapshots, not live focus tracking or paste routing",
                           "privacy": "No message text, titles, IDs, coordinates, or file paths",
                           "samples": rows}, indent=2)
