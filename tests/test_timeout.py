"""Tests for the default request timeout on the shared HTTP session.

Issue: `NotionClient.post` called `session.post(...)` with no timeout, so a
connection that stalls after it is established blocks forever and the urllib3
Retry never gets a chance to help. Every session request now goes through a
`_TimeoutAdapter` that fills in a default (connect, read) timeout when the
caller doesn't pass one.
"""

import os
import sys

import pytest
import requests
from requests.adapters import HTTPAdapter
from requests.models import Response

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "packages", "unpy-core", "src"))

from unpy.client import DEFAULT_CONNECT_TIMEOUT, NotionClient, _TimeoutAdapter, create_session
from unpy.config import DEFAULT_REQUEST_TIMEOUT, request_timeout

DEFAULT_TIMEOUT = (DEFAULT_CONNECT_TIMEOUT, DEFAULT_REQUEST_TIMEOUT)


@pytest.fixture
def captured_send(monkeypatch):
    """Replace HTTPAdapter.send with a stub that records the timeout kwarg and
    returns a bare 200 Response (Session.send tolerates one)."""
    captured = {}

    def fake_send(self, request, **kwargs):
        captured["timeout"] = kwargs.get("timeout")
        response = Response()
        response.status_code = 200
        response.request = request
        return response

    monkeypatch.setattr(HTTPAdapter, "send", fake_send)
    return captured


# ---- config knob ----


class TestRequestTimeoutConfig:
    def test_default(self, monkeypatch):
        monkeypatch.delenv("UNPY_REQUEST_TIMEOUT", raising=False)
        assert request_timeout() == DEFAULT_REQUEST_TIMEOUT == 120.0

    def test_env_override(self, monkeypatch):
        monkeypatch.setenv("UNPY_REQUEST_TIMEOUT", "45")
        assert request_timeout() == 45.0

    def test_invalid_value_falls_back_to_default(self, monkeypatch):
        monkeypatch.setenv("UNPY_REQUEST_TIMEOUT", "not-a-number")
        assert request_timeout() == DEFAULT_REQUEST_TIMEOUT

    def test_zero_or_negative_never_disables_the_timeout(self, monkeypatch):
        monkeypatch.setenv("UNPY_REQUEST_TIMEOUT", "0")
        assert request_timeout() == DEFAULT_REQUEST_TIMEOUT
        monkeypatch.setenv("UNPY_REQUEST_TIMEOUT", "-5")
        assert request_timeout() == DEFAULT_REQUEST_TIMEOUT


# ---- session wiring ----


class TestCreateSessionTimeoutAdapter:
    def test_https_and_http_mount_a_timeout_adapter(self):
        session = create_session()
        for url in ("https://www.notion.so/api/v3/loadUserContent", "http://example.com/x"):
            adapter = session.get_adapter(url)
            assert isinstance(adapter, _TimeoutAdapter)
            assert adapter._timeout == DEFAULT_TIMEOUT

    def test_env_override_flows_into_the_adapter(self, monkeypatch):
        monkeypatch.setenv("UNPY_REQUEST_TIMEOUT", "45")
        adapter = create_session().get_adapter("https://www.notion.so/x")
        assert adapter._timeout == (DEFAULT_CONNECT_TIMEOUT, 45.0)

    def test_explicit_client_retry_is_still_honored(self):
        retry = requests.packages.urllib3.util.retry.Retry(total=2)
        adapter = create_session(retry).get_adapter("https://www.notion.so/x")
        assert adapter.max_retries is retry


# ---- adapter behavior ----


class TestTimeoutAdapterSend:
    def _adapter(self):
        return _TimeoutAdapter(max_retries=None, pool_connections=1, pool_maxsize=1)

    def test_fills_default_timeout_when_none(self, captured_send):
        self._adapter().send(request=None)
        assert captured_send["timeout"] == DEFAULT_TIMEOUT

    def test_preserves_explicit_timeout(self, captured_send):
        self._adapter().send(request=None, timeout=30)
        assert captured_send["timeout"] == 30
        self._adapter().send(request=None, timeout=(5, 60))
        assert captured_send["timeout"] == (5, 60)

    def test_preserves_custom_adapter_default(self, captured_send):
        adapter = _TimeoutAdapter(timeout=(3, 90))
        adapter.send(request=None)
        assert captured_send["timeout"] == (3, 90)


# ---- the reported hang: NotionClient.post (issue: client.py session.post) ----


class TestNotionClientPostTimeout:
    def _client(self, monkeypatch):
        # _update_user_info hits the live API on __init__; stub it — not the
        # subject under test.
        monkeypatch.setattr(NotionClient, "_update_user_info", lambda self: None)
        return NotionClient(token_v2="test-token-v2")

    def test_post_carries_default_timeout(self, captured_send, monkeypatch):
        client = self._client(monkeypatch)
        client.post("api/v3/testEndpoint", {"data": 1})
        assert captured_send["timeout"] == DEFAULT_TIMEOUT

    def test_session_post_without_timeout_gets_one(self, captured_send):
        # Any session.get/post caller that passes no timeout (monitor polling,
        # utils redirect resolution) is covered the same way.
        create_session().post("https://www.notion.so/api/v3/x", json={})
        assert captured_send["timeout"] == DEFAULT_TIMEOUT
