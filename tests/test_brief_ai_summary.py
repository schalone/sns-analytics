import unittest
from brief import ai_summary as a

class Prompt(unittest.TestCase):
    def test_prompt_contains_both_reports(self):
        p = a.build_prompt("GA LINE", "ADS LINE")
        self.assertIn("WEBSITE (GA4):\nGA LINE", p); self.assertIn("GOOGLE ADS:\nADS LINE", p)
    def test_system_forbids_invented_numbers(self):
        self.assertIn("never compute or estimate new ones", a.SYSTEM)

class _Block:  # minimal stand-ins for SDK response objects
    def __init__(self, t): self.type = "text"; self.text = t
class _Usage: input_tokens = 1; output_tokens = 1
class _Msg:
    def __init__(self, text, stop="end_turn"): self.content = [_Block(text)]; self.stop_reason = stop; self.model = "m"; self.usage = _Usage()
class _Client:
    def __init__(self, msg=None, exc=None):
        self.beta = self; self.messages = self; self._msg = msg; self._exc = exc; self.kwargs = None
    def create(self, **kw):
        self.kwargs = kw
        if self._exc: raise self._exc
        return self._msg

class Narrative(unittest.TestCase):
    def test_returns_text_and_uses_opus_with_fallbacks(self):
        c = _Client(_Msg("All quiet."))
        self.assertEqual(a.narrative("g", "d", client=c), "All quiet.")
        self.assertEqual(c.kwargs["model"], "claude-opus-5"); self.assertEqual(c.kwargs["fallbacks"], "default")
    def test_refusal_returns_none(self):
        self.assertIsNone(a.narrative("g", "d", client=_Client(_Msg("x", stop="refusal"))))
    def test_exception_returns_none(self):
        self.assertIsNone(a.narrative("g", "d", client=_Client(exc=RuntimeError("boom"))))

if __name__ == "__main__": unittest.main()
