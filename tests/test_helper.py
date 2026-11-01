import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

import helper


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["COMMANDS_DATA_DIR"] = self.tmp.name
        os.environ["COMMANDS_DRY_RUN"] = "1"

    def tearDown(self):
        self.tmp.cleanup()
        os.environ.pop("COMMANDS_DATA_DIR", None)
        os.environ.pop("COMMANDS_DRY_RUN", None)

    def save(self, **fields):
        command = {
            "title": "Pokaż ARP",
            "command": "get system arp",
            "group": "Fortinet",
            "tags": ["Diagnostyka"],
            "body": "Gdy host nie odpowiada.",
            "danger": False,
            "pinned": False,
        }
        command.update(fields)
        return helper.dispatch({"op": "save", "command": command})

    def test_save_list_and_search_fields(self):
        saved = self.save()
        command = saved["commands"][0]
        self.assertEqual(command["tags"], ["diagnostyka"])
        self.assertEqual(command["group"], "Fortinet")
        self.assertTrue(command["id"])
        listed = helper.dispatch({"op": "list"})
        self.assertEqual(listed["commands"][0]["title"], "Pokaż ARP")
        self.assertNotIn("token", listed["settings"])
        self.assertFalse(listed["settings"]["syncConfigured"])

    def test_unchanged_save_keeps_revision(self):
        saved = self.save()
        command = dict(saved["commands"][0])
        command.pop("placeholders")
        again = helper.dispatch({"op": "save", "command": command})
        self.assertEqual(saved["revision"], again["revision"])

    def test_groups_can_exist_before_commands(self):
        created = helper.dispatch({"op": "saveGroup", "name": "  Konfigurowanie   Fortineta "})
        self.assertEqual(created["groups"], ["Konfigurowanie Fortineta"])
        self.assertEqual(created["commands"], [])
        with self.assertRaises(helper.HelperError):
            helper.dispatch({"op": "saveGroup", "name": "konfigurowanie fortineta"})
        saved = self.save(group="Konfigurowanie Fortineta", title="Adres interfejsu", command="show system interface")
        self.assertEqual(saved["groups"], ["Konfigurowanie Fortineta"])
        renamed = helper.dispatch({"op": "saveGroup", "name": "Fortinet — konfiguracja", "previous": "Konfigurowanie Fortineta"})
        self.assertEqual(renamed["groups"], ["Fortinet — konfiguracja"])
        self.assertEqual(renamed["commands"][0]["group"], "Fortinet — konfiguracja")
        with self.assertRaises(helper.HelperError):
            helper.dispatch({"op": "deleteGroup", "name": "Fortinet — konfiguracja"})
        helper.dispatch({"op": "saveGroup", "name": "Pusta"})
        deleted = helper.dispatch({"op": "deleteGroup", "name": "Pusta"})
        self.assertNotIn("Pusta", deleted["groups"])
        self.assertIn("Fortinet — konfiguracja", deleted["groups"])

    def test_old_catalog_without_groups_still_opens(self):
        saved = self.save()
        command = dict(saved["commands"][0])
        command.pop("placeholders")
        path = Path(self.tmp.name, "catalog.json")
        path.write_text(json.dumps({"schema": 1, "commands": [command]}), encoding="utf-8")
        listed = helper.dispatch({"op": "list"})
        self.assertEqual(listed["groups"], ["Fortinet"])

    def test_unknown_field_is_rejected(self):
        with self.assertRaises(helper.HelperError):
            self.save(secret="nope")

    def test_pin_sorts_first_and_delete_removes(self):
        first = self.save(title="Alfa")
        self.save(title="Beta", command="get system status")
        ident = first["commands"][0]["id"]
        pinned = helper.dispatch({"op": "pin", "id": ident, "pinned": True})
        self.assertEqual(pinned["commands"][0]["title"], "Alfa")
        self.assertTrue(pinned["commands"][0]["pinned"])
        deleted = helper.dispatch({"op": "delete", "id": ident})
        self.assertEqual([item["title"] for item in deleted["commands"]], ["Beta"])

    def test_recent_copies_sort_under_pins(self):
        alfa = self.ident(self.save(title="Alfa"), "Alfa")
        beta = self.ident(self.save(title="Beta", command="echo beta"), "Beta")
        gamma = self.ident(self.save(title="Gamma", command="echo gamma"), "Gamma")
        revision = helper.dispatch({"op": "list"})["revision"]
        self.assertEqual(self.titles(), ["Alfa", "Beta", "Gamma"])

        helper.dispatch({"op": "deliver", "id": beta, "mode": "copy", "values": {}})
        self.assertEqual(self.titles(), ["Beta", "Alfa", "Gamma"])
        helper.dispatch({"op": "deliver", "id": gamma, "mode": "paste", "values": {}})
        self.assertEqual(self.titles(), ["Gamma", "Beta", "Alfa"])
        self.assertEqual(helper.dispatch({"op": "list"})["revision"], revision)

        helper.dispatch({"op": "pin", "id": alfa, "pinned": True})
        self.assertEqual(self.titles(), ["Alfa", "Gamma", "Beta"])
        helper.dispatch({"op": "deliver", "id": alfa, "mode": "copy", "values": {}})
        listed = helper.dispatch({"op": "list"})["commands"]
        self.assertEqual([item["title"] for item in listed], ["Alfa", "Gamma", "Beta"])
        self.assertTrue(listed[0]["pinned"])

        helper.dispatch({"op": "delete", "id": gamma})
        self.assertEqual(self.titles(), ["Alfa", "Beta"])
        stored = json.loads(Path(self.tmp.name, "settings.json").read_text(encoding="utf-8"))
        self.assertEqual(stored["recent"], [alfa, beta])
        self.assertNotIn("recent", helper.dispatch({"op": "list"})["settings"])

    def titles(self):
        return [item["title"] for item in helper.dispatch({"op": "list"})["commands"]]

    def ident(self, state, title):
        return next(item["id"] for item in state["commands"] if item["title"] == title)

    def test_placeholders_and_danger_confirmation(self):
        saved = self.save(command="diagnose sniffer packet {{iface}} '{{filter}}' 4", danger=True)
        command = saved["commands"][0]
        self.assertEqual(command["placeholders"], ["iface", "filter"])
        with self.assertRaises(helper.HelperError):
            helper.dispatch({"op": "deliver", "id": command["id"], "mode": "copy", "values": {}})
        with self.assertRaises(helper.HelperError):
            helper.dispatch({
                "op": "deliver",
                "id": command["id"],
                "mode": "copy",
                "confirmDanger": True,
                "values": {"iface": "port1"},
            })
        delivered = helper.dispatch({
            "op": "deliver",
            "id": command["id"],
            "mode": "paste",
            "confirmDanger": True,
            "values": {"iface": "port1", "filter": "host 10.0.0.1"},
        })
        self.assertEqual(delivered["text"], "diagnose sniffer packet port1 'host 10.0.0.1' 4")

    def test_settings_reject_secrets_in_the_url(self):
        with self.assertRaises(helper.HelperError):
            helper.dispatch({"op": "saveSettings", "apiBase": "https://user:pw@example.test"})
        state = helper.dispatch({"op": "saveSettings", "apiBase": "https://sync.example.test", "token": "sekret", "layout": "wide"})
        self.assertEqual(state["settings"]["apiBase"], "https://sync.example.test")
        self.assertTrue(state["settings"]["tokenSet"])
        self.assertEqual(state["settings"]["layout"], "wide")
        stored = json.loads(Path(self.tmp.name, "settings.json").read_text(encoding="utf-8"))
        self.assertEqual(stored["token"], "sekret")
        cleared = helper.dispatch({"op": "saveSettings", "clearToken": True})
        self.assertFalse(cleared["settings"]["tokenSet"])
        sejfik = helper.dispatch({"op": "saveSettings", "apiBase": "https://sejfik.xerima.pl/v1/snapshot/"})
        self.assertEqual(sejfik["settings"]["apiBase"], "https://sejfik.xerima.pl")

    def test_snapshot_ignores_library_metadata(self):
        saved = self.save()
        command = dict(saved["commands"][0])
        command.pop("placeholders")
        parsed = helper.snapshot({
            "schema": 1,
            "libraryId": "lib_abc",
            "libraryName": "Sieć",
            "revision": "deadbeef",
            "groups": ["Fortinet"],
            "commands": [command],
        })
        self.assertEqual(set(parsed), {"schema", "groups", "commands"})
        self.assertEqual(parsed["commands"][0]["title"], "Pokaż ARP")
        self.assertNotIn("libraryId", json.dumps(parsed))

    def test_sync_preview_keeps_newer_local_until_replace(self):
        saved = self.save()
        command = dict(saved["commands"][0])
        command.pop("placeholders")
        local = dict(command)
        local["title"] = "ARP lokalnie"
        local["updatedAt"] = "2099-06-01T00:00:00Z"
        remote_new = dict(local)
        remote_new["title"] = "ARP ze serwera"
        remote_new["updatedAt"] = "2099-01-01T00:00:00Z"
        added = dict(command)
        added["id"] = "remote-only"
        added["title"] = "Nowa ze serwera"
        added["command"] = "get system status"
        added["updatedAt"] = "2099-01-01T00:00:00Z"

        def fetch(_settings):
            return {"schema": 1, "commands": [remote_new, added]}

        with self.assertRaises(helper.HelperError):
            helper.preview_sync(fetch)

        helper.dispatch({"op": "saveSettings", "apiBase": "https://sync.example.test"})
        helper.write_private(helper.catalog_path(), {"schema": 1, "commands": [local]})
        preview = helper.preview_sync(fetch)
        actions = {row["id"]: row["action"] for row in preview["rows"]}
        self.assertEqual(actions[command["id"]], "conflict")
        self.assertEqual(actions["remote-only"], "added")

        kept = helper.dispatch({"op": "applySync", "token": preview["token"], "policy": "keep"})
        titles = {item["id"]: item["title"] for item in kept["commands"]}
        self.assertEqual(titles[command["id"]], "ARP lokalnie")
        self.assertEqual(titles["remote-only"], "Nowa ze serwera")

        remote_new["updatedAt"] = "2099-01-01T00:00:00Z"
        preview = helper.preview_sync(fetch)
        replaced = helper.dispatch({"op": "applySync", "token": preview["token"], "policy": "replace"})
        titles = {item["id"]: item["title"] for item in replaced["commands"]}
        self.assertEqual(titles[command["id"]], "ARP ze serwera")

    def test_sync_keeps_newer_local_and_pushes_the_merge(self):
        saved = self.save(title="Alfa")
        command = dict(saved["commands"][0])
        command.pop("placeholders")
        command["updatedAt"] = "2020-01-01T00:00:00Z"
        gamma = dict(command)
        gamma["id"] = "gamma"
        gamma["title"] = "Gamma"
        gamma["command"] = "echo gamma"
        gamma["updatedAt"] = "2026-01-01T00:00:00Z"
        helper.write_private(helper.catalog_path(), {"schema": 1, "groups": ["Fortinet"], "commands": [command, gamma]})
        remote_alfa = dict(command)
        remote_alfa["title"] = "Alfa z serwera"
        remote_alfa["updatedAt"] = "2026-06-01T00:00:00Z"
        beta = dict(command)
        beta["id"] = "beta"
        beta["title"] = "Beta"
        beta["command"] = "echo beta"
        beta["updatedAt"] = "2026-06-01T00:00:00Z"
        helper.dispatch({"op": "saveSettings", "apiBase": "https://sejfik.xerima.pl", "token": "cmd_test"})

        def fetch(_settings):
            return {
                "schema": 1,
                "libraryId": "lib_abc",
                "libraryName": "Sieć",
                "revision": "deadbeef",
                "groups": ["Fortinet"],
                "commands": [remote_alfa, beta],
            }

        seen = {}

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self, _limit):
                return b""

        def opener(request, timeout):
            seen["body"] = json.loads(request.data.decode("utf-8"))
            seen["auth"] = request.headers["Authorization"]
            seen["timeout"] = timeout
            return Response()

        result = helper.sync_catalog(fetch, opener)
        titles = {item["id"]: item["title"] for item in result["commands"]}
        self.assertEqual(titles[command["id"]], "Alfa z serwera")
        self.assertEqual(titles["beta"], "Beta")
        self.assertEqual(titles["gamma"], "Gamma")
        self.assertEqual(seen["auth"], "Bearer cmd_test")
        self.assertEqual({item["id"] for item in seen["body"]["commands"]}, {command["id"], "beta", "gamma"})
        self.assertEqual(result["summary"]["added"], 1)
        self.assertEqual(result["summary"]["updated"], 1)
        self.assertTrue(result["changed"])

    def test_sync_skips_push_when_nothing_changed(self):
        self.save(title="Alfa")
        catalog = json.loads(helper.catalog_path().read_text(encoding="utf-8"))
        helper.dispatch({"op": "saveSettings", "apiBase": "https://sejfik.xerima.pl", "token": "cmd_test"})

        def fetch(_settings):
            return catalog

        def opener(*_args, **_kwargs):
            raise AssertionError("nie powinno wysyłać")

        result = helper.sync_catalog(fetch, opener)
        self.assertFalse(result["changed"])
        self.assertEqual(result["summary"], {"added": 0, "updated": 0, "conflict": 0})

    def test_push_sends_if_match(self):
        self.save()
        helper.dispatch({"op": "saveSettings", "apiBase": "https://sync.example.test", "token": "sekret"})
        seen = {}

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self, _limit):
                return b""

        def opener(request, timeout):
            seen["url"] = request.full_url
            seen["method"] = request.get_method()
            seen["match"] = request.headers["If-match"]
            seen["auth"] = request.headers["Authorization"]
            seen["timeout"] = timeout
            seen["body"] = json.loads(request.data.decode("utf-8"))
            return Response()

        result = helper.push_snapshot(helper.load_settings(), opener)
        self.assertEqual(seen["url"], "https://sync.example.test/v1/snapshot")
        self.assertEqual(seen["method"], "PUT")
        self.assertEqual(seen["auth"], "Bearer sekret")
        self.assertEqual(seen["match"], result["revision"])
        self.assertEqual(seen["body"]["commands"][0]["title"], "Pokaż ARP")

    def test_push_reports_conflict(self):
        self.save()
        helper.dispatch({"op": "saveSettings", "apiBase": "https://sync.example.test"})

        def opener(request, timeout):
            raise urllib.error.HTTPError(request.full_url, 409, "conflict", hdrs=None, fp=None)

        with self.assertRaises(helper.HelperError) as caught:
            helper.push_snapshot(helper.load_settings(), opener)
        self.assertIn("nowszy", str(caught.exception))

    def test_ask_matches_a_misspelled_question_without_opencode(self):
        self.save(
            title="Adresy interfejsów",
            group="Fortinet",
            command="diagnose ip address list",
            body="Adresy, które naprawdę siedzą na interfejsach.",
        )
        self.save(
            title="Trasa do adresu",
            group="Fortinet",
            command="get router info routing-table details {{address}}",
            body="Który wpis złapie pakiet do tego adresu.",
        )
        self.save(
            title="Dzierżawy DHCP",
            group="Fortinet",
            command="execute dhcp lease-list",
            body="Adresy rozdane przez serwer DHCP na FortiGate.",
        )

        def runner(_prompt):
            raise AssertionError("to pytanie da się rozstrzygnąć bez OpenCode")

        match = helper.ask("sprawdzic lsite adffresow na fortigate", runner)
        self.assertEqual(match["match"]["title"], "Adresy interfejsów")

    def test_ask_offers_ping_when_the_sentence_is_ambiguous(self):
        self.save(title="Ping", group="Fortinet", command="execute ping {{host}}", body="Ping z FortiGate.")
        self.save(title="Ping", group="Linux", command="ping -c 4 {{host}}", body="Cztery próby i koniec.")
        self.save(title="Wolne miejsce", group="Linux", command="df -hT", body="Zajętość dysku.")

        def runner(_prompt):
            raise AssertionError("lista pingów jest w katalogu")

        result = helper.ask("Sprawdzic czy urzdenie odpowaida", runner)
        self.assertIsNone(result["match"])
        self.assertEqual(sorted(item["title"] for item in result["candidates"]), ["Ping", "Ping"])
        shorter = helper.ask("spradzi czy urzadzenie odpowaida", runner)
        self.assertIsNone(shorter["match"])
        self.assertEqual(sorted(item["title"] for item in shorter["candidates"]), ["Ping", "Ping"])

    def test_ask_treats_a_responding_address_as_ping(self):
        self.save(title="Ping", group="Fortinet", command="execute ping {{host}}", body="Ping z FortiGate.")
        self.save(title="Ping", group="Linux", command="ping -c 4 {{host}}", body="Cztery próby i koniec.")
        self.save(
            title="Adresy interfejsów",
            group="Fortinet",
            command="diagnose ip address list",
            body="Adresy, które naprawdę siedzą na interfejsach.",
            tags=["sieć"],
        )
        self.save(
            title="Trasa do adresu",
            group="Fortinet",
            command="get router info routing-table details {{address}}",
            body="Który wpis złapie pakiet do tego adresu.",
        )

        def runner(_prompt):
            raise AssertionError("odpowiada w sieci to ping, nie lista adresów")

        result = helper.ask("spradz czy adres opowiada w sieci", runner)
        self.assertIsNone(result["match"])
        self.assertEqual(sorted(item["title"] for item in result["candidates"]), ["Ping", "Ping"])

    def test_ask_accepts_only_catalog_ids(self):
        saved = self.save()
        ident = saved["commands"][0]["id"]

        def runner(_prompt):
            return 'pewność: {"id": "%s"}' % ident

        match = helper.ask("nie widzę MAC-a", runner)
        self.assertEqual(match["match"]["id"], ident)

        def missing(_prompt):
            return '{"id": "nie-ma"}'

        self.assertIsNone(helper.ask("coś innego", missing)["match"])

    def test_main_answers_without_closing_stdin(self):
        script = Path(__file__).resolve().parents[1] / "helper.py"
        proc = subprocess.Popen(
            [sys.executable, "-B", str(script)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            env={**os.environ, "COMMANDS_DATA_DIR": self.tmp.name, "COMMANDS_DRY_RUN": "1"},
        )
        assert proc.stdin is not None and proc.stdout is not None
        try:
            proc.stdin.write(json.dumps({"op": "list"}) + "\n")
            proc.stdin.flush()
            line = proc.stdout.readline()
        finally:
            proc.kill()
            proc.stdin.close()
            proc.stdout.close()
            proc.wait(timeout=5)
        self.assertIn('"ok": true', line)

    def test_symlink_data_dir_fails_closed(self):
        outside = tempfile.TemporaryDirectory()
        link = Path(self.tmp.name) / "linked"
        link.symlink_to(outside.name)
        os.environ["COMMANDS_DATA_DIR"] = str(link)
        with self.assertRaises(helper.HelperError):
            helper.dispatch({"op": "list"})
        outside.cleanup()


if __name__ == "__main__":
    unittest.main()
