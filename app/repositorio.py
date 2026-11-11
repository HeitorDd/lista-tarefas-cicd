"""Onde as tarefas ficam guardadas.

- RepositorioMemoria: guarda na memoria do processo (para rodar localmente sem AWS).
- RepositorioDynamo: guarda numa tabela do Amazon DynamoDB (usado nos ambientes da AWS).

Os dois tem os mesmos metodos, entao a API nao precisa saber qual esta em uso.
"""

from __future__ import annotations

import os
import uuid
from datetime import UTC, datetime


def _nova_tarefa(texto: str) -> dict:
    return {
        "id": uuid.uuid4().hex,
        "texto": texto,
        "criado_em": datetime.now(UTC).isoformat(),
    }


class RepositorioMemoria:
    def __init__(self) -> None:
        self._itens: dict[str, dict] = {}

    def listar(self) -> list[dict]:
        return sorted(self._itens.values(), key=lambda i: i["criado_em"])

    def adicionar(self, texto: str) -> dict:
        item = _nova_tarefa(texto)
        self._itens[item["id"]] = item
        return item

    def remover(self, item_id: str) -> bool:
        return self._itens.pop(item_id, None) is not None


class RepositorioDynamo:
    def __init__(self, nome_tabela: str, regiao: str | None = None) -> None:
        import boto3

        self._tabela = boto3.resource("dynamodb", region_name=regiao).Table(nome_tabela)

    def listar(self) -> list[dict]:
        resposta = self._tabela.scan()
        itens = resposta.get("Items", [])
        while "LastEvaluatedKey" in resposta:
            resposta = self._tabela.scan(ExclusiveStartKey=resposta["LastEvaluatedKey"])
            itens.extend(resposta.get("Items", []))
        return sorted(itens, key=lambda i: i["criado_em"])

    def adicionar(self, texto: str) -> dict:
        item = _nova_tarefa(texto)
        self._tabela.put_item(Item=item)
        return item

    def remover(self, item_id: str) -> bool:
        resposta = self._tabela.delete_item(Key={"id": item_id}, ReturnValues="ALL_OLD")
        return "Attributes" in resposta


def criar_repositorio():
    """Usa DynamoDB se a variavel TABLE_NAME existir; senao, memoria."""
    nome_tabela = os.getenv("TABLE_NAME")
    if nome_tabela:
        regiao = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION")
        return RepositorioDynamo(nome_tabela, regiao)
    return RepositorioMemoria()
