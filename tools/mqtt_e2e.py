#!/usr/bin/env python3
"""
LAYER 2 of the MQTT test suite: end-to-end against a real broker.

Publishes the exact JSON Home Assistant would publish to
`{prefix}/{device}/command/*`, then asserts on the retained state topics the app
publishes back on `{prefix}/{device}/alarm/{index}/*`. Where Layer 1 (the Swift
tests in HaWake Alarm V2Tests/MQTTPayloadTests.swift) proves the payload → model
translation, this proves the WIRE: that the app subscribes, routes by topic
segment, applies the command, and reports the result back to the broker.

SAFETY
    Every alarm this script creates is labelled with a per-run tag —
    "E2E-<runid> …" — and it only ever deletes alarms carrying that tag, by
    name. It never issues `delete_next_alarm`, never deletes by index, and never
    touches an alarm it did not create. Running it against a phone with real
    alarms on it is safe, though the simulator is the intended target.

REQUIREMENTS
    pip3 install paho-mqtt

CONFIGURATION (environment)
    MQTT_HOST        broker hostname/IP            (required)
    MQTT_PORT        broker port                   (default 1883)
    MQTT_USER        username                      (optional)
    MQTT_PASS        password                      (optional)
    MQTT_TLS         "1" to use TLS                (default off)
    HAWAKE_PREFIX    app's MQTT topic prefix       (default "hawake")
    HAWAKE_DEVICE    app's sanitized device name   (required)
    E2E_TIMEOUT      seconds to await each state   (default 10)

    HAWAKE_DEVICE must match the app's *sanitized* name: lowercased, spaces to
    hyphens, anything outside [a-z0-9-] stripped. "iPhone 17 Pro Max" becomes
    "iphone-17-pro-max".

USAGE
    export MQTT_HOST=192.168.1.100
    export HAWAKE_DEVICE=iphone-17-pro-max
    python3 tools/mqtt_e2e.py

    Exits 0 when every check passes, 1 otherwise, so it can be dropped into CI
    unchanged. `--verbose` echoes every publish and every state topic received.

PREREQUISITE IN THE APP
    "Allow Inbound Commands" must be ON, or the app ignores everything sent here
    and every check will time out.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import random
import string
import sys
import threading
import time

try:
    import paho.mqtt.client as mqtt
except ImportError:
    sys.exit("paho-mqtt is required:  pip3 install paho-mqtt")


# ── Configuration ────────────────────────────────────────────────────────────

HOST = os.environ.get("MQTT_HOST")
PORT = int(os.environ.get("MQTT_PORT", "1883"))
USER = os.environ.get("MQTT_USER") or None
PASS = os.environ.get("MQTT_PASS") or None
USE_TLS = os.environ.get("MQTT_TLS") == "1"
PREFIX = os.environ.get("HAWAKE_PREFIX", "hawake")
DEVICE = os.environ.get("HAWAKE_DEVICE")
TIMEOUT = float(os.environ.get("E2E_TIMEOUT", "10"))

RUN_ID = "".join(random.choices(string.ascii_lowercase + string.digits, k=4))
TAG = f"E2E-{RUN_ID}"


# ── Result tracking ──────────────────────────────────────────────────────────

class Results:
    def __init__(self) -> None:
        self.passed = 0
        self.failed: list[str] = []
        self.skipped: list[str] = []

    def ok(self, what: str) -> None:
        self.passed += 1
        print(f"  \033[32m✓\033[0m {what}")

    def fail(self, what: str, detail: str) -> None:
        self.failed.append(f"{what}: {detail}")
        print(f"  \033[31m✗\033[0m {what}\n      {detail}")

    def skip(self, what: str, why: str) -> None:
        self.skipped.append(f"{what}: {why}")
        print(f"  \033[33m–\033[0m {what} (skipped: {why})")


RESULTS = Results()


# ── Broker plumbing ──────────────────────────────────────────────────────────

class Bus:
    """Wraps the MQTT client and records the latest payload per topic."""

    def __init__(self, verbose: bool = False) -> None:
        self.verbose = verbose
        self.latest: dict[str, str] = {}
        self.events: queue.Queue[tuple[str, str]] = queue.Queue()
        self._lock = threading.Lock()
        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"hawake-e2e-{RUN_ID}")
        if USER:
            self.client.username_pw_set(USER, PASS)
        if USE_TLS:
            self.client.tls_set()
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message

    def _on_connect(self, client, userdata, flags, reason_code, properties=None):
        if reason_code != 0:
            sys.exit(f"Broker refused the connection: {reason_code}")
        # Everything the app reports about alarms and its own status.
        client.subscribe(f"{PREFIX}/{DEVICE}/alarm/#", qos=1)
        client.subscribe(f"{PREFIX}/{DEVICE}/status", qos=1)
        client.subscribe(f"{PREFIX}/{DEVICE}/availability", qos=1)

    def _on_message(self, client, userdata, msg):
        payload = msg.payload.decode("utf-8", errors="replace")
        with self._lock:
            self.latest[msg.topic] = payload
        self.events.put((msg.topic, payload))
        if self.verbose:
            print(f"      \033[90m← {msg.topic} = {payload!r}\033[0m")

    def connect(self) -> None:
        self.client.connect(HOST, PORT, keepalive=30)
        self.client.loop_start()
        # Let retained state land before the first assertion.
        time.sleep(1.5)

    def disconnect(self) -> None:
        self.client.loop_stop()
        self.client.disconnect()

    def publish_command(self, command: str, payload: dict) -> None:
        """Publish to the app's command topic.

        NEVER retained — the app drops retained command messages on purpose, so
        that a reconnect can't replay them. `ts` is stamped on every command so
        the freshness window is exercised on the real path too.
        """
        topic = f"{PREFIX}/{DEVICE}/command/{command}"
        body = dict(payload)
        body.setdefault("ts", int(time.time()))
        blob = json.dumps(body)
        if self.verbose:
            print(f"      \033[90m→ {topic} = {blob}\033[0m")
        self.client.publish(topic, blob, qos=1, retain=False)

    def await_topic(self, topic: str, predicate, timeout: float = TIMEOUT) -> str | None:
        """Wait for `topic` to satisfy `predicate`. Returns the payload or None.

        Checks what already arrived first — the app may well have published
        before we started waiting — then drains new events until the deadline.
        """
        with self._lock:
            current = self.latest.get(topic)
        if current is not None and predicate(current):
            return current

        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                t, payload = self.events.get(timeout=max(0.05, deadline - time.time()))
            except queue.Empty:
                break
            if t == topic and predicate(payload):
                return payload
        with self._lock:
            return None if topic not in self.latest else None

    def get(self, topic: str) -> str | None:
        with self._lock:
            return self.latest.get(topic)


# ── Helpers ──────────────────────────────────────────────────────────────────

def find_alarm_index(bus: Bus, label: str, timeout: float = TIMEOUT) -> int | None:
    """Resolve the alarm index the app assigned to a label.

    The app publishes `alarm/{index}/name`, so the index is discovered by
    watching for our label to appear on one of those topics.
    """
    deadline = time.time() + timeout

    def scan() -> int | None:
        with bus._lock:
            snapshot = dict(bus.latest)
        for topic, payload in snapshot.items():
            if topic.endswith("/name") and payload == label:
                parts = topic.split("/")
                try:
                    return int(parts[parts.index("alarm") + 1])
                except (ValueError, IndexError):
                    continue
        return None

    found = scan()
    if found is not None:
        return found
    while time.time() < deadline:
        try:
            bus.events.get(timeout=max(0.05, deadline - time.time()))
        except queue.Empty:
            break
        found = scan()
        if found is not None:
            return found
    return None


def expect_topic(bus: Bus, topic: str, expected: str, what: str) -> bool:
    got = bus.await_topic(topic, lambda p: p == expected)
    if got == expected:
        RESULTS.ok(f"{what} → {topic.split('/')[-1]} = {expected!r}")
        return True
    actual = bus.get(topic)
    RESULTS.fail(what, f"{topic}\n      expected {expected!r}, got {actual!r}")
    return False


# ── Checks ───────────────────────────────────────────────────────────────────

def check_app_online(bus: Bus) -> bool:
    """The app must be connected, or every later check is a slow timeout."""
    print("\n\033[1mApp reachable\033[0m")
    topic = f"{PREFIX}/{DEVICE}/availability"
    got = bus.await_topic(topic, lambda p: p == "online", timeout=5)
    if got == "online":
        RESULTS.ok("app is online")
        return True
    RESULTS.fail(
        "app is online",
        f"{topic} = {bus.get(topic)!r}. Is the app running, connected, "
        f"and is HAWAKE_DEVICE={DEVICE!r} correct?",
    )
    return False


def check_create_alarm(bus: Bus) -> int | None:
    """create_alarm, including the multi-mission `missions` array."""
    print("\n\033[1mcreate_alarm\033[0m")
    label = f"{TAG} morning"
    bus.publish_command("create_alarm", {
        "time": "07:30",
        "label": label,
        "enabled": True,
        "days": [2, 3, 4, 5, 6],
        "missions": [
            {"mission": "math", "mission_config": {"math_count": 3, "math_difficulty": "hard"}},
            "shake",
            "math",
        ],
        "snooze_duration": 9,
        "notes": "E2E notes body",
    })

    index = find_alarm_index(bus, label)
    if index is None:
        RESULTS.fail("create_alarm", f"no alarm/*/name ever carried {label!r}")
        return None
    RESULTS.ok(f"alarm created at index {index}")

    base = f"{PREFIX}/{DEVICE}/alarm/{index}"
    expect_topic(bus, f"{base}/enabled", "on", "enabled reported")
    expect_topic(bus, f"{base}/mission", "math", "slot 1 mission reported")
    # The whole sequence, comma-joined, plus its length — the topics that made
    # multi-mission alarms legible to automations.
    expect_topic(bus, f"{base}/missions", "math,shake,math", "full mission sequence reported")
    expect_topic(bus, f"{base}/mission_count", "3", "mission_count reported")
    expect_topic(bus, f"{base}/notes", "E2E notes body", "notes reported")
    return index


def check_update_alarm_missions(bus: Bus, index: int) -> None:
    """The slot-clearing rule, proven on the wire rather than in a unit test."""
    print("\n\033[1mupdate_alarm — mission semantics\033[0m")
    label = f"{TAG} morning"
    base = f"{PREFIX}/{DEVICE}/alarm/{index}"

    # `missions` replaces the whole sequence.
    bus.publish_command("update_alarm", {"name": label, "missions": ["shake", "math"]})
    expect_topic(bus, f"{base}/missions", "shake,math", "`missions` replaces the sequence")
    expect_topic(bus, f"{base}/mission_count", "2", "mission_count follows")

    # Singular `mission` replaces slot 1 AND clears slots 2–5. This is the rule
    # most likely to regress, because it reads like a partial update and isn't.
    bus.publish_command("update_alarm", {"name": label, "mission": "shake"})
    expect_topic(bus, f"{base}/mission_count", "1", "singular `mission` clears slots 2–5")
    expect_topic(bus, f"{base}/missions", "shake", "sequence collapses to one")


def check_update_alarm_fields(bus: Bus, index: int) -> None:
    print("\n\033[1mupdate_alarm — fields\033[0m")
    label = f"{TAG} morning"
    base = f"{PREFIX}/{DEVICE}/alarm/{index}"

    bus.publish_command("update_alarm", {"name": label, "enabled": False})
    expect_topic(bus, f"{base}/enabled", "off", "enabled toggled off")

    bus.publish_command("update_alarm", {"name": label, "enabled": True})
    expect_topic(bus, f"{base}/enabled", "on", "enabled toggled back on")

    # append_notes appends rather than replacing — V1 semantics, restored.
    bus.publish_command("update_alarm", {"name": label, "notes": "base note"})
    expect_topic(bus, f"{base}/notes", "base note", "notes replaced")

    bus.publish_command("update_alarm", {"name": label, "append_notes": "appended line"})
    got = bus.await_topic(f"{base}/notes", lambda p: "appended line" in p and "base note" in p)
    if got:
        RESULTS.ok("append_notes appended without replacing")
    else:
        RESULTS.fail("append_notes appended without replacing",
                     f"{base}/notes = {bus.get(f'{base}/notes')!r}")


def check_retained_command_dropped(bus: Bus, index: int) -> None:
    """A retained command must be IGNORED.

    This is the replay-protection contract: the broker would redeliver a
    retained command on every reconnect, so the app drops them. Sent last,
    because it deliberately leaves a retained message on a command topic —
    cleared immediately afterwards.
    """
    print("\n\033[1mreplay protection\033[0m")
    label = f"{TAG} morning"
    base = f"{PREFIX}/{DEVICE}/alarm/{index}"
    topic = f"{PREFIX}/{DEVICE}/command/update_alarm"

    bus.publish_command("update_alarm", {"name": label, "enabled": True})
    expect_topic(bus, f"{base}/enabled", "on", "baseline enabled=on")

    # Retained — the app must ignore this.
    bus.client.publish(
        topic,
        json.dumps({"name": label, "enabled": False, "ts": int(time.time())}),
        qos=1,
        retain=True,
    )
    time.sleep(3)
    still_on = bus.get(f"{base}/enabled")
    if still_on == "on":
        RESULTS.ok("retained command ignored (enabled stayed on)")
    else:
        RESULTS.fail("retained command ignored",
                     f"{base}/enabled = {still_on!r} — a retained command was ACTED ON")

    # Clear the retained message so it can't haunt the next run or a real device.
    bus.client.publish(topic, "", qos=1, retain=True)
    time.sleep(0.5)


def check_stale_ts_rejected(bus: Bus, index: int) -> None:
    """A `ts` outside the 60-second window must be rejected."""
    print("\n\033[1mfreshness window\033[0m")
    label = f"{TAG} morning"
    base = f"{PREFIX}/{DEVICE}/alarm/{index}"

    bus.publish_command("update_alarm", {"name": label, "enabled": True})
    expect_topic(bus, f"{base}/enabled", "on", "baseline enabled=on")

    stale = {"name": label, "enabled": False, "ts": int(time.time()) - 600}
    bus.client.publish(
        f"{PREFIX}/{DEVICE}/command/update_alarm", json.dumps(stale), qos=1, retain=False
    )
    time.sleep(3)
    still_on = bus.get(f"{base}/enabled")
    if still_on == "on":
        RESULTS.ok("stale ts rejected (enabled stayed on)")
    else:
        RESULTS.fail("stale ts rejected",
                     f"{base}/enabled = {still_on!r} — a 10-minute-old command was ACTED ON")


def cleanup(bus: Bus) -> None:
    """Delete ONLY what this run created, by name."""
    print("\n\033[1mcleanup\033[0m")
    label = f"{TAG} morning"
    bus.publish_command("delete_alarm", {"name": label})
    time.sleep(2)
    remaining = find_alarm_index(bus, label, timeout=2)
    if remaining is None:
        RESULTS.ok(f"deleted {label!r}")
    else:
        RESULTS.fail("cleanup", f"{label!r} still present at index {remaining} — delete by hand")


# ── Entry point ──────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="HaWake MQTT end-to-end checks")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="echo every publish and every state topic received")
    parser.add_argument("--no-cleanup", action="store_true",
                        help="leave the created alarm in place for inspection")
    args = parser.parse_args()

    if not HOST or not DEVICE:
        return int(bool(sys.stderr.write(
            "MQTT_HOST and HAWAKE_DEVICE are required.\n"
            "  export MQTT_HOST=192.168.1.100\n"
            "  export HAWAKE_DEVICE=iphone-17-pro-max\n"
            "HAWAKE_DEVICE is the app's SANITIZED name: lowercase, spaces→hyphens.\n"
        )))

    print(f"\033[1mHaWake MQTT E2E\033[0m  broker={HOST}:{PORT}  topics={PREFIX}/{DEVICE}/…  run={RUN_ID}")

    bus = Bus(verbose=args.verbose)
    bus.connect()

    try:
        if not check_app_online(bus):
            print("\n\033[31mAborting — the app is not reachable on this broker.\033[0m")
            return 1

        index = check_create_alarm(bus)
        if index is not None:
            check_update_alarm_missions(bus, index)
            check_update_alarm_fields(bus, index)
            check_stale_ts_rejected(bus, index)
            check_retained_command_dropped(bus, index)
            if not args.no_cleanup:
                cleanup(bus)
            else:
                RESULTS.skip("cleanup", f"--no-cleanup; delete {TAG!r} by hand")
    finally:
        bus.disconnect()

    print("\n" + "─" * 60)
    print(f"\033[1m{RESULTS.passed} passed"
          + (f", \033[31m{len(RESULTS.failed)} failed\033[0m" if RESULTS.failed else "\033[0m")
          + (f", {len(RESULTS.skipped)} skipped" if RESULTS.skipped else ""))
    for failure in RESULTS.failed:
        print(f"  \033[31m✗\033[0m {failure}")
    return 1 if RESULTS.failed else 0


if __name__ == "__main__":
    sys.exit(main())
