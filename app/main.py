import os
from pathlib import Path

from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from app.repositorio import criar_repositorio

AMBIENTE = os.getenv("APP_ENV", "local")
VERSAO = os.getenv("APP_VERSION", "dev-local")
PAGINA = (Path(__file__).parent / "pagina.html").read_text(encoding="utf-8")

app = FastAPI(title="Lista de tarefas", version=VERSAO)
repositorio = criar_repositorio()


class NovaTarefa(BaseModel):
    texto: str = Field(min_length=1, max_length=200)


@app.get("/health")
def health():
    return {"status": "ok", "ambiente": AMBIENTE, "versao": VERSAO}


@app.get("/api/itens")
def listar_itens():
    return repositorio.listar()


@app.post("/api/itens", status_code=201)
def adicionar_item(tarefa: NovaTarefa):
    texto = tarefa.texto.strip()
    if not texto:
        raise HTTPException(status_code=422, detail="O texto nao pode ficar em branco.")
    return repositorio.adicionar(texto)


@app.delete("/api/itens/{item_id}", status_code=204)
def remover_item(item_id: str):
    if not repositorio.remover(item_id):
        raise HTTPException(status_code=404, detail="Item nao encontrado.")
    return Response(status_code=204)


@app.get("/", response_class=HTMLResponse)
def pagina():
    return PAGINA.replace("{{AMBIENTE}}", AMBIENTE).replace("{{VERSAO}}", VERSAO[:7])
