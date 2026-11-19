"""Verify that the required personal journey actually ran in this XCTest bundle."""
import json
import subprocess
import sys

JOURNEY = "CareJourneyUITests/testPersonalConversationSurvivesRelaunch()"


def require_journey(report):
    nodes = list(report["testNodes"])
    results = []
    while nodes:
        node = nodes.pop()
        if node.get("nodeType") == "Test Case" and node.get("nodeIdentifier") == JOURNEY:
            results.append(node.get("result"))
        nodes.extend(node.get("children", []))
    if not results:
        raise ValueError("В отчёте нет обязательного сценария " + JOURNEY)
    if any(result != "Passed" for result in results):
        raise ValueError("У обязательного сценария нет успешного результата во всех запусках.")


if __name__ == "__main__":
    try:
        raw = subprocess.check_output([
            "xcrun", "xcresulttool", "get", "test-results", "tests", "--path", sys.argv[1]
        ])
        require_journey(json.loads(raw))
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError, TypeError, AttributeError) as error:
        sys.exit("Не удалось подтвердить прохождение iPhone-сценария: " + str(error))
    print("XCTest подтвердил прохождение " + JOURNEY)
