"""Read-only diagnostic classification, deliberately not production paste routing."""
from __future__ import annotations
from dataclasses import dataclass
from collections import deque
import json
import re


MAX_ANCESTORS = 48
PARTIAL_READ_ERRORS = {"Read timed out", "Ancestor limit reached", "Ancestor path incomplete"}
# These are observations from Ethan's supplied live report, not a public Codex
# contract. Unknown/new hosts may still use explicit markers or manual labels.
MEASURED_HOSTS = {("ChatGPT.app", "26.1013.31256 / 20586")}


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
    subrole: str = ""
    conversation: bool = False


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
    focus_stable: bool | None = None

    @property
    def layout(self):
        # Never reuse calibration after a different process/window or any resize/move.
        return self.pid, self.window_key, self.window

    @property
    def usable_path(self):
        # Partial evidence remains useful only with independently read window
        # bounds. Focus/owner changes are fatal, never downgraded to partial.
        return not self.error or (self.error in PARTIAL_READ_ERRORS and bool(self.nodes)
                                  and self.window is not None and self.window_key != 0)


def measured_marker(nodes, host, version):
    if (host, version) not in MEASURED_HOSTS:
        return None
    conversation_seen = False
    for node in nodes:
        conversation_seen |= node.conversation
        if not conversation_seen:
            continue
        # The nearest scope wins: a side panel can be inside the app's main
        # landmark. A generic panel/browser tab without Conversation is not chat.
        for identifier in (node.identifier, node.dom_identifier):
            if (node.role == "AXTabPanel" or node.subrole == "AXTabPanel") and re.fullmatch(
                    r"app-shell-tab-panel-app-shell-tab:[0-9]+", identifier):
                return "Side chat"
            if node.role == "AXGroup" and identifier.endswith("-chat-panel"):
                return "Main chat"
    return None


class PaneModel:
    def __init__(self):
        self.regions = {}

    def learn(self, pane, sample, index):
        if pane not in ("Main chat", "Side chat") or not sample.usable_path or sample.window is None:
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

    def classify(self, sample, host="", version=""):
        if not sample.usable_path:
            return "Unknown", sample.error
        partial = f" · partial path: {sample.error}" if sample.error else ""
        measured = measured_marker(sample.nodes, host, version)
        if measured:
            return measured, "Measured Codex structure · not input-focus proof" + partial
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
            return markers.pop(), "Explicit identifier · not proof of input focus" + partial
        if len(markers) > 1:
            return "Unknown", "Conflicting pane identifiers"
        # A saved rectangle alone becomes stale when a divider moves inside an
        # unchanged outer window. Require that exact container in this fresh path.
        matches = [pane for pane, (layout, node) in self.regions.items()
                   if layout == sample.layout and node in sample.nodes
                   and node.frame.contains(sample.x, sample.y)]
        if len(matches) == 1:
            return matches[0], "Learned region · not semantic detection or input focus" + partial
        if len(matches) > 1:
            return "Unknown", "Learned regions overlap here"
        return "Unknown", "No explicit pane identifier or matching learned region"

    def classify_focused_pane(self, sample, host="", version=""):
        if not sample.usable_path:
            return "Unknown", sample.error
        if not sample.nodes:
            return "Unknown", "Focused element unavailable"
        leaf = sample.nodes[0]
        if leaf.focused is not True:
            return "Unknown", "Element does not confirm keyboard focus"
        if sample.focus_stable is False or (sample.error and sample.focus_stable is not True):
            return "Unknown", "Keyboard focus could not be rechecked"
        return self.classify(sample, host, version)

    def classify_focus(self, sample, host="", version=""):
        pane, reason = self.classify_focused_pane(sample, host, version)
        if pane == "Unknown":
            return pane, reason
        leaf = sample.nodes[0]
        if leaf.role not in ("AXTextArea", "AXTextField", "AXComboBox") or leaf.editable is not True:
            return "Unknown", "Focused element is not a confirmed editable input"
        # Do not classify a focused editor by the CLICK location. Its own bounds
        # must fit wholly within a freshly matched user-labelled container.
        if not leaf.frame or not leaf.frame.inside(sample.window or Rect(0, 0, 0, 0)):
            return "Unknown", "Input bounds unavailable or outside its window"
        if reason.startswith("Learned region"):
            region = self.regions[pane][1].frame
            if not leaf.frame.inside(region):
                return "Unknown", "Input crosses the labelled pane boundary"
            return pane, "Focused input in a user-labelled region; not semantic pane identity"
        if reason.startswith("Explicit identifier"):
            return pane, "Focused editable input with an explicit pane identifier"
        if reason.startswith("Measured Codex structure"):
            return pane, "Focused editable input in the measured Codex pane" + (
                f" · partial path: {sample.error}" if sample.error else "")
        return pane, reason

    def input_state(self, sample, host="", version=""):
        if (sample.usable_path and sample.nodes and sample.nodes[0].focused is True
                and sample.focus_stable is not False
                and (not sample.error or sample.focus_stable is True)
                and sample.nodes[0].editable is False):
            return "No editable input focused"
        if self.classify_focus(sample, host, version)[0] != "Unknown":
            return "Editable input focused"
        return "Input focus unverified"


@dataclass(frozen=True)
class Observation:
    click: Sample
    focus: Sample
    number: int
    delay_ms: int = 90
    host: str = ""
    version: str = ""


def describe(model, observation):
    clicked, click_reason = model.classify(observation.click, observation.host, observation.version)
    focused, focus_reason = model.classify_focused_pane(observation.focus, observation.host, observation.version)
    input_state = model.input_state(observation.focus, observation.host, observation.version)
    # Some Chromium hit-tests return only a window-sized wrapper. A freshly
    # focused Conversation region containing this click supplies narrower proof;
    # a last-focused text box, another window or stale/changed focus never does.
    focus_leaf = observation.focus.nodes[0] if observation.focus.nodes else None
    if (clicked == "Unknown" and observation.click.usable_path
            and focused != "Unknown" and observation.focus.focus_stable is True
            and observation.focus.window is not None and observation.click.window_key != 0
            and observation.click.layout == observation.focus.layout
            and focus_leaf and focus_leaf.conversation and focus_leaf.frame
            and focus_leaf.frame.inside(observation.focus.window)
            and focus_leaf.frame.contains(observation.click.x, observation.click.y)):
        clicked = focused
        click_reason = "Focused Conversation region contains click · hit-test path had no pane marker"
    if clicked != "Unknown" and focused != "Unknown":
        same_window = observation.click.layout == observation.focus.layout
        status = "Different windows" if not same_window else ("Same pane" if clicked == focused else "Different panes")
        if input_state != "Editable input focused":
            status += " · " + input_state.lower()
        if input_state == "No editable input focused":
            next_check = "The chat area has focus, not an input. Click its input and compare again."
        elif clicked == focused and same_window:
            next_check = "Repeat in the other input, then the chat body."
        else:
            next_check = "The clicked pane and focused input differ. Click that pane's input and compare again."
    else:
        status = "Not enough evidence"
        if not observation.click.usable_path or not observation.focus.usable_path:
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
        self.observations.append((observation, describe(model, observation) + (
            model.input_state(observation.focus, observation.host, observation.version),)))

    def report(self, model):
        def metadata(sample):
            return {"error": sample.error, "end": sample.end, "elapsed_ms": sample.elapsed_ms,
                    "errors": list(sample.errors), "nodes": [
                        {"role": n.role if re.fullmatch(r"AX[A-Za-z]+", n.role) else "other",
                         "identifier_chars": len(n.identifier), "dom_identifier_chars": len(n.dom_identifier),
                         "bounds_present": n.frame is not None, "focused": n.focused, "editable": n.editable}
                         | {"subrole": n.subrole if re.fullmatch(r"AX[A-Za-z]+", n.subrole) else "",
                            "conversation": n.conversation}
                         | {"main_marker": any(s.endswith("-chat-panel") for s in (n.identifier, n.dom_identifier)),
                            "panel_marker": any(bool(re.fullmatch(r"app-shell-tab-panel-app-shell-tab:[0-9]+", s))
                                                for s in (n.identifier, n.dom_identifier))}
                        for n in sample.nodes[:MAX_ANCESTORS]],
                    "partial": bool(sample.error and sample.usable_path),
                    "focus_stable": sample.focus_stable}
        rows = []
        for o, result in self.observations:
            # Later manual calibration must not rewrite evidence of earlier misses.
            c, cr, f, fr, relation, _, input_state = result
            rows.append({"sample": o.number, "settle_ms": o.delay_ms, "clicked_pane": c,
                         "host": o.host if o.host in ("Codex.app", "ChatGPT.app", "demo") else "unknown",
                         "host_version": o.version if re.fullmatch(r"[0-9. /+-]{1,80}", o.version) else "unknown",
                         "click_reason": cr, "focused_pane": f, "focus_reason": fr,
                         "comparison": relation, "same_window": o.click.layout == o.focus.layout,
                         "input_state": input_state,
                         "click": metadata(o.click), "focus": metadata(o.focus)})
        return json.dumps({"tool": "Codex Focus Inspector", "schema": 3,
                           "scope": "user-click snapshots, not live focus tracking or paste routing",
                           "privacy": "No message text, titles, IDs, coordinates, or file paths",
                           "samples": rows}, indent=2)
