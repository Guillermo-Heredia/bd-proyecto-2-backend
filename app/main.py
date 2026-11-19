import logging
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from pathlib import Path
from typing import Literal

import psycopg
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from .db import cursor, pool

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("turbinas")

BASE_DIR = Path(__file__).resolve().parent

NIVELES = {"Baja", "Media", "Alta", "Critica"}
ESTADOS_ALERTA = {"Abierta", "En revision", "Cerrada"}
ESTADOS_ORDEN = {"Pendiente", "En proceso", "Finalizada", "Cancelada"}

ANALITICA = {
    "c1": {
        "titulo": "Lecturas anómalas frente a su historial de 24 h",
        "descripcion": "Lecturas con RMS >= 4 que superan 1.5 veces el promedio de las 24 horas previas del mismo sensor.",
        "archivo": "c1.sql",
        "limite": True,
    },
    "c2": {
        "titulo": "Sensores por encima del promedio de su parque",
        "descripcion": "En las últimas 48 h de datos, top 5 de sensores por parque según su RMS promedio.",
        "archivo": "c2.sql",
        "limite": True,
    },
    "c3": {
        "titulo": "Turbinas con rachas de vibración alta",
        "descripcion": "Secuencias de 3 o más lecturas consecutivas con RMS > 2.5, top 10 de turbinas.",
        "archivo": "c3.sql",
        "limite": False,
    },
    "c4": {
        "titulo": "Tendencia antes de alertas graves",
        "descripcion": "Pendiente del RMS en las 5 lecturas previas a cada alerta Alta/Crítica, por parque y componente.",
        "archivo": "c4.sql",
        "limite": True,
    },
    "c5": {
        "titulo": "Turbinas que se degradan más rápido",
        "descripcion": "Horas promedio desde la última lectura normal hasta la alerta, top 10 de turbinas.",
        "archivo": "c5.sql",
        "limite": False,
    },
}


@asynccontextmanager
async def lifespan(_app: FastAPI):
    pool.open()
    pool.wait(timeout=10)
    logger.info("Pool de PostgreSQL listo")
    yield
    pool.close()


app = FastAPI(title="Turbinas API", version="1.0.0", lifespan=lifespan)

origins = [
    o.strip()
    for o in os.getenv("CORS_ORIGINS", "http://localhost:5173").split(",")
    if o.strip()
]
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_methods=["*"],
    allow_headers=["*"],
)


def fetch_all(sql: str, params=None):
    with cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def fetch_one(sql: str, params=None):
    with cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()


def cargar_sql(nombre: str) -> str:
    ruta = BASE_DIR / "sql" / ANALITICA[nombre]["archivo"]
    lineas = [
        linea
        for linea in ruta.read_text(encoding="utf-8").splitlines()
        if linea.strip()
        and not linea.strip().startswith("--")
        and not linea.strip().upper().startswith("EXPLAIN ANALYZE")
    ]
    return "\n".join(lineas).strip().rstrip(";")


@app.exception_handler(psycopg.Error)
async def error_postgres(_request: Request, exc: psycopg.Error):
    logger.exception("Error de PostgreSQL", exc_info=exc)
    return JSONResponse(status_code=503, content={"detail": "Error de base de datos"})


@app.get("/")
def raiz():
    return {"app": "Turbinas API", "docs": "/docs", "health": "/api/health"}


@app.get("/api/health")
def health():
    fila = fetch_one("SELECT now() AS ahora, current_database() AS base")
    return {"ok": True, **fila}


@app.get("/api/contexto")
def contexto():
    return fetch_one(
        "SELECT min(fecha_hora) AS primera_lectura, max(fecha_hora) AS ultima_lectura "
        "FROM lecturavibracion"
    )


@app.get("/api/resumen")
def resumen():
    kpis = fetch_one(
        """
        SELECT
          (SELECT count(*)::int FROM parqueeolico)        AS parques,
          (SELECT count(*)::int FROM turbina)             AS turbinas,
          (SELECT count(*)::int FROM sensorvibracion)     AS sensores,
          (SELECT count(*)::int FROM lecturavibracion)    AS lecturas,
          (SELECT count(*)::int FROM alertamantenimiento
             WHERE estado <> 'Cerrada')                   AS alertas_abiertas,
          (SELECT count(*)::int FROM ordentrabajo
             WHERE estado IN ('Pendiente','En proceso'))  AS ordenes_abiertas
        """
    )
    niveles = fetch_all(
        """
        SELECT nivel, count(*)::int AS total
        FROM alertamantenimiento
        WHERE estado <> 'Cerrada'
        GROUP BY nivel
        """
    )
    orden_nivel = {"Critica": 0, "Alta": 1, "Media": 2, "Baja": 3}
    niveles.sort(key=lambda r: orden_nivel.get(r["nivel"], 9))
    top = fetch_all(
        """
        SELECT parque, id_turbina, turbina, alertas_abiertas, ultima_alerta
        FROM v_alertas_criticas_abiertas
        ORDER BY alertas_abiertas DESC, ultima_alerta DESC
        LIMIT 5
        """
    )
    ctx = fetch_one("SELECT max(fecha_hora) AS ultima_lectura FROM lecturavibracion")
    return {
        "kpis": kpis,
        "alertas_por_nivel": niveles,
        "top_turbinas": top,
        "ultima_lectura": ctx["ultima_lectura"],
    }


@app.get("/api/parques")
def parques():
    return fetch_all(
        """
        SELECT p.id_parque, p.nombre, p.ubicacion, p.capacidad_mw,
               p.fecha_operacion, count(t.id_turbina)::int AS turbinas
        FROM parqueeolico p
        LEFT JOIN turbina t USING (id_parque)
        GROUP BY p.id_parque
        ORDER BY p.nombre
        """
    )


@app.get("/api/parques/{id_parque}/turbinas")
def turbinas_de_parque(id_parque: int):
    parque = fetch_one(
        "SELECT id_parque, nombre, ubicacion, capacidad_mw FROM parqueeolico WHERE id_parque = %s",
        [id_parque],
    )
    if not parque:
        raise HTTPException(status_code=404, detail="Parque no encontrado")
    filas = fetch_all(
        """
        SELECT t.id_turbina, t.codigo, t.fabricante, t.modelo, t.capacidad_kw,
               t.fecha_instalacion, t.estado,
               count(DISTINCT c.id_componente)::int AS componentes,
               count(DISTINCT s.id_sensor)::int     AS sensores
        FROM turbina t
        LEFT JOIN componenteturbina c USING (id_turbina)
        LEFT JOIN sensorvibracion s USING (id_componente)
        WHERE t.id_parque = %s
        GROUP BY t.id_turbina
        ORDER BY t.codigo
        """,
        [id_parque],
    )
    return {"parque": parque, "turbinas": filas}


@app.get("/api/turbinas/{id_turbina}")
def turbina(id_turbina: int):
    fila = fetch_one(
        """
        SELECT t.id_turbina, t.codigo, t.fabricante, t.modelo, t.capacidad_kw,
               t.fecha_instalacion, t.estado,
               p.id_parque, p.nombre AS parque, p.ubicacion
        FROM turbina t
        JOIN parqueeolico p USING (id_parque)
        WHERE t.id_turbina = %s
        """,
        [id_turbina],
    )
    if not fila:
        raise HTTPException(status_code=404, detail="Turbina no encontrada")
    componentes = fetch_all(
        """
        SELECT c.id_componente, c.nombre, c.tipo, c.ubicacion_interna, c.estado,
               count(s.id_sensor)::int AS sensores
        FROM componenteturbina c
        LEFT JOIN sensorvibracion s USING (id_componente)
        WHERE c.id_turbina = %s
        GROUP BY c.id_componente
        ORDER BY c.nombre
        """,
        [id_turbina],
    )
    sensores = fetch_all(
        """
        SELECT s.id_sensor, s.codigo, s.modelo, s.unidad_medida, s.estado,
               c.id_componente, c.nombre AS componente
        FROM sensorvibracion s
        JOIN componenteturbina c USING (id_componente)
        WHERE c.id_turbina = %s
        ORDER BY c.nombre, s.codigo
        """,
        [id_turbina],
    )
    return {"turbina": fila, "componentes": componentes, "sensores": sensores}


@app.get("/api/turbinas/{id_turbina}/historial")
def historial_turbina(
    id_turbina: int,
    desde: datetime | None = None,
    hasta: datetime | None = None,
):
    if not fetch_one("SELECT 1 AS x FROM turbina WHERE id_turbina = %s", [id_turbina]):
        raise HTTPException(status_code=404, detail="Turbina no encontrada")
    ctx = fetch_one("SELECT max(fecha_hora) AS ultima FROM lecturavibracion")
    hasta = hasta or ctx["ultima"]
    desde = desde or (hasta - timedelta(days=90))
    return fetch_all(
        "SELECT * FROM fn_historial_turbina(%s, %s, %s)",
        [id_turbina, desde, hasta],
    )


@app.get("/api/sensores/{id_sensor}")
def sensor(id_sensor: int):
    fila = fetch_one(
        """
        SELECT s.id_sensor, s.codigo, s.modelo, s.unidad_medida,
               s.frecuencia_muestreo_hz, s.fecha_instalacion, s.estado,
               c.id_componente, c.nombre AS componente, c.tipo AS componente_tipo,
               t.id_turbina, t.codigo AS turbina,
               p.id_parque, p.nombre AS parque
        FROM sensorvibracion s
        JOIN componenteturbina c USING (id_componente)
        JOIN turbina t USING (id_turbina)
        JOIN parqueeolico p USING (id_parque)
        WHERE s.id_sensor = %s
        """,
        [id_sensor],
    )
    if not fila:
        raise HTTPException(status_code=404, detail="Sensor no encontrado")
    return fila


@app.get("/api/sensores/{id_sensor}/lecturas")
def lecturas_sensor(
    id_sensor: int,
    dias: int = Query(7, ge=1, le=180),
    desde: datetime | None = None,
    hasta: datetime | None = None,
    limit: int = Query(500, ge=1, le=2000),
):
    if not fetch_one("SELECT 1 AS x FROM sensorvibracion WHERE id_sensor = %s", [id_sensor]):
        raise HTTPException(status_code=404, detail="Sensor no encontrado")
    if not hasta:
        ctx = fetch_one("SELECT max(fecha_hora) AS ultima FROM lecturavibracion")
        hasta = ctx["ultima"]
    desde = desde or (hasta - timedelta(days=dias))
    filas = fetch_all(
        """
        SELECT fecha_hora, valor_rms, valor_pico, frecuencia_dominante_hz
        FROM lecturavibracion
        WHERE id_sensor = %s AND fecha_hora BETWEEN %s AND %s
        ORDER BY fecha_hora DESC
        LIMIT %s
        """,
        [id_sensor, desde, hasta, limit],
    )
    filas.reverse()
    return {
        "id_sensor": id_sensor,
        "desde": desde,
        "hasta": hasta,
        "total": len(filas),
        "filas": filas,
    }


@app.get("/api/sensores/{id_sensor}/estadisticas")
def estadisticas_sensor(id_sensor: int):
    if not fetch_one("SELECT 1 AS x FROM sensorvibracion WHERE id_sensor = %s", [id_sensor]):
        raise HTTPException(status_code=404, detail="Sensor no encontrado")
    filas = fetch_all(
        """
        SELECT mes, rms_promedio, rms_maximo, pico_maximo, n_lecturas
        FROM v_estadisticas_sensor_mes
        WHERE id_sensor = %s
        ORDER BY mes DESC
        LIMIT 24
        """,
        [id_sensor],
    )
    filas.reverse()
    return filas


@app.get("/api/alertas")
def alertas(
    nivel: str | None = None,
    estado: str | None = None,
    limit: int = Query(100, ge=1, le=1000),
):
    if nivel and nivel not in NIVELES:
        raise HTTPException(status_code=400, detail="Nivel inválido")
    if estado and estado not in ESTADOS_ALERTA:
        raise HTTPException(status_code=400, detail="Estado inválido")
    where, params = [], []
    if nivel:
        where.append("a.nivel = %s")
        params.append(nivel)
    if estado:
        where.append("a.estado = %s")
        params.append(estado)
    filtro = ("WHERE " + " AND ".join(where)) if where else ""
    params.append(limit)
    return fetch_all(
        f"""
        SELECT a.id_alerta, a.nivel, a.tipo_alerta, a.valor_detectado,
               a.descripcion, a.estado, a.fecha_hora, a.fecha_hora_lectura,
               s.codigo AS sensor, t.id_turbina, t.codigo AS turbina,
               p.nombre AS parque,
               EXISTS (SELECT 1 FROM alertaorden ao
                       WHERE ao.id_alerta = a.id_alerta) AS tiene_orden
        FROM alertamantenimiento a
        JOIN sensorvibracion s   USING (id_sensor)
        JOIN componenteturbina c USING (id_componente)
        JOIN turbina t           USING (id_turbina)
        JOIN parqueeolico p      USING (id_parque)
        {filtro}
        ORDER BY a.fecha_hora DESC
        LIMIT %s
        """,
        params,
    )


@app.get("/api/tecnicos")
def tecnicos():
    return fetch_all(
        "SELECT id_tecnico, nombres, especialidad FROM tecnico ORDER BY nombres"
    )


@app.get("/api/ordenes")
def ordenes(
    estado: str | None = None,
    limit: int = Query(100, ge=1, le=1000),
):
    if estado and estado not in ESTADOS_ORDEN:
        raise HTTPException(status_code=400, detail="Estado inválido")
    params = []
    filtro = ""
    if estado:
        filtro = "WHERE o.estado = %s"
        params.append(estado)
    params.append(limit)
    return fetch_all(
        f"""
        SELECT o.id_orden, o.fecha_creacion, o.fecha_programada, o.fecha_cierre,
               o.prioridad, o.tipo_mantenimiento, o.descripcion, o.estado,
               t.codigo AS turbina, p.nombre AS parque, tc.nombres AS tecnico
        FROM ordentrabajo o
        JOIN turbina t      USING (id_turbina)
        JOIN parqueeolico p USING (id_parque)
        LEFT JOIN tecnico tc USING (id_tecnico)
        {filtro}
        ORDER BY o.fecha_creacion DESC
        LIMIT %s
        """,
        params,
    )


class NuevaOrden(BaseModel):
    id_tecnico: int = Field(gt=0)
    tipo: Literal["Inspeccion", "Preventivo", "Correctivo"]


@app.post("/api/alertas/{id_alerta}/orden", status_code=201)
def crear_orden(id_alerta: int, body: NuevaOrden):
    alerta = fetch_one(
        "SELECT estado FROM alertamantenimiento WHERE id_alerta = %s", [id_alerta]
    )
    if not alerta:
        raise HTTPException(status_code=404, detail="Alerta no encontrada")
    if alerta["estado"] == "Cerrada":
        raise HTTPException(status_code=409, detail="La alerta ya está cerrada")
    if fetch_one("SELECT 1 AS x FROM alertaorden WHERE id_alerta = %s", [id_alerta]):
        raise HTTPException(status_code=409, detail="La alerta ya tiene una orden")
    try:
        with cursor(commit=True) as cur:
            cur.execute(
                "CALL sp_crear_orden_desde_alerta(%s, %s, %s, NULL)",
                [id_alerta, body.id_tecnico, body.tipo],
            )
            fila = cur.fetchone()
    except psycopg.Error as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"id_orden": fila["p_id_orden"] if fila else None}


@app.post("/api/ordenes/{id_orden}/cerrar")
def cerrar_orden(id_orden: int):
    fila = fetch_one("SELECT estado FROM ordentrabajo WHERE id_orden = %s", [id_orden])
    if not fila:
        raise HTTPException(status_code=404, detail="Orden no encontrada")
    if fila["estado"] == "Finalizada":
        raise HTTPException(status_code=409, detail="La orden ya está finalizada")
    try:
        with cursor(commit=True) as cur:
            cur.execute("CALL sp_cerrar_orden(%s)", [id_orden])
    except psycopg.Error as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True, "id_orden": id_orden}


@app.get("/api/analitica")
def listar_analitica():
    return [
        {
            "id": clave,
            "titulo": spec["titulo"],
            "descripcion": spec["descripcion"],
            "limite": spec["limite"],
        }
        for clave, spec in ANALITICA.items()
    ]


@app.get("/api/analitica/{nombre}")
def analitica(nombre: str, limit: int = Query(100, ge=1, le=500)):
    spec = ANALITICA.get(nombre)
    if not spec:
        raise HTTPException(status_code=404, detail="Consulta no encontrada")
    base = cargar_sql(nombre)
    sql = base
    params = []
    if spec["limite"]:
        sql = f"{base}\nLIMIT %s"
        params.append(limit)
    inicio = time.perf_counter()
    try:
        filas = fetch_all(sql, params)
    except psycopg.Error as exc:
        raise HTTPException(
            status_code=400, detail=f"Error ejecutando {nombre}: {exc}"
        ) from exc
    ms = (time.perf_counter() - inicio) * 1000
    return {
        "consulta": nombre,
        "titulo": spec["titulo"],
        "descripcion": spec["descripcion"],
        "sql": f"{base}\nLIMIT {limit}" if spec["limite"] else base,
        "tiempo_ms": round(ms, 2),
        "total": len(filas),
        "truncado": bool(spec["limite"] and len(filas) >= limit),
        "filas": filas,
    }
