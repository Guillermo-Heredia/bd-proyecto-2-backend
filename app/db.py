import os
from contextlib import contextmanager

from dotenv import load_dotenv
from psycopg.conninfo import make_conninfo
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

load_dotenv()


def _conninfo() -> str:
    url = os.getenv("DATABASE_URL", "").strip()
    if url:
        return url
    return make_conninfo(
        host=os.getenv("PGHOST", "127.0.0.1"),
        port=os.getenv("PGPORT", "5432"),
        dbname=os.getenv("PGDATABASE", "bd_web"),
        user=os.getenv("PGUSER", "postgres"),
        password=os.getenv("PGPASSWORD", "postgres"),
        sslmode=os.getenv("PGSSLMODE", "prefer"),
    )


pool = ConnectionPool(
    conninfo=_conninfo(),
    min_size=1,
    max_size=int(os.getenv("PGPOOL_MAX", "10")),
    timeout=10,
    kwargs={
        "row_factory": dict_row,
        "options": "-c statement_timeout="
        + os.getenv("PG_STATEMENT_TIMEOUT_MS", "25000"),
    },
    open=False,
)


@contextmanager
def cursor(commit: bool = False):
    with pool.connection() as conn:
        with conn.cursor() as cur:
            yield cur
        if commit:
            conn.commit()
