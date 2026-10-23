import unittest
from types import SimpleNamespace as NS
from unittest.mock import MagicMock, patch
from fastapi.testclient import TestClient
from agent import run_agent, _item_to_dict
from main import app
from auth import fake_user, require_user, require_ai_agent_user


class FakeClient:
    def __init__(self, responses):
        self.responses = self
        self.queue = list(responses)
        self.requests = []

    def create(self, **kwargs):
        self.requests.append({**kwargs, "input": list(kwargs["input"])})
        return self.queue.pop(0)


def call(name, arguments="{}"):
    return NS(type="function_call", name=name, arguments=arguments, call_id="c1")


def response(items, text=""):
    return NS(output=items, output_text=text)


class ItemToDictTests(unittest.TestCase):
    def test_dict_passthrough(self):
        d = {"type": "function_call", "name": "get_balance"}
        self.assertEqual(_item_to_dict(d), d)

    def test_namespace_to_dict(self):
        ns = NS(type="function_call", name="get_balance", call_id="c1")
        result = _item_to_dict(ns)
        self.assertEqual(result["name"], "get_balance")

    def test_pydantic_model(self):
        m = MagicMock()
        m.model_dump.return_value = {"type": "function_call"}
        result = _item_to_dict(m)
        self.assertEqual(result["type"], "function_call")


class AgentTests(unittest.TestCase):
    def test_tool_result_is_returned_to_model(self):
        client = FakeClient([
            response([call("get_balance")]),
            response([], "Demo balance: £650."),
        ])
        with patch("agent.get_toolkit", return_value=({"get_balance": lambda: {"balance": "650.00", "mock": True}}, [])):
            with patch("agent.load_history", return_value=[]):
                with patch("agent.save_history"):
                    result = run_agent("Balance?", client=client)
        self.assertEqual(result["tool_calls"][0]["result"]["balance"], "650.00")
        self.assertEqual(client.requests[1]["input"][-1]["type"], "function_call_output")
        self.assertTrue(result["mock_data"])

    def test_unknown_tool_is_not_executed(self):
        client = FakeClient([
            response([call("transfer_money")]),
            response([], "Cannot transfer."),
        ])
        with patch("agent.get_toolkit", return_value=({}, [])):
            with patch("agent.load_history", return_value=[]):
                with patch("agent.save_history"):
                    result = run_agent("Transfer", client=client)
        self.assertIn("Unknown tool", result["tool_calls"][0]["result"]["error"])

    def test_loop_is_bounded(self):
        client = FakeClient([response([call("get_balance")]) for _ in range(5)])
        with patch("agent.get_toolkit", return_value=({"get_balance": lambda: {"balance": "0.00"}}, [])):
            with patch("agent.load_history", return_value=[]):
                with patch("agent.save_history"):
                    with self.assertRaises(RuntimeError):
                        run_agent("Balance?", client=client)

    def test_invalid_arguments(self):
        client = FakeClient([
            response([call("get_balance", "broken")]),
            response([], "Retry"),
        ])
        with patch("agent.get_toolkit", return_value=({"get_balance": lambda: {"balance": "0.00"}}, [])):
            with patch("agent.load_history", return_value=[]):
                with patch("agent.save_history"):
                    result = run_agent("Balance?", client=client)
        self.assertEqual(result["tool_calls"][0]["result"]["error"], "Invalid tool arguments")

    def test_session_id_returned_in_result(self):
        client = FakeClient([response([], "Hi")])
        with patch("agent.get_toolkit", return_value=({}, [])):
            with patch("agent.load_history", return_value=[]):
                with patch("agent.save_history"):
                    result = run_agent("Hi", client=client, user_id="u1", session_id="ses1")
        self.assertEqual(result["session_id"], "ses1")

    def test_history_is_loaded_and_saved(self):
        prior_history = [{"role": "user", "content": "Hello"}, {"role": "assistant", "content": "Hi"}]
        client = FakeClient([response([], "Your balance is £100.")])
        with patch("agent.get_toolkit", return_value=({}, [])):
            with patch("agent.load_history", return_value=prior_history) as mock_load:
                with patch("agent.save_history") as mock_save:
                    run_agent("Balance?", client=client, user_id="u1", session_id="s1")
        mock_load.assert_called_once_with("u1", "s1")
        mock_save.assert_called_once()
        saved_inputs = mock_save.call_args[0][2]
        # Prior history + new user message + model output = at least 4 items
        self.assertGreaterEqual(len(saved_inputs), len(prior_history) + 1)

    def test_endpoints_require_auth_and_override_in_tests(self):
        web = TestClient(app)
        self.assertEqual(web.post("/chat", json={"message": "Balance?"}).status_code, 401)
        app.dependency_overrides[require_user] = lambda: fake_user("test-uid")
        app.dependency_overrides[require_ai_agent_user] = lambda: fake_user("test-uid")
        try:
            self.assertEqual(web.get("/health").status_code, 200)
            self.assertEqual(web.post("/chat", json={"message": " "}).status_code, 422)
            mock_result = {"answer": "Demo", "session_id": "abc", "tool_calls": [], "mock_data": True}
            with patch("main.run_agent", return_value=mock_result):
                resp = web.post("/chat", json={"message": "Balance?"})
                self.assertEqual(resp.status_code, 200)
                self.assertEqual(resp.json()["answer"], "Demo")
            self.assertEqual(web.get("/me").json()["user_id"], "test-uid")
        finally:
            app.dependency_overrides.clear()

    def test_session_management_endpoints(self):
        web = TestClient(app)
        app.dependency_overrides[require_user] = lambda: fake_user("test-uid")
        app.dependency_overrides[require_ai_agent_user] = lambda: fake_user("test-uid")
        try:
            with patch("main.list_sessions", return_value=["s1", "s2"]):
                resp = web.get("/sessions")
                self.assertEqual(resp.status_code, 200)
                self.assertEqual(resp.json()["sessions"], ["s1", "s2"])
            with patch("main.clear_session", return_value=True):
                resp = web.delete("/sessions/s1")
                self.assertEqual(resp.status_code, 200)
                self.assertTrue(resp.json()["deleted"])
            with patch("main.clear_all_sessions", return_value=3):
                resp = web.delete("/sessions")
                self.assertEqual(resp.status_code, 200)
                self.assertEqual(resp.json()["deleted_count"], 3)
        finally:
            app.dependency_overrides.clear()


if __name__ == "__main__":
    unittest.main()
