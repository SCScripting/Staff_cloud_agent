"""Tests for the box-side survey collector. No Tactical server is contacted."""

import csv
import json
import os
import tempfile
import unittest
import zipfile
from xml.etree import ElementTree

import collect_surveys as collector


SURVEY = {
    "computer": "FRONT DESK",
    "time": "2026-10-20T01:00:00",
    "result": "Pass",
    "summary": "Replacement survey collected.",
    "identity": {
        "manufacturer": "Dell Inc.",
        "model": "OptiPlex 7000",
        "serial": "ABC123",
        "sku": "n/a",
        "biosVersion": "1.2.3",
        "biosDate": "2024-05-01",
        "smbiosVersion": "3.3",
        "shipDate": "estimated from Dell PPID 2023-11-26 (week 48)",
    },
    "formFactor": {"size": "Small", "name": "Desktop", "detail": "Desktop; model indicates Small"},
    "display": {"reported": "HDMI x1", "source": "monitor connection", "gpu": []},
    "monitor": {"count": 2, "external": 2, "item": []},
    "cpu": [{"name": "Intel Core i5-12500", "core": "6"}],
    "memory": {"total": "16", "slots": "2 of 4", "max": "64", "dimm": []},
    "storage": {"disk": [], "volume": []},
    "network": {"ethernet": [], "wifi": [], "bluetooth": "none"},
    "port": {"usb": "USB 3.x x1", "com": "COM3", "parallel": "none", "thunderbolt": "no", "device": []},
    "printer": [],
    "os": {
        "caption": "Microsoft Windows 11 Pro",
        "build": "26100",
        "membership": "Workgroup WORKGROUP",
        "readiness": "Already Windows 11. Readiness checks passed.",
        "server": "no",
        "role": [],
        "software": [{"Label": "Dentrix", "Name": "Dentrix G7", "Version": "17"}],
    },
    "power": "No battery",
    "note": ["Needs VGA output", "Uses 2 monitors", "Needs COM port"],
    "problem": [],
}


def survey_stdout():
    body = json.dumps(SURVEY, separators=(",", ":"))
    return "Replacement survey\nComputer: FRONT DESK\n" + body + "\nEXITCODE: 0\n"


class FakeResponse:
    def __init__(self, payload, status=200):
        self.status_code = status
        self.headers = {"content-type": "application/json"}
        self._payload = payload
        self.text = payload if isinstance(payload, str) else json.dumps(payload)

    def json(self):
        if isinstance(self._payload, str):
            return json.loads(self._payload)
        return self._payload


class FakeSession:
    def __init__(self, routes):
        self.headers = {}
        self.routes = routes
        self.calls = []

    def get(self, url, params=None, timeout=None):
        path = url.split(".com", 1)[-1]
        self.calls.append(("GET", path, params))
        return FakeResponse(self.routes[("GET", path)])

    def post(self, url, json=None, timeout=None):
        path = url.split(".com", 1)[-1]
        self.calls.append(("POST", path, json))
        key = ("POST", path)
        if key not in self.routes:
            raise AssertionError("unexpected POST " + path)
        return FakeResponse(self.routes[key])


def history_record(agent_id, when, stdout, name="Get-ReplacementSurvey"):
    return {
        "id": 10,
        "time": when,
        "script_name": name,
        "agent_id": agent_id,
        "script_results": {"stdout": stdout, "stderr": "", "retcode": 0},
    }


class ParseTests(unittest.TestCase):
    def test_reads_the_json_line_before_exitcode(self):
        survey = collector.parse_survey_output(survey_stdout())
        self.assertEqual(survey["computer"], "FRONT DESK")
        self.assertEqual(survey["note"][0], "Needs VGA output")

    def test_reads_stdout_nested_in_script_results(self):
        text = collector.output_text(
            {"script_results": {"stdout": survey_stdout(), "retcode": 0}}
        )
        self.assertIn("FRONT DESK", collector.parse_survey_output(text)["computer"])

    def test_keeps_the_newest_run_for_each_agent(self):
        agent = "abcd1234efgh5678"
        older = history_record(agent, "2026-10-01T00:00:00Z", "{}")
        newer = history_record(agent, "2026-10-20T00:00:00Z", survey_stdout())
        other = history_record(agent, "2026-10-19T00:00:00Z", "nope", name="Other")
        chosen = collector.latest_by_agent([older, newer, other], "Get-ReplacementSurvey")
        self.assertEqual(chosen[agent]["time"], "2026-10-20T00:00:00Z")


class SafetyTests(unittest.TestCase):
    def test_get_allowlist_rejects_reboot_shutdown_and_commands(self):
        for path in (
            "agents/abcd1234efgh5678/reboot/",
            "agents/abcd1234efgh5678/shutdown/",
            "agents/abcd1234efgh5678/cmd/",
            "agents/update/",
            "agents/maintenance/bulk/",
        ):
            with self.assertRaises(collector.CollectorError):
                collector.read_path(path)

    def test_run_path_is_only_runscript(self):
        self.assertEqual(
            collector.run_script_path("abcd1234efgh5678"),
            "agents/abcd1234efgh5678/runscript/",
        )
        with self.assertRaises(collector.CollectorError):
            collector.run_script_path("reboot")


class CollectTests(unittest.TestCase):
    def setUp(self):
        self.agent_id = "abcd1234efgh5678"
        self.client_routes = {
            ("GET", "/clients/"): [{"id": 4, "name": "Front Desk Dental"}],
            ("GET", "/agents/"): [
                {
                    "agent_id": self.agent_id,
                    "hostname": "FRONT-DESK",
                    "client": "Front Desk Dental",
                    "site": "Office",
                }
            ],
        }

    def test_history_is_saved_and_run_is_not_called(self):
        routes = dict(self.client_routes)
        routes[("GET", "/agents/scripthistory/")] = [
            history_record(self.agent_id, "2026-10-20T00:00:00Z", survey_stdout())
        ]
        session = FakeSession(routes)
        tactical = collector.TacticalClient(
            "https://api.standardcomputer.com", "test-key", session=session
        )
        self.assertEqual(session.headers["X-API-KEY"], "test-key")
        with tempfile.TemporaryDirectory() as folder:
            code = collector.collect(
                client="Front Desk Dental",
                agents=[],
                out_dir=folder,
                run=True,
                script_name="Get-ReplacementSurvey",
                script_id=None,
                timeout=300,
                tactical=tactical,
            )
            self.assertEqual(code, 0)
            self.assertFalse(any(call[0] == "POST" for call in session.calls))
            with open(os.path.join(folder, "FRONT_DESK.json"), encoding="utf-8") as handle:
                saved = json.load(handle)
            self.assertEqual(saved["source"], "history")
            self.assertEqual(saved["survey"]["identity"]["serial"], "ABC123")
            with open(os.path.join(folder, "surveys.csv"), encoding="utf-8", newline="") as handle:
                rows = list(csv.DictReader(handle))
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["manufacturer"], "Dell Inc.")
            self.assertEqual(rows[0]["form_factor"], "Small")
            self.assertEqual(
                rows[0]["replacement_notes"],
                "Needs VGA output | Uses 2 monitors | Needs COM port",
            )
            self.assertEqual(rows[0]["dental_software"], "Dentrix 17")
            with zipfile.ZipFile(os.path.join(folder, "surveys.xlsx")) as package:
                sheet = package.read("xl/worksheets/sheet1.xml")
            root = ElementTree.fromstring(sheet)
            namespace = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
            texts = [node.text or "" for node in root.findall(".//m:t", namespace)]
            self.assertIn("replacement_notes", texts)
            self.assertIn("Needs VGA output | Uses 2 monitors | Needs COM port", texts)

    def test_missing_history_stays_read_only_without_run(self):
        routes = dict(self.client_routes)
        routes[("GET", "/agents/scripthistory/")] = []
        session = FakeSession(routes)
        tactical = collector.TacticalClient(
            "https://api.standardcomputer.com", "test-key", session=session
        )
        with tempfile.TemporaryDirectory() as folder:
            code = collector.collect(
                client="4",
                agents=[],
                out_dir=folder,
                run=False,
                script_name="Get-ReplacementSurvey",
                script_id=None,
                timeout=300,
                tactical=tactical,
            )
            self.assertEqual(code, 1)
            self.assertFalse(any(call[0] == "POST" for call in session.calls))
            with open(os.path.join(folder, "surveys.csv"), encoding="utf-8", newline="") as handle:
                self.assertEqual(list(csv.DictReader(handle)), [])

    def test_run_posts_only_the_survey_script(self):
        routes = dict(self.client_routes)
        routes[("GET", "/agents/{0}/".format(self.agent_id))] = {
            "agent_id": self.agent_id,
            "hostname": "FRONT-DESK",
            "client": {"name": "Front Desk Dental"},
            "site": {"name": "Office"},
        }
        routes[("GET", "/agents/scripthistory/")] = []
        routes[("GET", "/scripts/")] = [
            {"id": 89, "name": "Get-ReplacementSurvey", "shell": "powershell"},
            {"id": 3, "name": "Other", "shell": "powershell"},
        ]
        routes[("POST", "/agents/{0}/runscript/".format(self.agent_id))] = {
            "stdout": survey_stdout(),
            "stderr": "",
            "retcode": 0,
        }
        session = FakeSession(routes)
        tactical = collector.TacticalClient(
            "https://api.standardcomputer.com", "test-key", session=session
        )
        with tempfile.TemporaryDirectory() as folder:
            code = collector.collect(
                client=None,
                agents=[self.agent_id],
                out_dir=folder,
                run=True,
                script_name="Get-ReplacementSurvey",
                script_id=None,
                timeout=300,
                tactical=tactical,
            )
            self.assertEqual(code, 0)
        posts = [call for call in session.calls if call[0] == "POST"]
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0][1], "/agents/{0}/runscript/".format(self.agent_id))
        body = posts[0][2]
        self.assertEqual(body["script"], 89)
        self.assertEqual(body["output"], "wait")
        self.assertEqual(body["args"], [])
        self.assertEqual(body["run_as_user"], False)
        self.assertNotIn("reboot", json.dumps(body))
        gets = [call[1] for call in session.calls if call[0] == "GET"]
        self.assertIn("/agents/{0}/".format(self.agent_id), gets)
        self.assertIn("/agents/scripthistory/", gets)


if __name__ == "__main__":
    unittest.main()
