"""Check where the public Actions page walk agrees to run and which page it accepts."""
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import walk


def parse_options(environment, *arguments):
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-official", action="store_true")
    argv = ["walk.py", "--app", "/fixture/Bark.app", "--output", "/fixture/evidence", *arguments]
    with patch.dict(os.environ, environment, clear=True), patch.object(sys, "argv", argv), \
            contextlib.redirect_stderr(io.StringIO()):
        return walk.parse_options(parser)


class RunnerTests(unittest.TestCase):
    def test_hosted_runner_visits_the_page(self):
        args = parse_options({"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"}, "--require-official")
        self.assertTrue(args.require_official)

    def test_self_hosted_release_runner_visits_the_page(self):
        args = parse_options({"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"}, "--require-official")
        self.assertTrue(args.require_official)

    def test_local_run_is_refused(self):
        with self.assertRaises(SystemExit):
            parse_options({"RUNNER_ENVIRONMENT": "self-hosted"}, "--require-official")

    def test_official_sdk_is_required(self):
        with self.assertRaises(SystemExit):
            parse_options({"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"})


ACTIONS = "https://github.com/kuzaxak/Bark/actions"


class ActionsPageTests(unittest.TestCase):
    def visit(self, address, *, title="All workflows · GitHub", field=True, typed_address=None, focus="field"):
        state = {"address": address, "now": 0.0}
        elements = {
            "bark": {"AXWindows": ["window"], "AXFocusedUIElement": focus},
            "window": {"AXRole": "AXWindow", "AXTitle": title, "AXChildren": ["page"]},
            "page": {"AXRole": "AXWebArea", "AXTitle": title, "AXChildren": ["field"] if field else [],
                     "AXURL": SimpleNamespace(absoluteString=lambda: state["address"])},
            "field": {"AXRole": "AXTextField", "AXPlaceholderValue": "Search runs", "AXValue": "",
                      "AXPosition": SimpleNamespace(x=313, y=179), "AXSize": SimpleNamespace(width=565, height=32)},
            "suggestion": {"AXRole": "AXStaticText", "AXValue": "Build Bark release"},
        }
        ax = Mock()
        ax.AXUIElementCreateApplication.return_value = "bark"
        ax.AXUIElementCopyAttributeValue.side_effect = lambda element, name, _: (
            (0, elements[element][name]) if name in elements.get(element, {}) else (-25212, None))
        ax.AXValueGetValue.side_effect = lambda value, kind, _: (True, value)
        screen = Mock(ax=ax)
        screen.windows.return_value = [{"kCGWindowBounds": {"X": 50, "Y": 31, "Width": 900, "Height": 660}}]

        def key(text, flags=0, unicode=False):
            if unicode:
                elements["field"]["AXValue"] = text
                state["address"] = typed_address or state["address"]

        screen.key.side_effect = key
        process = Mock(pid=4321)
        process.poll.return_value = None
        failure = None
        with tempfile.TemporaryDirectory() as folder, \
                patch("time.monotonic", lambda: state["now"]), \
                patch("time.sleep", side_effect=lambda seconds: state.update(now=state["now"] + seconds)), \
                contextlib.redirect_stdout(io.StringIO()):
            output = Path(folder)
            try:
                walk.exercise(screen, process, [], output)
            except RuntimeError as error:
                failure = str(error)
            dump = output / "accessibility.json"
            accessibility = json.loads(dump.read_text()) if dump.exists() else []
        return SimpleNamespace(failure=failure, screen=screen, output=output, accessibility=accessibility,
                               elements=elements)

    def test_github_client_title_at_the_actions_address_takes_typed_search(self):
        visit = self.visit(ACTIONS)
        self.assertIsNone(visit.failure)
        visit.screen.click.assert_called_once_with((545.5, 164.0))
        visit.screen.key.assert_any_call("Bark", unicode=True)
        visit.screen.screenshot.assert_called_once_with(visit.output / "actions.png")

    def test_search_that_adds_a_query_to_the_address_keeps_the_page(self):
        visit = self.visit(ACTIONS, typed_address=ACTIONS + "/?query=Bark")
        self.assertIsNone(visit.failure)
        visit.screen.screenshot.assert_called_once_with(visit.output / "actions.png")

    def test_search_with_a_highlighted_suggestion_counts_the_field_value(self):
        visit = self.visit(ACTIONS, focus="suggestion")
        self.assertIsNone(visit.failure)
        visit.screen.screenshot.assert_called_once_with(visit.output / "actions.png")

    def test_sign_in_redirect_is_inconclusive_and_records_the_tree(self):
        visit = self.visit("https://github.com/login?return_to=%2Fkuzaxak%2FBark%2Factions")
        self.assertRegex(str(visit.failure), "^Inconclusive")
        visit.screen.click.assert_not_called()
        visit.screen.screenshot.assert_not_called()
        self.assertIn(["AXWebArea", ["All workflows · GitHub"]], visit.accessibility)

    def test_actions_address_without_the_search_field_is_inconclusive(self):
        visit = self.visit(ACTIONS, title="Page not found · GitHub", field=False)
        self.assertRegex(str(visit.failure), "^Inconclusive")
        visit.screen.click.assert_not_called()


if __name__ == "__main__":
    unittest.main()
