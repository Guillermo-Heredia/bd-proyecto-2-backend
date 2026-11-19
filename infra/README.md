# Despliegue mínimo en AWS

Arquitectura:

```text
Amplify (React, HTTPS)
        |
        v
CloudFront (HTTPS)
        |
        v
EC2 t3.micro (FastAPI + Uvicorn :8000, systemd)
        |
        v
RDS PostgreSQL 16 (turbinas)
```

No hay Nginx, no hay Docker en AWS y no se crea una VPC nueva. La EC2 y RDS
usan la VPC default que ya existe en el Learner Lab.

## 1. Antes de desplegar

1. **Sube el código al repositorio.** El user data hace `git clone` del
   repositorio backend; debe contener `app/`, `infra/`, `dumps/` e
   `indices/`. El frontend vive en su propio repositorio y se despliega en
   Amplify.

   ```bash
   git status
   git add app infra dumps indices requirements.txt .env.example README.md
   git commit -m "Backend e infraestructura"
   git push
   ```

2. **Crea un key pair** en EC2 (`us-east-1`) y descarga el `.pem`.

3. **Ubica la VPC default y dos subredes en AZs distintas.** En la consola de
   VPC, copia:

   - `VpcId` de la VPC default.
   - `SubnetA` para la EC2 (debe ser una subred pública con salida a internet).
   - `SubnetB` para RDS, en otra zona de disponibilidad.

   RDS necesita subredes en al menos dos AZs, aunque no sea Multi-AZ.

4. Ten a mano:

   - Tu IP pública para SSH: `https://checkip.amazonaws.com`.
   - Una contraseña para el usuario maestro de RDS.
   - Una contraseña distinta para `app_turbinas`.

Las contraseñas deben usar solo letras, números, punto, guion o guion bajo
(`^[A-Za-z0-9._-]{8,41}$`).

## 2. Qué crea el stack

| Recurso | Detalle |
|---|---|
| EC2 | Amazon Linux 2023, `t3.micro`, 20 GB gp3, Elastic IP, `LabInstanceProfile`. |
| RDS | PostgreSQL 16, `db.t3.micro`, 20 GB gp2, sin Multi-AZ, sin acceso público. |
| Security Group API | SSH desde tu IP; puerto 8000 solo desde CloudFront. |
| Security Group RDS | 5432 solo desde el Security Group de la EC2. |
| CloudFront | HTTPS del API, sin caché, todos los métodos necesarios. |
| User data | Instala Python 3.11, clona el repo, crea el venv, restaura el dump y arranca `turbinas-api`. |

## 3. Parámetros

| Parámetro | Valor |
|---|---|
| `ProjectName` | `turbinas` |
| `VpcId` | VPC default |
| `SubnetA` | Subred pública de la EC2 |
| `SubnetB` | Otra subred, otra AZ |
| `KeyName` | Tu key pair |
| `SshAllowedCidr` | `TU_IP/32` |
| `InstanceProfileName` | `LabInstanceProfile` |
| `DbPassword` | contraseña del usuario `postgres` |
| `AppDbPassword` | contraseña de `app_turbinas` |
| `DbEngineVersion` | `16` |
| `RestoreDatabase` | `true` |
| `CorsOrigins` | `*` para la primera demo; luego el dominio de Amplify |

`CorsOrigins` se cambia después de crear Amplify. Si se deja `*`, la API es
accesible desde cualquier origen; para la demo funciona, pero no es lo ideal.

## 4. Desplegar desde la consola

1. CloudFormation → **Create stack** → **With new resources**.
2. Sube `infra/turbinas.yml`.
3. Stack name: `turbinas`.
4. Completa los parámetros de la tabla anterior.
5. No se necesitan capabilities de IAM: el stack solo referencia un instance
   profile existente.
6. Espera a que el stack llegue a `CREATE_COMPLETE`. RDS tarda varios minutos;
   CloudFront también.

## 5. Desplegar con AWS CLI

Si tienes AWS CLI configurado:

```bash
aws cloudformation deploy \
  --region us-east-1 \
  --stack-name turbinas \
  --template-file infra/turbinas.yml \
  --parameter-overrides \
    ProjectName=turbinas \
    VpcId=vpc-xxxxxxxx \
    SubnetA=subnet-aaaaaaaa \
    SubnetB=subnet-bbbbbbbb \
    KeyName=tu-llave \
    SshAllowedCidr=TU_IP/32 \
    InstanceProfileName=LabInstanceProfile \
    DbPassword='TU_PASSWORD_RDS' \
    AppDbPassword='TU_PASSWORD_APP' \
    DbEngineVersion=16 \
    RestoreDatabase=true \
    CorsOrigins='*'
```

No uses esta forma si la contraseña queda en el historial del shell. En la
consola es más seguro para el laboratorio.

## 6. Verificar

En **Outputs** del stack:

- `ApiBase`: URL HTTPS de CloudFront.
- `ApiHealth`: URL completa del health check.
- `ElasticIP`: IP pública de la EC2.
- `RdsEndpoint`: endpoint de RDS.
- `SshCommand`: comando SSH de referencia.

Prueba:

```bash
curl -i https://dxxxxxxxxxxxx.cloudfront.net/api/health
```

Debe responder `{"ok":true,...}` con la base `turbinas`.

Entra por SSH:

```bash
ssh -i tu-llave.pem ec2-user@<ElasticIP>
```

Revisa el bootstrap:

```bash
sudo tail -f /var/log/turbinas-bootstrap.log
sudo systemctl status turbinas-api
sudo journalctl -u turbinas-api -n 80 --no-pager
curl http://127.0.0.1:8000/api/health
```

Si CloudFront aún no está listo, usa un túnel SSH para probar el API directo:

```bash
ssh -i tu-llave.pem -L 8000:127.0.0.1:8000 ec2-user@<ElasticIP>
curl http://127.0.0.1:8000/api/health
```

Comprueba los datos:

```bash
sudo -u ec2-user bash -lc '
  cd /opt/turbinas
  set -a; . ./.env; set +a
  psql "host=$PGHOST dbname=$PGDATABASE user=$PGUSER sslmode=require" \
    -c "SELECT count(*) FROM lecturavibracion;"
'
```

El resultado esperado es `991610`.

Prueba las consultas y una orden:

```bash
curl -s https://dxxxxxxxxxxxx.cloudfront.net/api/analitica/c1?limit=5
curl -s https://dxxxxxxxxxxxx.cloudfront.net/api/analitica/c3
```

En la web, crea una orden desde una alerta y ciérrala. Esto valida los permisos
de `sp_crear_orden_desde_alerta` y `sp_cerrar_orden`.

## 7. Configurar Amplify

El `amplify.yml` debe estar en la raíz del repositorio **frontend**:

```yaml
version: 1
applications:
  - frontend:
      phases:
        preBuild:
          commands:
            - npm ci
        build:
          commands:
            - npm run build
      artifacts:
        baseDirectory: dist
        files:
          - "**/*"
```

En la consola de Amplify:

1. Conecta el repositorio y la rama `main`.
2. Agrega la variable de entorno:

   ```text
   VITE_API_URL=https://dxxxxxxxxxxxx.cloudfront.net
   ```

3. Configura el rewrite de React Router:

   ```text
   Source: /<*>
   Target: /index.html
   Type: Rewrite (200)
   ```

4. Despliega. Copia el dominio de Amplify
   (`https://main.xxxxxxxx.amplifyapp.com`).

5. Edita el `.env` de la EC2 y reinicia (recomendado; no reemplaza la
   instancia):

   ```bash
   sudo -u ec2-user nano /opt/turbinas/.env
   sudo systemctl restart turbinas-api
   ```

   Cambia `CORS_ORIGINS=*` por `CORS_ORIGINS=https://main.xxxxxxxx.amplifyapp.com`.
   Para la primera demo se puede dejar `*`.

Si Amplify no está disponible en el Learner Lab, publica el `dist` del repo
frontend en S3 + CloudFront. El API no cambia.

## 8. Restauración manual

El bootstrap restaura automáticamente cuando `RestoreDatabase=true`. Si falla,
revisa el log y vuelve a ejecutarlo:

```bash
sudo bash /opt/turbinas/infra/bootstrap.sh
```

También puedes hacerlo a mano desde la EC2:

```bash
cd /opt/turbinas
export PGPASSWORD='<DbPassword>'
export RDSHOST='<RdsEndpoint>'
pg_restore -h "$RDSHOST" -U postgres -d turbinas \
  --no-owner --no-privileges -j 2 dumps/bd_1m.dump
psql "host=$RDSHOST user=postgres dbname=turbinas sslmode=require" \
  -f indices/crear_indices.sql
psql "host=$RDSHOST user=postgres dbname=turbinas sslmode=require" \
  -c 'VACUUM ANALYZE;'
```

Después crea el usuario y permisos. El bootstrap ya lo hace; si lo haces a mano,
no olvides `sp_cerrar_orden`:

```sql
CREATE ROLE app_turbinas LOGIN PASSWORD 'TU_PASSWORD_APP';
GRANT CONNECT ON DATABASE turbinas TO app_turbinas;
GRANT USAGE ON SCHEMA public TO app_turbinas;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_turbinas;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO app_turbinas;

ALTER PROCEDURE sp_crear_orden_desde_alerta(bigint, int, varchar, bigint)
  SECURITY DEFINER;
ALTER PROCEDURE sp_crear_orden_desde_alerta(bigint, int, varchar, bigint)
  SET search_path = public, pg_temp;
GRANT EXECUTE ON PROCEDURE
  sp_crear_orden_desde_alerta(bigint, int, varchar, bigint) TO app_turbinas;

ALTER PROCEDURE sp_cerrar_orden(bigint) SECURITY DEFINER;
ALTER PROCEDURE sp_cerrar_orden(bigint) SET search_path = public, pg_temp;
GRANT EXECUTE ON PROCEDURE sp_cerrar_orden(bigint) TO app_turbinas;
```

## 9. Problemas frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| CloudFront 502 | API caída o puerto incorrecto | `systemctl status turbinas-api`; `curl 127.0.0.1:8000/api/health`. |
| CloudFront 504 | Consulta lenta o API colgada | Revisar `journalctl`; C3 puede tardar ~5 s. |
| 403/CORS en Amplify | Origen no permitido | `CORS_ORIGINS=https://main.xxx.amplifyapp.com` y reiniciar. |
| 404 al recargar una ruta | Falta rewrite SPA | Regla `/<*>` → `/index.html` 200. |
| `password authentication failed` | Contraseña o usuario | Revisar `.env`; el usuario de la app es `app_turbinas`. |
| `connection refused` a RDS | SG, endpoint o subredes | RDS debe aceptar 5432 desde el SG de la EC2. |
| `permission denied for procedure sp_cerrar_orden` | Faltan grants | Ejecutar el bloque SQL de la sección 8. |
| RDS no crea el subnet group | Subredes en la misma AZ | Elegir `SubnetA` y `SubnetB` en AZs distintas. |
| Error con `SourcePrefixListId` | Región sin mapping | Editar `CloudFrontPrefixList` en el YAML o usar `us-east-1`. |
| `LabRole` no se adjunta | Es un rol, no un profile | Usar `LabInstanceProfile`. |
| La EC2 no tiene el código | `web/` no está en GitHub | Hacer commit y push antes de crear el stack. |

## 10. Eliminar

Desde CloudFormation, elimina el stack `turbinas`. Se borran la EC2, la Elastic
IP, RDS y CloudFront. RDS no crea snapshot final; si necesitas conservar datos:

```bash
pg_dump -h "$RDSHOST" -U postgres -d turbinas -Fc -f respaldo.dump
```

## 11. Notas de seguridad

- RDS no tiene IP pública y solo acepta conexiones desde la EC2.
- La EC2 no acepta el puerto 8000 desde internet: solo desde la prefix list de
  CloudFront.
- SSH está limitado a `SshAllowedCidr`.
- `app_turbinas` solo puede leer tablas y ejecutar los dos procedimientos.
- `PGSSLMODE=require` en la conexión FastAPI → RDS.
- Las contraseñas quedan en el user data de EC2 y en `.env`; para producción se
  usaría Secrets Manager o SSM Parameter Store.
- `CorsOrigins=*` es solo para la primera demo.
