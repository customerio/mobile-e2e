import io
import json
import unittest
from types import SimpleNamespace

from scripts import run_background_push as rbp

EMAIL = "maestro+e2e-run42abc@cio.test"
DATA = {"run_id": "run42abc", "order": "42"}
TOKEN = "synthetic-device-token"
CAPABLE = {"id": TOKEN, "platform": "android", "attributes": {rbp.CAPABILITY: "1"}}
ROW = {"delivery_id": "dlv-1", "received_at_ms": 1_000_500, "data": DATA}


class FakeApi:
    """Mocked public API that records every call."""

    def __init__(self, devices=(CAPABLE,), metrics=None, post_error=None, mode="background"):
        self.calls, self.devices, self.metrics, self.post_error = [], list(devices), metrics or {}, post_error
        self.mode = mode

    def call(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method == "POST":
            if self.post_error:
                raise self.post_error
            return 200, {"delivery_id": "dlv-1", "queued_at": 1}
        if path.startswith("/customers?email="):
            return 200, {"results": [{"cio_id": "cio-1", "email": EMAIL}]}
        if path.endswith("/attributes?id_type=cio_id"):
            return 200, {"customer": {"devices": self.devices}}
        if path.endswith("/contents"):
            return 200, {"contents": [{"type": "push", "push_mode": self.mode, "subject": "", "body": ""}]}
        return 200, {"messages": [{"id": "dlv-1", "type": "push", "metrics": self.metrics}]}

    def posts(self):
        return [c for c in self.calls if c[0] == "POST"]


class FakeDevice:
    """Mocked device. Callbacks and notification changes appear after the POST."""

    def __init__(self, api, rows=(), notifications=(frozenset(), frozenset())):
        self.api, self.rows, self.notifications = api, list(rows), notifications

    def preflight(self):
        return "adb_home"

    def callbacks(self):
        return self.rows if self.api.posts() else []

    def notification_snapshot(self):
        if self.notifications is None:
            return None
        return self.notifications[1 if self.api.posts() else 0]


class FakeClock:
    def __init__(self):
        self.t = 0.0

    def monotonic(self):
        return self.t

    def now_ms(self):
        return 1_000_000 + int(self.t * 1000)

    def sleep(self, seconds):
        self.t += seconds


def opts(**changes):
    values = dict(email=EMAIL, transactional_id=7, platform="android", data=dict(DATA), send_now=False, timeout=30)
    values.update(changes)
    return SimpleNamespace(**values)


def execute(o, api, device, stdin=""):
    return rbp.execute(o, api, device, FakeClock(), io.StringIO(stdin), io.StringIO())


class RunBackgroundPushTest(unittest.TestCase):
    def test_refuses_a_visible_template_before_sending(self):
        api = FakeApi(mode="visible")
        result = execute(opts(), api, FakeDevice(api))
        self.assertEqual(result["reason"], "template_not_background")
        self.assertEqual(api.posts(), [])

    def test_ios_accepts_native_fractional_millisecond_timestamp(self):
        api = FakeApi(devices=[dict(CAPABLE, platform="ios")], metrics={"sent": 1, "delivered": 2})
        row = dict(ROW, received_at_ms=1_000_500.25)
        result = execute(opts(platform="ios"), api, FakeDevice(api, rows=[row], notifications=None), stdin="SEND\n")
        self.assertEqual(result["result"], "passed")
        self.assertFalse(result["evidence"]["ios_no_display_verified"])

    def test_refuses_non_synthetic_email_before_any_request(self):
        api = FakeApi()
        result = execute(opts(email="someone@example.com"), api, FakeDevice(api))
        self.assertEqual(result["reason"], "email_not_fresh_synthetic")
        self.assertEqual(api.calls, [])

    def test_ios_sends_nothing_until_operator_confirms(self):
        api = FakeApi(devices=[dict(CAPABLE, platform="ios")])
        result = execute(opts(platform="ios"), api, FakeDevice(api, notifications=None), stdin="")
        self.assertEqual(result["reason"], "send_not_confirmed")
        self.assertEqual(api.posts(), [])

    def test_refuses_ambiguous_or_incapable_devices_before_send(self):
        cases = {
            "ambiguous_eligible_devices": [CAPABLE, dict(CAPABLE, id="other-synthetic-token")],
            "no_eligible_device": [dict(CAPABLE, attributes={})],
        }
        for reason, devices in cases.items():
            with self.subTest(reason):
                api = FakeApi(devices=devices)
                self.assertEqual(execute(opts(), api, FakeDevice(api))["reason"], reason)
                self.assertEqual(api.posts(), [])

    def test_sent_metric_alone_does_not_pass(self):
        cases = {"timed_out_waiting_for_callback": [], "timed_out_waiting_for_delivered_metric": [ROW]}
        for reason, rows in cases.items():
            with self.subTest(reason):
                api = FakeApi(metrics={"sent": 1})
                result = execute(opts(), api, FakeDevice(api, rows=rows))
                self.assertEqual((result["result"], result["reason"]), ("failed", reason))
                self.assertTrue(result["evidence"]["backend_sent_metric"])
                self.assertFalse(result["evidence"]["backend_delivered_metric"])

    def test_callback_with_different_data_fails(self):
        api = FakeApi(metrics={"sent": 1, "delivered": 2})
        row = dict(ROW, data={"run_id": "run42abc", "order": "43"})
        self.assertEqual(execute(opts(), api, FakeDevice(api, rows=[row]))["reason"], "callback_data_mismatch")

    def test_visible_android_notification_fails(self):
        api = FakeApi(metrics={"sent": 1, "delivered": 2})
        result = execute(opts(), api, FakeDevice(api, rows=[ROW], notifications=(frozenset(), frozenset({"new notification"}))))
        self.assertEqual(result["reason"], "visible_notification_posted")

    def test_dismissed_notification_cannot_hide_a_new_notification(self):
        api = FakeApi(metrics={"sent": 1, "delivered": 2})
        device = FakeDevice(api, rows=[ROW], notifications=(frozenset({"old notification"}), frozenset({"new notification"})))
        self.assertEqual(execute(opts(), api, device)["reason"], "visible_notification_posted")

    def test_ambiguous_send_timeout_is_not_retried(self):
        api = FakeApi(post_error=rbp.TransportError())
        result = execute(opts(), api, FakeDevice(api))
        self.assertEqual(result["reason"], "send_outcome_ambiguous_not_retried")
        self.assertEqual(len(api.posts()), 1)

    def test_delivered_metric_and_matching_callback_pass(self):
        api = FakeApi(metrics={"sent": 1, "delivered": 2})
        result = execute(opts(), api, FakeDevice(api, rows=[ROW, ROW]))  # duplicate delivery is allowed
        self.assertEqual(result["result"], "passed")
        self.assertEqual(result["evidence"]["callback_count"], 2)
        self.assertTrue(result["evidence"]["provider_traversed"])
        self.assertTrue(result["evidence"]["android_no_added_notification_observed"])
        (_, path, body), = api.posts()
        self.assertEqual(path, "/send/push")
        self.assertEqual(body, {"transactional_message_id": 7, "identifiers": {"email": EMAIL}, "to": TOKEN, "custom_data": DATA, "queue_draft": False})
        self.assertNotIn(TOKEN, json.dumps(result))



class BroadcastApi(FakeApi):
    def __init__(self, send_error=None, create_error=None, readback=None, deliveries=None, **kwargs):
        super().__init__(metrics={"sent":1,"delivered":2}, **kwargs)
        self.send_error = send_error
        self.create_error = create_error
        self.readback = readback
        self.deliveries = deliveries if deliveries is not None else [{"id":"dlv-1","type":"push","recipient":TOKEN,"customer_identifiers":{"cio_id":"cio-1"},"metrics":{"sent":1}}]

    def call(self,method,path,body=None):
        if path == "/newsletters" and method == "POST":
            self.calls.append((method,path,body))
            if self.create_error:
                raise self.create_error
            return 200,{"newsletter":{"id":9,"send_state":"draft"}}
        if path == "/newsletters/9/contents":
            self.calls.append((method,path,body))
            return 200,{"contents":self.readback if self.readback is not None else [{"type":"push","push_mode":"background","subject":"","body":"","custom_data":DATA}]}
        if path == "/newsletters/9/send":
            self.calls.append((method,path,body))
            if self.send_error:
                raise self.send_error
            return 200,{}
        if path.startswith("/newsletters/9/messages"):
            self.calls.append((method,path,body))
            return 200,{"messages":self.deliveries}
        return super().call(method,path,body)


class BroadcastDevice(FakeDevice):
    def notification_snapshot(self):
        if self.notifications is None:
            return None
        sent=any(method == "POST" and path.endswith("/send") for method,path,_ in self.api.calls)
        return self.notifications[1 if sent else 0]

    def callbacks(self):
        sent=any(method == "POST" and path.endswith("/send") for method,path,_ in self.api.calls)
        return self.rows if sent else []


class RunBackgroundBroadcastTest(unittest.TestCase):
    def test_creates_only_own_audience_and_checks_real_delivery_callback(self):
        api=BroadcastApi()
        result=execute(opts(transactional_id=None,create_broadcast=True),api,BroadcastDevice(api,rows=[ROW]))
        self.assertEqual(result["result"],"passed",result)
        self.assertEqual(result["delivery_id"],"dlv-1")
        self.assertEqual(result["newsletter_id"],9)
        self.assertEqual(api.posts(),[
            ("POST","/newsletters",{"name":"Background push E2E run42abc","type":"push","push_mode":"background","custom_data":DATA,"recipients":{"and":[{"attribute":{"field":"email","operator":"eq","value":EMAIL}}]}}),
            ("POST","/newsletters/9/send",{}),
        ])
        self.assertFalse(result["evidence"]["replay_or_debug_broadcast_used"])

    def test_ambiguous_send_is_never_retried(self):
        api=BroadcastApi(send_error=rbp.TransportError())
        result=execute(opts(transactional_id=None,create_broadcast=True),api,BroadcastDevice(api))
        self.assertEqual(result["reason"],"send_outcome_ambiguous_not_retried")
        self.assertEqual(len([c for c in api.posts() if c[1].endswith("/send")]),1)

    def test_no_capable_device_cannot_create_or_send_broadcast(self):
        api=BroadcastApi(devices=[])
        result=execute(opts(transactional_id=None,create_broadcast=True),api,BroadcastDevice(api))
        self.assertEqual(result["reason"],"no_eligible_device")
        self.assertEqual(api.posts(),[])

    def test_multiple_deliveries_are_not_accepted_as_the_test_delivery(self):
        row={"id":"dlv-1","type":"push","recipient":TOKEN,"customer_identifiers":{"cio_id":"cio-1"},"metrics":{"sent":1}}
        api=BroadcastApi(deliveries=[row,dict(row,id="other")])
        result=execute(opts(transactional_id=None,create_broadcast=True),api,BroadcastDevice(api,rows=[ROW]))
        self.assertEqual(result["reason"],"broadcast_delivery_not_unique")

    def test_readback_mismatch_never_sends(self):
        background={"type":"push","push_mode":"background","subject":"","body":"","custom_data":DATA}
        for contents in [[dict(background,push_mode="")],[dict(background,custom_data={"run_id":"wrong"})],[background,background]]:
            with self.subTest(contents=contents):
                api=BroadcastApi(readback=contents)
                result=execute(opts(transactional_id=None,create_broadcast=True),api,BroadcastDevice(api))
                self.assertEqual(result["result"],"failed")
                self.assertFalse(any(path.endswith("/send") for _,path,_ in api.posts()))

    def test_extra_device_is_rejected_before_creating_any_draft(self):
        api=BroadcastApi(devices=[CAPABLE,{"id":"other","platform":"ios","attributes":{}}])
        result=execute(opts(transactional_id=None,create_broadcast=True),api,BroadcastDevice(api))
        self.assertEqual(result["reason"],"profile_has_other_devices")
        self.assertEqual(api.posts(),[])

    def test_ambiguous_create_is_not_retried_and_never_sends(self):
        api=BroadcastApi(create_error=rbp.TransportError())
        result=execute(opts(transactional_id=None,create_broadcast=True),api,BroadcastDevice(api))
        self.assertEqual(result["reason"],"broadcast_create_ambiguous_not_retried")
        self.assertEqual(len(api.posts()),1)

    def test_wrong_customer_or_recipient_cannot_be_the_discovered_delivery(self):
        for fields,reason in [({"customer_identifiers":{"cio_id":"other"}},"broadcast_wrong_customer"),({"recipient":"other"},"broadcast_recipient_mismatch")]:
            with self.subTest(reason=reason):
                row={"id":"dlv-1","type":"push","recipient":TOKEN,"customer_identifiers":{"cio_id":"cio-1"},"metrics":{"sent":1}}
                api=BroadcastApi(deliveries=[dict(row,**fields)])
                result=execute(opts(transactional_id=None,create_broadcast=True),api,BroadcastDevice(api,rows=[ROW]))
                self.assertEqual(result["reason"],reason)

    def test_created_draft_is_not_evidence_of_a_callback_after_the_send(self):
        api=BroadcastApi()
        old_row=dict(ROW,received_at_ms=995_000)
        result=execute(opts(transactional_id=None,create_broadcast=True),api,BroadcastDevice(api,rows=[old_row]))
        self.assertEqual(result["reason"],"callback_before_send")

    def test_later_extra_delivery_cannot_pass_after_first_delivery_was_discovered(self):
        class GrowingBroadcastApi(BroadcastApi):
            def call(self,method,path,body=None):
                result=super().call(method,path,body)
                if path.startswith("/newsletters/9/messages") and len(self.deliveries)==1:
                    self.deliveries=self.deliveries+[dict(self.deliveries[0],id="second")]
                return result
        api=GrowingBroadcastApi()
        result=execute(opts(transactional_id=None,create_broadcast=True),api,BroadcastDevice(api,rows=[ROW]))
        self.assertEqual(result["reason"],"broadcast_delivery_not_unique")


if __name__ == "__main__":
    unittest.main()
