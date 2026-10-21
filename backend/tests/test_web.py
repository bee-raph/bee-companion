"""The web shell shares the API service without weakening API authentication."""
from fastapi.testclient import TestClient
from app.main import app


def test_web_shell_and_assets():
    with TestClient(app) as client:
        response = client.get('/')
        assert response.status_code == 200
        assert 'Bee Companion' in response.text
        for path in ('app.js', 'store.js', 'agenda.js', 'richtext.js', 'clocks.js', 'app.css', 'manifest.json'):
            assert client.get('/web/' + path).status_code == 200
        assert client.get('/sw.js').headers['service-worker-allowed'] == '/'
        assert client.get('/web/../main.py').status_code == 404
        assert client.get('/api/unknown').status_code == 404
        assert client.get('/docs').status_code == 200
