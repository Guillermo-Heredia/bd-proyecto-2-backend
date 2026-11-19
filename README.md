# Backend de turbinas

API FastAPI y base PostgreSQL para la demo de turbinas. Este repositorio
contiene **solo el backend y su infraestructura**; el frontend está en
`bd-proyecto-2-fronted` y se despliega en Amplify.

```text
Amplify (React) -> API Gateway -> EC2 (FastAPI :8000) -> RDS PostgreSQL 16
```

## Estructura

```text
.
├── app/                    # FastAPI: main, db y consultas C1-C5
├── requirements.txt
├── .env.example
├── dumps/
│   └── bd_1m.dump          # datos para restaurar en RDS
├── indices/
│   ├── crear_indices.sql
│   └── borrar_indices.sql
└── infra/
    ├── turbinas.yml        # EC2 + RDS + API Gateway
    ├── bootstrap.sh        # se ejecuta en la EC2
    └── README.md           # despliegue paso a paso
```

## Desarrollo local

Crea el entorno e instala dependencias:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
cp .env.example .env
```

Edita `.env` con tu PostgreSQL local y arranca:

```bash
.venv/bin/uvicorn app.main:app --reload --port 8000
```

- API: <http://127.0.0.1:8000>
- Documentación: <http://127.0.0.1:8000/docs>
- Salud: <http://127.0.0.1:8000/api/health>

El frontend hace proxy de `/api` a este puerto.

## Endpoints principales

| Método | Ruta | Uso |
|---|---|---|
| GET | `/api/health` | Estado de la API y la base |
| GET | `/api/contexto` | Rango temporal de las lecturas |
| GET | `/api/resumen` | KPIs y resumen general |
| GET | `/api/parques` | Catálogo de parques |
| GET | `/api/parques/{id}/turbinas` | Turbinas por parque |
| GET | `/api/alertas` | Alertas de mantenimiento |
| GET | `/api/ordenes` | Órdenes de trabajo |
| GET | `/api/analitica/c1` ... `/c5` | Consultas del experimento |

## Despliegue

La guía completa está en [`infra/README.md`](infra/README.md). Resumen:

1. El repositorio debe ser **público** para que la EC2 pueda hacer `git clone`
   sin credenciales. Si es privado, hay que configurar un token de GitHub.
2. Crea el stack con `infra/turbinas.yml`. El parámetro `RepoUrl` ya apunta a
   este repositorio.
3. El user data clona el repo en `/opt/turbinas`, ejecuta
   `infra/bootstrap.sh`, instala Python 3.11, restaura
   `dumps/bd_1m.dump`, crea `app_turbinas` y arranca `turbinas-api`.
4. Configura Amplify con la URL de API Gateway y actualiza `CORS_ORIGINS` en el
   `.env` de la EC2.

No hay Nginx ni Docker en AWS. El API corre con Uvicorn y `systemd`.

## Variables de entorno

Revisa `.env.example`. En producción el bootstrap genera `/opt/turbinas/.env`
con los datos de RDS. No subas `.env` ni contraseñas al repositorio.
