#!/usr/bin/env python3
"""Collect Get-ReplacementSurvey results from Tactical RMM.

This runs on the Standard Computer box, not on the dental PC. The PC script
does not contain an API key. Set TACTICAL_API_URL and TACTICAL_API_KEY in the
environment. The key is sent only as the X-API-KEY header.

By default the tool reads script history with GET. It does not reboot, shut
down, restart, or edit agents. --run is the only write, and it POSTs
/agents/<agent_id>/runscript/ for Get-ReplacementSurvey alone, and only for
agents whose latest history has no survey JSON.

Usage:
  python collect_surveys.py --client "Front Desk Dental" --out ./surveys
  python collect_surveys.py --out ./surveys AGENTID1 AGENTID2
  python collect_surveys.py --client "Front Desk Dental" --run --out ./surveys
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import zipfile
from xml.sax.saxutils import escape

import requests

DEFAULT_API_URL = "https://api.standardcomputer.com"
DEFAULT_SCRIPT_NAME = "Get-ReplacementSurvey"
SURVEY_SCRIPT_TIMEOUT = 300

RESERVED_SEGMENTS = {
    "actions",
    "bulkrecovery",
    "checks",
    "cmd",
    "eventlog",
    "history",
    "installer",
    "maintenance",
    "meshcentral",
    "notes",
    "pendingactions",
    "ping",
    "processes",
    "reboot",
    "recover",
    "registry",
    "scripthistory",
    "shutdown",
    "tasks",
    "update",
    "versions",
    "wmi",
    "wol",
}

AGENT_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{7,}$")

COLUMNS = (
    "agent_id",
    "hostname",
    "client",
    "site",
    "source",
    "history_time",
    "computer",
    "survey_time",
    "result",
    "summary",
    "manufacturer",
    "model",
    "serial",
    "sku",
    "bios_version",
    "bios_date",
    "smbios_version",
    "ship_date",
    "form_factor",
    "form_detail",
    "display_outputs",
    "gpus",
    "monitor_count",
    "external_monitors",
    "monitors",
    "cpu",
    "ram_gb",
    "ram_slots",
    "ram_max_gb",
    "dimms",
    "disks",
    "volumes",
    "ethernet",
    "wifi",
    "bluetooth",
    "usb",
    "com",
    "parallel",
    "thunderbolt",
    "usb_devices",
    "printers",
    "os",
    "os_build",
    "membership",
    "win11_readiness",
    "windows_server",
    "server_roles",
    "dental_software",
    "power",
    "replacement_notes",
    "collection_gaps",
)


class CollectorError(Exception):
    """The collector cannot continue because of arguments or the API."""


def as_list(payload):
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict) and isinstance(payload.get("results"), list):
        return payload["results"]
    raise CollectorError("Tactical returned a response that is not a list.")


def pick_name(value):
    if isinstance(value, dict):
        return str(value.get("name") or "")
    if value is None:
        return ""
    return str(value)


def normalize_agent(row):
    if not isinstance(row, dict):
        raise CollectorError("Tactical returned an agent record that is not an object.")
    site = row.get("site")
    client = row.get("client")
    if not client and isinstance(site, dict):
        client = site.get("client")
    agent_id = str(row.get("agent_id") or "")
    return {
        "agent_id": agent_id,
        "hostname": str(row.get("hostname") or ""),
        "client": pick_name(client),
        "site": pick_name(site),
    }


def find_client(clients, text):
    wanted = str(text).strip()
    if not wanted:
        raise CollectorError("Client name is empty.")
    if wanted.isdigit():
        for client in clients:
            if str(client.get("id")) == wanted:
                return client
        raise CollectorError("No client has id {0}.".format(wanted))
    matches = [
        client
        for client in clients
        if str(client.get("name") or "").lower() == wanted.lower()
    ]
    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise CollectorError("No client is named {0}.".format(wanted))
    raise CollectorError("More than one client is named {0}.".format(wanted))


def find_script_id(scripts, name, script_id=None):
    if script_id is not None:
        return int(script_id)
    matches = [script for script in scripts if script.get("name") == name]
    powershell = [
        script
        for script in matches
        if str(script.get("shell") or "powershell").lower() in ("powershell", "pwsh")
    ]
    chosen = powershell or matches
    if len(chosen) != 1:
        raise CollectorError(
            "Expected one Script Manager entry named {0}.".format(name)
        )
    return int(chosen[0]["id"])


def _normalize_path(path):
    text = str(path).strip().lstrip("/")
    if not text.endswith("/"):
        text += "/"
    return text


def validate_agent_id(agent_id):
    text = str(agent_id or "")
    if text in RESERVED_SEGMENTS or not AGENT_ID_PATTERN.match(text):
        raise CollectorError("Agent id is not valid.")
    return text


def read_path(path):
    """Return a GET path, or raise if it is not a read endpoint."""
    text = _normalize_path(path)
    if text in ("clients/", "scripts/", "agents/", "agents/scripthistory/"):
        return text
    if re.fullmatch(r"clients/\d+/", text) or re.fullmatch(r"scripts/\d+/", text):
        return text
    history = re.fullmatch(r"agents/([^/]+)/history/", text)
    if history:
        validate_agent_id(history.group(1))
        return text
    agent = re.fullmatch(r"agents/([^/]+)/", text)
    if agent:
        validate_agent_id(agent.group(1))
        return text
    raise CollectorError("Refusing to read {0}.".format(text))


def run_script_path(agent_id):
    agent = validate_agent_id(agent_id)
    return "agents/{0}/runscript/".format(agent)


def record_time(record):
    value = record.get("time") if isinstance(record, dict) else None
    return str(value or "")


def latest_by_agent(records, script_name):
    chosen = {}
    for record in records:
        if not isinstance(record, dict):
            continue
        if script_name and record.get("script_name") != script_name:
            continue
        agent_id = str(record.get("agent_id") or "")
        if not agent_id:
            continue
        current = chosen.get(agent_id)
        if current is None or record_time(record) >= record_time(current):
            chosen[agent_id] = record
    return chosen


def output_text(payload):
    if isinstance(payload, str):
        stripped = payload.strip()
        if stripped.startswith("{") or stripped.startswith("["):
            try:
                decoded = json.loads(stripped)
            except json.JSONDecodeError:
                return payload
            if isinstance(decoded, dict) and any(
                key in decoded for key in ("stdout", "output", "script_results")
            ):
                return output_text(decoded)
        return payload
    if not isinstance(payload, dict):
        return ""
    nested = payload.get("script_results")
    if nested is not None and nested is not payload:
        text = output_text(nested)
        if text.strip():
            return text
    for key in ("stdout", "output"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value
    results = payload.get("results")
    if isinstance(results, str):
        return results
    return ""


def parse_survey_output(text):
    """Return the survey object from summary text plus one JSON line."""
    chosen = None
    for line in str(text or "").splitlines():
        stripped = line.strip()
        if not stripped.startswith("{"):
            continue
        try:
            value = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and (
            "identity" in value or "note" in value or "computer" in value
        ):
            chosen = value
    if chosen is None:
        raise CollectorError("Script output has no survey JSON line.")
    return chosen


def _text(value):
    if value is None:
        return ""
    return str(value)


def _join(items, render):
    if isinstance(items, str):
        return items
    if not isinstance(items, list):
        return "" if items is None else _text(items)
    parts = []
    for item in items:
        part = render(item)
        if part:
            parts.append(part)
    return " | ".join(parts)


def _field(item, key):
    if isinstance(item, dict):
        return _text(item.get(key))
    return ""


def _measure(item, key, suffix):
    text = _field(item, key)
    if not text or text == "n/a":
        return text
    return text + suffix


def flatten_survey(agent, survey, source, history_time):
    identity = survey.get("identity") if isinstance(survey.get("identity"), dict) else {}
    form = survey.get("formFactor") if isinstance(survey.get("formFactor"), dict) else {}
    display = survey.get("display") if isinstance(survey.get("display"), dict) else {}
    monitor = survey.get("monitor") if isinstance(survey.get("monitor"), dict) else {}
    memory = survey.get("memory") if isinstance(survey.get("memory"), dict) else {}
    storage = survey.get("storage") if isinstance(survey.get("storage"), dict) else {}
    network = survey.get("network") if isinstance(survey.get("network"), dict) else {}
    port = survey.get("port") if isinstance(survey.get("port"), dict) else {}
    operating = survey.get("os") if isinstance(survey.get("os"), dict) else {}

    row = {column: "" for column in COLUMNS}
    row.update(
        {
            "agent_id": agent.get("agent_id") or "",
            "hostname": agent.get("hostname") or "",
            "client": agent.get("client") or "",
            "site": agent.get("site") or "",
            "source": source,
            "history_time": history_time or "",
            "computer": _text(survey.get("computer")),
            "survey_time": _text(survey.get("time")),
            "result": _text(survey.get("result")),
            "summary": _text(survey.get("summary")),
            "manufacturer": _text(identity.get("manufacturer")),
            "model": _text(identity.get("model")),
            "serial": _text(identity.get("serial")),
            "sku": _text(identity.get("sku")),
            "bios_version": _text(identity.get("biosVersion")),
            "bios_date": _text(identity.get("biosDate")),
            "smbios_version": _text(identity.get("smbiosVersion")),
            "ship_date": _text(identity.get("shipDate")),
            "form_factor": _text(form.get("size")),
            "form_detail": _text(form.get("detail")),
            "display_outputs": _text(display.get("reported")),
            "gpus": _join(
                display.get("gpu"),
                lambda item: " ".join(
                    part
                    for part in (
                        _field(item, "name"),
                        _field(item, "kind"),
                        _field(item, "vram"),
                    )
                    if part
                ),
            ),
            "monitor_count": _text(monitor.get("count")),
            "external_monitors": _text(monitor.get("external")),
            "monitors": _join(
                monitor.get("item"),
                lambda item: " ".join(
                    part
                    for part in (
                        _field(item, "make"),
                        _field(item, "model"),
                        _measure(item, "sizeInch", "in"),
                        _field(item, "connection"),
                        _field(item, "resolution"),
                    )
                    if part
                ),
            ),
            "cpu": _join(
                survey.get("cpu"),
                lambda item: " ".join(
                    part
                    for part in (
                        _field(item, "name"),
                        _measure(item, "core", " cores"),
                    )
                    if part
                ),
            ),
            "ram_gb": _text(memory.get("total")),
            "ram_slots": _text(memory.get("slots")),
            "ram_max_gb": _text(memory.get("max")),
            "dimms": _join(
                memory.get("dimm"),
                lambda item: " ".join(
                    part
                    for part in (
                        _field(item, "locator"),
                        _measure(item, "size", " GB"),
                        _field(item, "type"),
                        _measure(item, "speed", " MHz"),
                    )
                    if part
                ),
            ),
            "disks": _join(
                storage.get("disk"),
                lambda item: " ".join(
                    part
                    for part in (
                        _field(item, "model"),
                        _measure(item, "size", " GB"),
                        _field(item, "media"),
                        _field(item, "health"),
                    )
                    if part
                ),
            ),
            "volumes": _join(
                storage.get("volume"),
                lambda item: " ".join(
                    part
                    for part in (
                        _field(item, "letter"),
                        _measure(item, "size", " GB"),
                        ("free " + _field(item, "free")) if _field(item, "free") and _field(item, "free") != "n/a" else _field(item, "free"),
                    )
                    if part
                ),
            ),
            "ethernet": _join(
                network.get("ethernet"),
                lambda item: " ".join(
                    part
                    for part in (
                        _field(item, "name"),
                        _field(item, "speed"),
                        _field(item, "mac"),
                        _field(item, "ip"),
                    )
                    if part
                ),
            ),
            "wifi": _join(
                network.get("wifi"),
                lambda item: " ".join(
                    part
                    for part in (
                        _field(item, "name"),
                        _field(item, "standard"),
                        _field(item, "mac"),
                    )
                    if part
                ),
            ),
            "bluetooth": _text(network.get("bluetooth")),
            "usb": _text(port.get("usb")),
            "com": _text(port.get("com")),
            "parallel": _text(port.get("parallel")),
            "thunderbolt": _text(port.get("thunderbolt")),
            "usb_devices": _join(port.get("device"), lambda item: _text(item)),
            "printers": _join(
                survey.get("printer"),
                lambda item: " ".join(
                    part
                    for part in (
                        _field(item, "name"),
                        _field(item, "kind"),
                        _field(item, "port"),
                    )
                    if part
                ),
            ),
            "os": _text(operating.get("caption")),
            "os_build": _text(operating.get("build")),
            "membership": _text(operating.get("membership")),
            "win11_readiness": _text(operating.get("readiness")),
            "windows_server": _text(operating.get("server")),
            "server_roles": _join(operating.get("role"), lambda item: _text(item)),
            "dental_software": _join(
                operating.get("software"),
                lambda item: " ".join(
                    part
                    for part in (_field(item, "Label"), _field(item, "Version"))
                    if part
                ),
            ),
            "power": _text(survey.get("power")),
            "replacement_notes": _join(survey.get("note"), lambda item: _text(item)),
            "collection_gaps": _join(survey.get("problem"), lambda item: _text(item)),
        }
    )
    return row


def safe_filename(value):
    text = re.sub(r"[^A-Za-z0-9._-]+", "_", str(value or "")).strip("._")
    return text or "agent"


def json_filename(computer, agent_id, used):
    base = safe_filename(computer)
    name = base + ".json"
    if name in used:
        name = "{0}_{1}.json".format(base, safe_filename(agent_id))
    used.add(name)
    return name


def _xml_text(value):
    text = "" if value is None else str(value)
    cleaned = []
    for char in text:
        code = ord(char)
        if char in ("\n", "\r", "\t"):
            cleaned.append(" ")
        elif code >= 32:
            cleaned.append(char)
    return escape("".join(cleaned))


def _column_letter(index):
    letters = ""
    number = index
    while number:
        number, remainder = divmod(number - 1, 26)
        letters = chr(65 + remainder) + letters
    return letters


def write_xlsx(path, rows):
    sheet_rows = []
    header = "".join(
        '<c r="{0}1" t="inlineStr"><is><t>{1}</t></is></c>'.format(
            _column_letter(position), _xml_text(name)
        )
        for position, name in enumerate(COLUMNS, start=1)
    )
    sheet_rows.append('<row r="1">{0}</row>'.format(header))
    for row_number, row in enumerate(rows, start=2):
        cells = []
        for position, name in enumerate(COLUMNS, start=1):
            ref = "{0}{1}".format(_column_letter(position), row_number)
            cells.append(
                '<c r="{0}" t="inlineStr"><is><t>{1}</t></is></c>'.format(
                    ref, _xml_text(row.get(name, ""))
                )
            )
        sheet_rows.append('<row r="{0}">{1}</row>'.format(row_number, "".join(cells)))
    sheet = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        "<sheetData>{0}</sheetData></worksheet>"
    ).format("".join(sheet_rows))
    content_types = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        "</Types>"
    )
    root_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        "</Relationships>"
    )
    workbook = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="Surveys" sheetId="1" r:id="rId1"/></sheets></workbook>'
    )
    workbook_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        "</Relationships>"
    )
    styles = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="2"><fill><patternFill patternType="none"/></fill>'
        '<fill><patternFill patternType="gray125"/></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>'
        "</styleSheet>"
    )
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as package:
        package.writestr("[Content_Types].xml", content_types)
        package.writestr("_rels/.rels", root_rels)
        package.writestr("xl/workbook.xml", workbook)
        package.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
        package.writestr("xl/styles.xml", styles)
        package.writestr("xl/worksheets/sheet1.xml", sheet)


def write_csv(path, rows):
    with open(path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=COLUMNS, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


class TacticalClient:
    """GET client, agent, script, and script-history endpoints. POST only runscript."""

    def __init__(self, base_url, api_key, session=None, timeout=60):
        if not api_key:
            raise CollectorError("TACTICAL_API_KEY is not set.")
        self.base_url = str(base_url or DEFAULT_API_URL).rstrip("/")
        self.timeout = timeout
        self.session = session or requests.Session()
        self.session.headers["X-API-KEY"] = api_key
        self.session.headers["Accept"] = "application/json"

    def _url(self, path):
        return self.base_url + "/" + path.lstrip("/")

    def get_json(self, path, params=None):
        safe = read_path(path)
        response = self.session.get(self._url(safe), params=params, timeout=self.timeout)
        if response.status_code >= 400:
            raise CollectorError("GET {0} returned {1}.".format(safe, response.status_code))
        return response.json()

    def run_survey(self, agent_id, script_id, timeout):
        path = run_script_path(agent_id)
        body = {
            "output": "wait",
            "emails": [],
            "emailMode": "default",
            "custom_field": None,
            "save_all_output": False,
            "script": int(script_id),
            "args": [],
            "env_vars": [],
            "run_as_user": False,
            "timeout": int(timeout),
        }
        response = self.session.post(
            self._url(path),
            json=body,
            timeout=max(int(timeout) + 30, self.timeout),
        )
        if response.status_code >= 400:
            raise CollectorError("POST {0} returned {1}.".format(path, response.status_code))
        content_type = response.headers.get("content-type", "")
        if "json" in content_type.lower():
            return response.json()
        return response.text

    def clients(self):
        return as_list(self.get_json("clients/"))

    def agents_for_client(self, client_id):
        payload = self.get_json(
            "agents/",
            params={"client": str(client_id), "detail": "false"},
        )
        return [normalize_agent(row) for row in as_list(payload)]

    def agent(self, agent_id):
        agent = validate_agent_id(agent_id)
        return normalize_agent(self.get_json("agents/{0}/".format(agent)))

    def script_history(self, script_name):
        payload = self.get_json(
            "agents/scripthistory/",
            params={"scriptname": script_name},
        )
        return as_list(payload)

    def scripts(self):
        return as_list(self.get_json("scripts/"))


def collect(client, agents, out_dir, run, script_name, script_id, timeout, tactical):
    targets = []
    seen = set()
    if client is not None:
        match = find_client(tactical.clients(), client)
        for agent in tactical.agents_for_client(match.get("id")):
            if not agent["agent_id"] or agent["agent_id"] in seen:
                continue
            if not agent["client"]:
                agent["client"] = str(match.get("name") or "")
            seen.add(agent["agent_id"])
            targets.append(agent)
    for agent_id in agents:
        if agent_id in seen:
            continue
        agent = tactical.agent(agent_id)
        seen.add(agent["agent_id"])
        targets.append(agent)

    history = latest_by_agent(tactical.script_history(script_name), script_name)
    os.makedirs(out_dir, exist_ok=True)
    rows = []
    errors = []
    used_names = set()
    resolved_script_id = script_id

    for agent in targets:
        record = history.get(agent["agent_id"])
        text = output_text(record) if record else ""
        survey = None
        source = "history"
        history_time = record_time(record) if record else ""
        history_id = record.get("id") if isinstance(record, dict) else None
        if text:
            try:
                survey = parse_survey_output(text)
            except CollectorError:
                survey = None
        if survey is None and run:
            if resolved_script_id is None:
                resolved_script_id = find_script_id(tactical.scripts(), script_name, None)
            payload = tactical.run_survey(agent["agent_id"], resolved_script_id, timeout)
            source = "run"
            history_time = ""
            history_id = None
            try:
                survey = parse_survey_output(output_text(payload))
            except CollectorError as exc:
                errors.append("{0}: {1}".format(agent["agent_id"], exc))
                continue
        if survey is None:
            errors.append("{0}: no Get-ReplacementSurvey JSON in script history.".format(agent["agent_id"]))
            continue

        computer = survey.get("computer") or agent.get("hostname") or agent["agent_id"]
        filename = json_filename(computer, agent["agent_id"], used_names)
        document = {
            "agent_id": agent["agent_id"],
            "hostname": agent.get("hostname") or "",
            "client": agent.get("client") or "",
            "site": agent.get("site") or "",
            "source": source,
            "history_id": history_id,
            "history_time": history_time,
            "script_name": script_name,
            "survey": survey,
        }
        json_path = os.path.join(out_dir, filename)
        with open(json_path, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=False)
            handle.write("\n")
        rows.append(flatten_survey(agent, survey, source, history_time))
        print("{0}: saved {1} from {2}".format(agent.get("hostname") or agent["agent_id"], filename, source))

    write_csv(os.path.join(out_dir, "surveys.csv"), rows)
    write_xlsx(os.path.join(out_dir, "surveys.xlsx"), rows)
    print("Wrote {0}".format(os.path.join(out_dir, "surveys.csv")))
    print("Wrote {0}".format(os.path.join(out_dir, "surveys.xlsx")))
    for message in errors:
        print(message, file=sys.stderr)
    if not targets:
        print("No agents matched.")
    return 1 if errors else 0


def build_parser():
    parser = argparse.ArgumentParser(
        description="Save the latest Get-ReplacementSurvey JSON from Tactical script history."
    )
    parser.add_argument("--client", help="Client name or numeric client id.")
    parser.add_argument(
        "--agent",
        action="append",
        default=[],
        dest="agent_flags",
        help="Agent id. Repeat to add more than one.",
    )
    parser.add_argument("agent_ids", nargs="*", help="Agent ids.")
    parser.add_argument("--out", required=True, help="Folder for the JSON, CSV, and XLSX files.")
    parser.add_argument(
        "--run",
        action="store_true",
        help="Run Get-ReplacementSurvey only when that agent has no survey JSON in history.",
    )
    parser.add_argument("--script-name", default=DEFAULT_SCRIPT_NAME)
    parser.add_argument("--script-id", type=int, help="Script Manager id, used only with --run.")
    parser.add_argument("--timeout", type=int, default=SURVEY_SCRIPT_TIMEOUT)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    agent_ids = list(args.agent_flags) + list(args.agent_ids)
    if not args.client and not agent_ids:
        parser.error("Pass --client or at least one agent id.")
    if args.timeout < 30:
        parser.error("--timeout must be at least 30 seconds.")
    api_key = os.environ.get("TACTICAL_API_KEY", "").strip()
    api_url = os.environ.get("TACTICAL_API_URL", DEFAULT_API_URL).strip() or DEFAULT_API_URL
    try:
        tactical = TacticalClient(api_url, api_key)
        return collect(
            client=args.client,
            agents=agent_ids,
            out_dir=args.out,
            run=args.run,
            script_name=args.script_name,
            script_id=args.script_id,
            timeout=args.timeout,
            tactical=tactical,
        )
    except CollectorError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    except requests.RequestException:
        print("Tactical API request failed.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
