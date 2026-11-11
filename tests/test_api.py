import pytest
from fastapi.testclient import TestClient

import app.main as main
from app.repositorio import RepositorioMemoria


@pytest.fixture
def cliente(monkeypatch):
    # Cada teste comeca com uma lista vazia, guardada em memoria.
    monkeypatch.setattr(main, "repositorio", RepositorioMemoria())
    return TestClient(main.app)


def test_health(cliente):
    resposta = cliente.get("/health")
    assert resposta.status_code == 200
    corpo = resposta.json()
    assert corpo["status"] == "ok"
    assert "ambiente" in corpo
    assert "versao" in corpo


def test_lista_comeca_vazia(cliente):
    assert cliente.get("/api/itens").json() == []


def test_adicionar_e_listar(cliente):
    resposta = cliente.post("/api/itens", json={"texto": "  Estudar CI/CD  "})
    assert resposta.status_code == 201
    item = resposta.json()
    assert item["texto"] == "Estudar CI/CD"
    assert item["id"]

    itens = cliente.get("/api/itens").json()
    assert [i["texto"] for i in itens] == ["Estudar CI/CD"]


def test_remover(cliente):
    item = cliente.post("/api/itens", json={"texto": "Apagar depois"}).json()
    assert cliente.delete(f"/api/itens/{item['id']}").status_code == 204
    assert cliente.get("/api/itens").json() == []


def test_remover_inexistente_retorna_404(cliente):
    assert cliente.delete("/api/itens/nao-existe").status_code == 404


@pytest.mark.parametrize("texto", ["", "   ", "x" * 201])
def test_texto_invalido_retorna_422(cliente, texto):
    assert cliente.post("/api/itens", json={"texto": texto}).status_code == 422


def test_pagina_mostra_ambiente(cliente):
    resposta = cliente.get("/")
    assert resposta.status_code == 200
    assert "Lista de tarefas" in resposta.text
    assert "{{AMBIENTE}}" not in resposta.text
