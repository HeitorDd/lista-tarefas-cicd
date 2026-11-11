"""Testa o repositorio do DynamoDB sem acessar a AWS de verdade (usa o moto, um simulador)."""

import boto3
import pytest
from moto import mock_aws

from app.repositorio import RepositorioDynamo, RepositorioMemoria, criar_repositorio

REGIAO = "us-east-2"
TABELA = "tarefas-teste"


@pytest.fixture
def credenciais_falsas(monkeypatch):
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "teste")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "teste")
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGIAO)


@pytest.fixture
def repo(credenciais_falsas):
    with mock_aws():
        boto3.client("dynamodb", region_name=REGIAO).create_table(
            TableName=TABELA,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        yield RepositorioDynamo(TABELA, REGIAO)


def test_adicionar_listar_remover(repo):
    primeiro = repo.adicionar("primeiro")
    segundo = repo.adicionar("segundo")

    assert [i["texto"] for i in repo.listar()] == ["primeiro", "segundo"]

    assert repo.remover(primeiro["id"]) is True
    assert [i["id"] for i in repo.listar()] == [segundo["id"]]


def test_remover_inexistente(repo):
    assert repo.remover("nao-existe") is False


def test_criar_repositorio_escolhe_pelo_ambiente(monkeypatch, credenciais_falsas):
    monkeypatch.delenv("TABLE_NAME", raising=False)
    assert isinstance(criar_repositorio(), RepositorioMemoria)

    monkeypatch.setenv("TABLE_NAME", TABELA)
    with mock_aws():
        assert isinstance(criar_repositorio(), RepositorioDynamo)
