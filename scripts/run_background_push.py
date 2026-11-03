#!/usr/bin/env python3
"""Send one background push through the public API and check the device callback.

The send uses /send/push or a freshly created, single-profile broadcast, so APNs or FCM carries the message to the
device. A pass needs the backend sent and delivered metrics for the returned
delivery ID plus a device callback with that ID and the exact data. On iOS the
script can't inspect SpringBoard, so display suppression stays unverified.

MAESTRO_APP_API_KEY is read from the environment only. Errors and the result
leave out the key, the device token and the payload. The last stdout line is
the result JSON.
"""
import argparse
import http.client
import json
import math
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import quote, urlparse

EMAIL = re.compile(r"maestro\+e2e-[a-z0-9][a-z0-9-]*@cio\.test", re.ASCII)
CAPABILITY = "cio_background_push_version"
FAILED_METRICS = ("failed", "undeliverable", "bounced")
INTERACTION_METRICS = ("opened", "clicked")
HTTP_TIMEOUT = 15
CLOCK_SKEW_MS = 2000
POLL_SECONDS = 1.0


class RunFailure(Exception):
    """Holds a fixed reason code. Keep tokens, keys and payloads out of it."""

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


class TransportError(Exception):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # Keeps the bearer key on the host given in --api-base.
    def redirect_request(self, *args, **kwargs):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def _json(raw):
    try:
        return json.loads(raw or b"null")
    except ValueError:
        return None


class Api:
    def __init__(self, base, key):
        self.base, self.key = base.rstrip("/"), key

    def call(self, method, path, body=None):
        request = urllib.request.Request(
            self.base + path,
            data=None if body is None else json.dumps(body).encode(),
            method=method,
            headers={"Authorization": "Bearer " + self.key, "Content-Type": "application/json", "Accept": "application/json"},
        )
        try:
            with _OPENER.open(request, timeout=HTTP_TIMEOUT) as response:
                return response.status, _json(response.read())
        except urllib.error.HTTPError as error:
            with error:
                return error.code, None
        except (OSError, http.client.HTTPException):
            raise TransportError() from None


class Clock:
    monotonic = staticmethod(time.monotonic)
    sleep = staticmethod(time.sleep)

    @staticmethod
    def now_ms():
        return int(time.time() * 1000)


def run(command):
    env = dict(os.environ)
    env.pop("MAESTRO_APP_API_KEY", None)
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    name = Path(command[0]).name
    try:
        return subprocess.run(command, check=False, capture_output=True, text=True, timeout=20, env=env)
    except subprocess.TimeoutExpired:
        raise RunFailure(name + "_timed_out") from None
    except OSError:
        raise RunFailure(name + "_unavailable") from None


def parse_rows(text):
    rows = []
    for line in text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue  # a partially written last line
        if isinstance(row, dict):
            rows.append(row)
    return rows


class AndroidDevice:
    def __init__(self, serial, app_id):
        self.adb, self.app_id = ["adb", "-s", serial], app_id

    def preflight(self):
        if run(self.adb + ["shell", "run-as", self.app_id, "id"]).returncode != 0:
            raise RunFailure("android_run_as_unavailable")
        # HOME moves the app to the background and leaves its process alive.
        if run(self.adb + ["shell", "input", "keyevent", "KEYCODE_HOME"]).returncode != 0:
            raise RunFailure("android_home_failed")
        return "adb_home"

    def callbacks(self):
        result = run(self.adb + ["shell", "run-as", self.app_id, "cat", "files/background-push.jsonl"])
        return parse_rows(result.stdout) if result.returncode == 0 else []

    def notification_snapshot(self):
        result = run(self.adb + ["shell", "dumpsys", "notification", "--noredact"])
        if result.returncode != 0:
            raise RunFailure("android_dumpsys_failed")
        marker = f"pkg={self.app_id} "
        return frozenset(line.strip() for line in result.stdout.splitlines() if "NotificationRecord(" in line and marker in line)


class IOSSimulator:
    def __init__(self, udid, app_id):
        self.udid, self.app_id, self.path = udid, app_id, None

    def preflight(self):
        result = run(["xcrun", "simctl", "get_app_container", self.udid, self.app_id, "data"])
        if result.returncode != 0 or not result.stdout.strip():
            raise RunFailure("ios_app_container_unavailable")
        self.path = Path(result.stdout.strip()) / "Documents" / "background-push.jsonl"
        return None  # the operator confirms backgrounding at the send gate

    def callbacks(self):
        try:
            return parse_rows(self.path.read_text())
        except FileNotFoundError:
            return []
        except OSError:
            raise RunFailure("ios_callback_log_unreadable") from None

    def notification_snapshot(self):
        return None  # SpringBoard state is out of reach here


def validate(opts):
    if not isinstance(opts.email, str) or not EMAIL.fullmatch(opts.email):
        raise RunFailure("email_not_fresh_synthetic")
    if getattr(opts, "create_broadcast", False):
        if opts.transactional_id is not None:
            raise RunFailure("conflicting_send_modes")
    elif isinstance(opts.transactional_id, bool) or not isinstance(opts.transactional_id, int) or opts.transactional_id <= 0:
        raise RunFailure("invalid_transactional_id")
    data = opts.data
    if not isinstance(data, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in data.items()):
        raise RunFailure("data_not_flat_string_map")
    if not data.get("run_id", "").strip():
        raise RunFailure("data_missing_run_id")
    if getattr(opts, "create_broadcast", False) and len(data["run_id"]) > 190:
        raise RunFailure("broadcast_run_id_too_long")


def get(api, path, reason):
    try:
        status, body = api.call("GET", path)
    except TransportError:
        raise RunFailure(reason + "_transport") from None
    if status != 200 or not isinstance(body, dict):
        raise RunFailure(f"{reason}_status_{status}")
    return body


def lookup_customer(api, email):
    results = get(api, "/customers?email=" + quote(email, safe=""), "customer_lookup").get("results") or []
    if len(results) != 1 or not isinstance(results[0], dict) or results[0].get("email") != email or not results[0].get("cio_id"):
        raise RunFailure("customer_not_unique")
    return str(results[0]["cio_id"])


def eligible_device(api, cio_id, platform, single_device=False):
    customer = get(api, f"/customers/{quote(cio_id, safe='')}/attributes?id_type=cio_id", "customer_attributes").get("customer")
    devices = customer.get("devices") if isinstance(customer, dict) else None
    if single_device and len(devices or []) > 1:
        raise RunFailure("profile_has_other_devices")
    eligible = [
        d for d in devices or []
        if isinstance(d, dict) and d.get("id") and d.get("platform") == platform
        and isinstance(d.get("attributes"), dict) and d["attributes"].get(CAPABILITY) == "1"
    ]
    if len(eligible) != 1:
        raise RunFailure("ambiguous_eligible_devices" if eligible else "no_eligible_device")
    return eligible[0]["id"]


def check_template(api, transactional_id):
    contents = get(api, f"/transactional/{transactional_id}/contents", "template_contents").get("contents")
    if not isinstance(contents, list) or not contents or any(
        not isinstance(content, dict) or content.get("type") != "push"
        or content.get("push_mode") != "background" or content.get("subject") or content.get("body") or content.get("image_url")
        for content in contents
    ):
        raise RunFailure("template_not_background")


def confirm_send(stdin, stdout):
    print("Preflight passed. Background the app, make the provider ready, then enter SEND.", file=stdout)
    print("READY_FOR_PROVIDER_SEND", file=stdout, flush=True)
    if stdin.readline().strip() != "SEND":
        raise RunFailure("send_not_confirmed")


def send(api, opts, token):
    body = {"transactional_message_id": opts.transactional_id, "identifiers": {"email": opts.email}, "to": token, "custom_data": opts.data, "queue_draft": False}
    try:
        status, response = api.call("POST", "/send/push", body)
    except TransportError:
        # The request may have reached the API; a retry could send twice.
        raise RunFailure("send_outcome_ambiguous_not_retried") from None
    if status != 200 or not isinstance(response, dict) or not response.get("delivery_id"):
        raise RunFailure(f"send_status_{status}")
    return str(response["delivery_id"])


def create_broadcast(api, opts):
    body = {
        "name": "Background push E2E " + opts.data["run_id"], "type": "push",
        "push_mode": "background", "custom_data": opts.data,
        "recipients": {"and": [{"attribute": {"field": "email", "operator": "eq", "value": opts.email}}]},
    }
    try:
        status, response = api.call("POST", "/newsletters", body)
    except TransportError:
        raise RunFailure("broadcast_create_ambiguous_not_retried") from None
    newsletter = response.get("newsletter") if isinstance(response, dict) else None
    nid = newsletter.get("id") if isinstance(newsletter, dict) else None
    if status != 200 or isinstance(nid, bool) or not isinstance(nid, int) or nid <= 0:
        raise RunFailure(f"broadcast_create_status_{status}")
    return nid


def check_newsletter(api, nid, data):
    contents = get(api, f"/newsletters/{nid}/contents", "template_contents").get("contents")
    if not isinstance(contents, list) or len(contents) != 1:
        raise RunFailure("template_not_background")
    content = contents[0]
    if not isinstance(content, dict) or content.get("type") != "push" or content.get("push_mode") != "background" or any(
        content.get(field) for field in ("subject", "body", "image_url")
    ) or content.get("custom_data") != data:
        raise RunFailure("broadcast_readback_mismatch")


def send_broadcast(api, nid):
    try:
        status, _ = api.call("POST", f"/newsletters/{nid}/send", {})
    except TransportError:
        raise RunFailure("send_outcome_ambiguous_not_retried") from None
    if status != 200:
        raise RunFailure(f"send_status_{status}")


def broadcast_delivery(api, nid, cio_id, token):
    try:
        status, body = api.call("GET", f"/newsletters/{nid}/messages?limit=10")
    except TransportError:
        return None
    if status != 200 or not isinstance(body, dict) or not isinstance(body.get("messages"), list):
        return None
    rows = body["messages"]
    if len(rows) > 1:
        raise RunFailure("broadcast_delivery_not_unique")
    if not rows:
        return None
    row = rows[0]
    if not isinstance(row, dict) or row.get("type") != "push" or not row.get("id"):
        raise RunFailure("delivery_not_push")
    identifiers = row.get("customer_identifiers") or {}
    if identifiers.get("cio_id") != cio_id:
        raise RunFailure("broadcast_wrong_customer")
    metrics = row.get("metrics") or {}
    if any(metrics.get(m) for m in FAILED_METRICS):
        raise RunFailure("backend_reported_failure")
    # Recipient is populated by the sent event. A queued row can still be empty.
    if not row.get("recipient") and not metrics.get("sent"):
        return None
    if row.get("recipient") != token:
        raise RunFailure("broadcast_recipient_mismatch")
    return str(row["id"])


def message_metrics(api, path, delivery_id):
    try:
        status, body = api.call("GET", path)
    except TransportError:
        return None  # a GET is safe to repeat on the next poll
    if status != 200 or not isinstance(body, dict):
        return None
    for message in body.get("messages") or []:
        if isinstance(message, dict) and str(message.get("id")) == delivery_id:
            if message.get("type") != "push":
                raise RunFailure("delivery_not_push")
            return message.get("metrics") or {}
    return None


def await_outcome(api, device, clock, opts, cio_id, delivery_id, started_ms, before, evidence, identity_check=None):
    deadline = clock.monotonic() + opts.timeout
    path = f"/customers/{quote(cio_id, safe='')}/messages?limit=50"
    while True:
        identity_verified = True
        if identity_check is not None:
            found = identity_check()
            identity_verified = found == delivery_id
            if found is not None and not identity_verified:
                raise RunFailure("broadcast_delivery_changed")
        metrics = message_metrics(api, path, delivery_id)
        if metrics is not None:
            if any(metrics.get(m) for m in FAILED_METRICS):
                raise RunFailure("backend_reported_failure")
            if any(metrics.get(m) for m in INTERACTION_METRICS):
                raise RunFailure("unexpected_open_or_click")
            evidence["backend_sent_metric"] = bool(metrics.get("sent"))
            evidence["backend_delivered_metric"] = bool(metrics.get("delivered"))
        rows = [r for r in device.callbacks() if r.get("delivery_id") == delivery_id]
        if any(r.get("data") != opts.data for r in rows):
            raise RunFailure("callback_data_mismatch")
        if any(
            isinstance(r.get("received_at_ms"), bool)
            or not isinstance(r.get("received_at_ms"), (int, float))
            or not math.isfinite(r["received_at_ms"])
            or r["received_at_ms"] < started_ms - CLOCK_SKEW_MS
            for r in rows
        ):
            raise RunFailure("callback_before_send")
        # Delivery is at least once, so duplicate rows for the ID are allowed.
        evidence["callback_count"] = len(rows)
        evidence["device_callback_matched"] = bool(rows)
        if before is not None:
            unchanged = device.notification_snapshot().issubset(before)
            evidence["android_no_added_notification_observed"] = unchanged
            if not unchanged:
                raise RunFailure("visible_notification_posted")
        if identity_verified and rows and evidence["backend_sent_metric"] and evidence["backend_delivered_metric"]:
            return
        if clock.monotonic() >= deadline:
            raise RunFailure("timed_out_waiting_for_" + ("delivered_metric" if rows else "callback"))
        clock.sleep(POLL_SECONDS)


def execute(opts, api, device, clock=Clock, stdin=sys.stdin, stdout=sys.stdout):
    evidence = {
        "replay_or_debug_broadcast_used": False,
        "api_send_accepted": False,
        "backend_sent_metric": False,
        "backend_delivered_metric": False,
        "device_callback_matched": False,
        "callback_count": 0,
        "app_backgrounded": None,
        "android_no_added_notification_observed": None,
        "ios_no_display_verified": False if opts.platform == "ios" else None,
        "broadcast_created": False,
        "broadcast_readback_matched": False,
        "delivery_id_discovered": False,
    }
    result = {"result": "failed", "reason": None, "platform": opts.platform, "run_id": None, "delivery_id": None, "newsletter_id": None, "evidence": evidence}
    try:
        validate(opts)
        result["run_id"] = opts.data["run_id"]
        broadcast = getattr(opts, "create_broadcast", False)
        if not broadcast:
            check_template(api, opts.transactional_id)
        evidence["app_backgrounded"] = device.preflight()
        cio_id = lookup_customer(api, opts.email)
        token = eligible_device(api, cio_id, opts.platform, single_device=broadcast)
        if broadcast:
            result["newsletter_id"] = nid = create_broadcast(api, opts)
            evidence["broadcast_created"] = True
            check_newsletter(api, nid, opts.data)
            evidence["broadcast_readback_matched"] = True
        if opts.platform == "ios":
            if opts.send_now:
                evidence["app_backgrounded"] = "operator_unconfirmed"
            else:
                confirm_send(stdin, stdout)
                evidence["app_backgrounded"] = "operator_confirmed"
        before = device.notification_snapshot()
        started_ms = clock.now_ms()
        identity_check = None
        if broadcast:
            send_broadcast(api, nid)
            evidence["api_send_accepted"] = True
            identity_check = lambda: broadcast_delivery(api, nid, cio_id, token)
            deadline = clock.monotonic() + opts.timeout
            while result["delivery_id"] is None:
                result["delivery_id"] = identity_check()
                if result["delivery_id"] is not None:
                    evidence["delivery_id_discovered"] = True
                    break
                if clock.monotonic() >= deadline:
                    raise RunFailure("broadcast_no_delivery_timed_out")
                clock.sleep(POLL_SECONDS)
        else:
            result["delivery_id"] = send(api, opts, token)
            evidence["api_send_accepted"] = True
        await_outcome(api, device, clock, opts, cio_id, result["delivery_id"], started_ms, before, evidence, identity_check)
        result["result"], result["reason"] = "passed", "delivered_and_callback_matched"
    except RunFailure as failure:
        result["reason"] = failure.reason
    return result


def api_base_ok(base):
    parsed = urlparse(base)
    if parsed.username or parsed.password or parsed.query or parsed.fragment or not parsed.hostname:
        return False
    return parsed.scheme == "https" or (parsed.scheme == "http" and parsed.hostname in ("localhost", "127.0.0.1"))


def load_data(value):
    text = value if value.lstrip().startswith("{") else Path(value).read_text()
    return json.loads(text)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--api-base", required=True, help="App API base URL; there is no default")
    parser.add_argument("--email", required=True, help="fresh maestro+e2e-...@cio.test profile")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--transactional-id", type=int)
    mode.add_argument("--create-broadcast", action="store_true", help="create a fresh background broadcast for this profile only")
    parser.add_argument("--platform", choices=("android", "ios"), required=True)
    parser.add_argument("--device", required=True, help="adb serial or simulator UDID")
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--data", required=True, help="flat JSON string map, inline or a file path; must include run_id")
    parser.add_argument("--send-now", action="store_true", help="iOS: skip the READY_FOR_PROVIDER_SEND confirmation")
    parser.add_argument("--timeout", type=int, default=120, help="seconds, 10 to 300")
    opts = parser.parse_args(argv)
    if not 10 <= opts.timeout <= 300:
        parser.error("--timeout must be between 10 and 300")
    if not api_base_ok(opts.api_base):
        parser.error("--api-base must be https, or http on localhost")
    key = os.environ.get("MAESTRO_APP_API_KEY", "")
    if not key:
        parser.error("MAESTRO_APP_API_KEY is not set")
    try:
        opts.data = load_data(opts.data)
    except (OSError, ValueError):
        parser.error("--data is not readable JSON")
    device = AndroidDevice(opts.device, opts.app_id) if opts.platform == "android" else IOSSimulator(opts.device, opts.app_id)
    result = execute(opts, Api(opts.api_base, key), device)
    print(json.dumps(result, sort_keys=True))
    return 0 if result["result"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
