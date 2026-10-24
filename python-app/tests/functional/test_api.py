"""Functional tests: start the real app on a real port and call it over HTTP."""
import threading

import pytest
import requests
from werkzeug.serving import make_server

from app import create_app

pytestmark = pytest.mark.functional


@pytest.fixture(scope="module")
def base_url():
    server = make_server("127.0.0.1", 0, create_app())  # port 0 = any free port
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()


def test_root(base_url):
    r = requests.get(f"{base_url}/", timeout=5)
    assert r.status_code == 200
    assert r.text == "Hello from demo-py-app"


def test_health(base_url):
    r = requests.get(f"{base_url}/health", timeout=5)
    assert r.status_code == 200
    assert r.text == "OK"


def test_add(base_url):
    r = requests.get(f"{base_url}/add", params={"a": 2, "b": 40}, timeout=5)
    assert r.status_code == 200
    assert r.text == "42"


def test_add_bad_input(base_url):
    r = requests.get(f"{base_url}/add", params={"a": "x", "b": 1}, timeout=5)
    assert r.status_code == 400
