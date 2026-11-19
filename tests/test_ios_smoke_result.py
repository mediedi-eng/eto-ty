import unittest

from scripts.check_ios_smoke_result import JOURNEY, require_journey


def report(*cases):
    return {"testNodes": [{"nodeType": "Test Plan", "children": [
        {"nodeType": "Test Case", "nodeIdentifier": identifier, "result": result}
        for identifier, result in cases
    ]}]}


class JourneyResultTests(unittest.TestCase):
    def test_executed(self):
        require_journey(report((JOURNEY, "Passed")))

    def test_partial_or_absent(self):
        for value in [report(), report(("OtherTests/testOther()", "Passed")),
                      report((JOURNEY, "Skipped")), report((JOURNEY, "Failed")),
                      report((JOURNEY, "Passed"), (JOURNEY, "Failed")),
                      report((JOURNEY, None))]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                require_journey(value)

    def test_suite_name_is_not_execution(self):
        with self.assertRaises(ValueError):
            require_journey({"testNodes": [{"nodeType": "Test Suite",
                                            "nodeIdentifier": JOURNEY, "result": "Passed"}]})
