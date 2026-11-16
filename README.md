# geonode-base
Imagem base mais segura e enxuta de geonode 5.x para instâncias do SGB

Imagem base do GeoNode derivada de [`ndscprm/gdal`](https://hub.docker.com/r/ndscprm/gdal)
(GDAL compilado com Oracle, Arrow/Parquet e bindings Python), no lugar da imagem
`geonode/geonode-base` baseada em Ubuntu.

É um port do [`docker/base/ubuntu/26/Dockerfile`](https://github.com/GeoNode/geonode/blob/master/docker/base/ubuntu/26/Dockerfile)
do GeoNode. Ela substitui `geonode/geonode-base` no `FROM` do `Dockerfile` do GeoNode ou de um geonode-project.

## Build

```sh
docker build -t geonode-base:3.12.4 .

# outra tag da imagem do GDAL
docker build --build-arg GDAL_TAG=3.12.4-py3.12 -t geonode-base:3.12.4 .
```

O build precisa do BuildKit (padrão no Docker atual), por causa do `RUN --mount`.

Argumentos:

| Argumento          | Padrão                   | Uso                                                              |
|--------------------|--------------------------|------------------------------------------------------------------|
| `GDAL_IMAGE`       | `docker.io/ndscprm/gdal` | repositório da imagem do GDAL                                    |
| `GDAL_TAG`         | `3.12.4-py3.12`          | tag da imagem final (variante `-py`). O builder usa `${GDAL_TAG}-devel` |
| `UWSGI_VERSION`    | `2.0.30`                 | uWSGI, igual ao pin do GeoNode                                   |
| `PSYCOPG2_VERSION` | `2.9.13`                 | psycopg2, igual ao pin do GeoNode                                |
| `INVOKE_VERSION`   | `2.2.0`                  | invoke                                                           |
| `SHERLOCK_VERSION` | `0.4.1`                  | sherlock                                                         |
| `NUMPY_VERSION`    | `1.26.*`                 | numpy, igual ao pin do GeoNode                                   |

## Multi-stage

| Estágio   | Imagem                         | Função                                                                 |
|-----------|--------------------------------|------------------------------------------------------------------------|
| `builder` | `ndscprm/gdal:${GDAL_TAG}-devel` | compila as wheels (uWSGI, psycopg2 e as demais) e lista as bibliotecas Debian que os binários usam (`ldd` + `dpkg -S`) |
| final     | `ndscprm/gdal:${GDAL_TAG}`     | instala só essas bibliotecas e as wheels, sem compiladores nem headers |

As duas imagens têm o mesmo Debian, o mesmo Python e o mesmo `/opt/geosgb`, por isso as wheels compiladas no
builder funcionam na imagem final.

**Consequência para as imagens derivadas**: a imagem final não tem `gcc` nem pacotes `-dev`. O `pip install` do
GeoNode funciona porque uWSGI e psycopg2 já estão instalados nas versões que ele fixa, e as demais dependências têm
wheels no PyPI. Por isso, `UWSGI_VERSION`, `PSYCOPG2_VERSION` e `NUMPY_VERSION` precisam acompanhar o `pyproject.toml` do GeoNode.
Um geonode-project que dependa de outro pacote sem wheel precisa compilar num estágio próprio, a partir da imagem
`-devel`, ou instalar o compilador.

## Diferenças em relação à base do GeoNode

- **SO e Python**: Debian trixie com Python 3.12 em `/usr/local` (de `python:3.12-slim-trixie`), não Ubuntu.
- **GDAL**: biblioteca, utilitários e bindings Python vêm de `/opt/geosgb`. Os pacotes `libgdal-dev`,
  `gdal-bin` e `python3-gdal` não são instalados, para não haver um segundo GDAL na imagem.
- **Virtualenv**: é o `/opt/geosgb/venv` da imagem do GDAL, que já tem `osgeo` e `numpy`. O numpy cai para o 1.x
  e o `pyarrow` é removido. Veja [numpy e pyarrow](#numpy-e-pyarrow).
  `/usr/src/venv` continua existindo como link simbólico para ele, e `/usr/local/bin/invoke` também é mantido.
- **Pacotes `python3-*` e `uwsgi` do sistema**: não são instalados. uWSGI, invoke e sherlock vão para o venv via pip,
  junto com o psycopg2, compilado no builder.
- **Compiladores e headers** (`build-essential`, `gcc`, `libpq-dev`, `libxml2-dev` etc.): ficam só no builder.
  Veja [Multi-stage](#multi-stage).
- **Ferramentas de empacotamento Debian** (`devscripts`, `debhelper`, `pkg-kde-tools`): removidas, eram usadas só por
  um build do PROJ que está comentado no upstream.
- **`wheel==0.38.1`**: não é instalado. O setuptools do venv precisa de um `wheel` mais novo.
- **Cliente PostgreSQL**: `postgresql-client` do repositório oficial do Debian (17 no trixie), a mesma versão do
  `libpq5` usado pelo GDAL da imagem. O upstream usa o 15 do PGDG. O bloco do PGDG ficou comentado no Dockerfile,
  para o caso de ser preciso outra versão. Veja [Compatibilidade do cliente PostgreSQL](#compatibilidade-do-cliente-postgresql).
- **Entrypoint**: a imagem herda o `ENTRYPOINT ["/docker-entrypoint.sh"]` do GDAL, que roda os scripts de
  `/docker-entrypoint.d` (incluindo o nss_wrapper para UIDs arbitrários) antes do comando.

## Comparação com as bases do GeoNode

Comparado em 16/11/2026 com as duas bases publicadas pelo GeoNode, conferindo o que o código do GeoNode master
(commit `c125d8f`) usa de fato. O master usa a `latest-ubuntu-26.04`. As duas imagens upstream são só amd64.

| Item | `latest-ubuntu-24.04` | `latest-ubuntu-26.04` | Esta imagem | Uso no GeoNode |
|---|---|---|---|---|
| Tamanho | 1,44 GB | 1,66 GB | 850 MB | — |
| SO | Ubuntu 24.04.5 | Ubuntu 26.04.1 | Debian 13 (trixie) | — |
| Python | 3.12.3 | 3.14.4 | 3.12.16 | `requires-python >= 3.10` |
| GDAL | 3.8.4, 216 drivers | 3.12.2, 210 drivers | 3.12.4, 62 drivers (+ OCI, Arrow, Parquet) | ver abaixo |
| PROJ | 9.4.0 | 9.7.1 | 9.6.0 | — |
| Cliente PostgreSQL | 15.19 (PGDG) | 15.19 (PGDG) | 17.12 (Debian) | ver [Compatibilidade](#compatibilidade-do-cliente-postgresql) |
| `ogr2ogr`, `gdal_translate`, `psql`, `pg_dump`, `pg_restore`, `pg_isready` | sim | sim | sim | importer, backup (`geonode.br`), `tasks.py` |
| `uwsgi`, `invoke`, `celery`, `cron`, `git`, `msgfmt`, `curl` | sim | sim | sim | entrypoint, `celery-cmd`, `tasks.py`, versão |
| `libmagic` | sim (via `libgdal-dev`) | sim (via `libgdal-dev`) | sim (`libmagic1`) | `python-magic` no `FileValidationUploadHandler`, em todo upload |
| `psycopg2`, `numpy` no venv | não | não | sim | instalados pelo `pip install` do GeoNode |
| compiladores e headers | sim | sim | não | só para compilar dependências. Veja [Multi-stage](#multi-stage) |
| `libspatialite`, `spatialite` | só a biblioteca | só a biblioteca | não | só com o `DATABASE_URL` padrão de desenvolvimento (SQLite). Em Docker o banco é PostGIS |
| `libmemcached` | sim | não | não | não é usado (o cache é Redis, via `django-redis`) |
| `procps` (`ps`, `top`, `pkill`), `file`, `less` | sim | sim | sim | não são usados pelo GeoNode. Ficam na imagem para depurar. O `ps` do `docker-compose.yml` é do container do nginx |

A `latest-ubuntu-24.04` traz o GDAL 3.8.4. Com o pin `GDAL==3.12.2` do GeoNode master, o pip tentaria compilar
os bindings 3.12.2 contra a biblioteca 3.8.4, o que não funciona. Por isso ela não serve para o master, só para versões
anteriores do GeoNode. Os drivers que ela tem a mais que a 26.04 (Memory, SVG, TIGER, SDTS, OGDI e outros legados)
também não são usados pelo GeoNode.

**Drivers do GDAL**: os handlers do importer usam `ESRI Shapefile`, `GeoJSON`, `GPKG`, `KML`, `CSV` (também para
XLSX/XLS, lidos com `python-calamine`) e `GTiff`. O destino é `PostgreSQL` ou `PGDump` piped para o `psql`, e o
COG remoto vai via `/vsicurl/`. Todos esses drivers estão presentes. Testado: shp, geojson, gpkg, kml, kmz (LIBKML),
csv → `ogr2ogr -f PGDump`, e GTiff → COG. Os 151 drivers que faltam (HDF, netCDF, GRIB, MBTiles, FlatGeobuf, XLSX,
DXF, PDF, OSM etc.) não são usados pelo GeoNode.

O `KMLFileHandler` abre `.kmz` com o driver `KML`, que não lê KMZ, aqui e nas duas imagens upstream. É um comportamento
do GeoNode, não desta imagem.

## Segurança e boas práticas (comparação com a `latest-ubuntu-26.04`)

Análise de 16/11/2026, com Trivy 0.76.1 (CVEs e segredos), Grype v0.121.0 (SBOMs de `/opt/geosgb`), Dockle v0.4.15
(imagem) e Hadolint v2.15.1 (Dockerfile). A imagem upstream analisada foi publicada em 26/10/2026.

### Vulnerabilidades

| | `latest-ubuntu-26.04` | Esta imagem |
|---|---|---|
| CVEs únicos (Trivy) | 4.171 (C=30, H=584, M=2.298, L=1.258) | 605 (C=1, H=150, M=192, L=254) |
| ...sem `linux-libc-dev` (headers do kernel) | 668 | 605 (o pacote não está na imagem) |
| Com correção já disponível | 3.510 | 11, todos Python |
| Pacotes do SO com correção disponível | 3.484 | 0 |
| CRITICAL | 30, todos em `linux-libc-dev` (corrigidos em versão mais nova) | 1: `libxml2` CVE-2026-6653, sem correção no Debian |
| Segredos (Trivy) | 0 | 0 |

- **Upstream**: quase todos os CVEs (3.503) estão no `linux-libc-dev`, que entra com as ferramentas de compilação.
  Os CVEs com correção disponível mostram que a imagem não recebe `apt-get upgrade` e está desatualizada.
- **Esta imagem**: nenhum CVE de pacote do SO tem correção pendente. O que sobra é marcado pelo Debian como
  `affected` ou `fix_deferred`, sem pacote corrigido. Os mais frequentes são `krb5` e `libxml2`, dependências do
  `libpq5`, do GDAL e do uWSGI.
- **Python** (iguais nas duas imagens): `msgpack`, `setuptools` 70.3.0 e `urllib3` 2.7.0 estão embutidos no pip
  (`pip/_vendor`) e só afetam o próprio pip. O GDAL tem 3 CVEs pelo PyPI, corrigidos no 3.13.
- **GDAL, Arrow e Oracle compilados do fonte** (`/opt/geosgb/share/sbom`): o Trivy não os avalia (são
  `pkg:generic`, e ele não cruza CPE). O Grype acha 7 CVEs no GDAL 3.12.4 (3 HIGH), os mesmos do pacote do GDAL
  no upstream, e 3 no RapidJSON embutido na Arrow (o Debian marca como won't fix). O Oracle Instant Client não tem CVEs.

### Boas práticas

| Item | `latest-ubuntu-26.04` | Esta imagem |
|---|---|---|
| Dockle | 2 FATAL, 1 WARN, 3 INFO | 1 FATAL (falso positivo), 1 WARN, 3 INFO |
| Hadolint (Dockerfile) | 22 avisos (8 regras) | 4 avisos |
| Multi-stage, sem compiladores no runtime | não | sim |
| `apt-get update` e `install` na mesma camada, listas removidas | não (camadas separadas, listas ficam nas intermediárias) | sim |
| Cache do pip | 29 MB em `/root/.cache` | `--no-cache-dir` |
| Camadas | 16 | 12 |
| Arquiteturas | amd64 | amd64 e arm64 |
| Labels OCI | 4 (herdados do Ubuntu) | 12 |
| SBOM de componentes fora do apt | não | sim (`/opt/geosgb/share/sbom`) |
| Usuário | root | root na base (o `USER` fica para a imagem final). Veja [Sem root, somente leitura](#execução-sem-root-e-com-filesystem-somente-leitura) |
| UID arbitrário | sem suporte | nss_wrapper no entrypoint |
| Filesystem somente leitura | não testado | testado (`--read-only --tmpfs /tmp`) |
| `HEALTHCHECK` | não | não |
| setuid/setgid | 14 | 0 (bits removidos) |

Observações:

- **Dockle DKL-DI-0005** ("Clear apt-get caches") é falso positivo aqui. As camadas apontadas, a do `python:slim`
  (`apt-get dist-clean`) e a nossa (`rm -rf /var/lib/apt/lists/*` com `RUN --mount`), limpam as listas, e
  `/var/lib/apt/lists` está vazio na imagem.
- **Usuário root e `HEALTHCHECK`**: numa imagem base, as duas coisas cabem à imagem do GeoNode ou ao compose.
  A base não define `USER`, porque o Dockerfile do GeoNode ainda roda `apt-get` depois do `FROM`.
- **Hadolint, nossos avisos**: DL3008 (versões do apt sem pin; prática comum no Debian, para receber as correções de
  segurança), DL3013 (`certifi` sem pin) e SC3011 (here-string no builder, que roda em bash; falso positivo).

### Melhorias possíveis

1. `apt-get -y upgrade` no estágio final, para pegar as correções do Debian entre uma publicação e outra da imagem do GDAL.
2. Fixar o `certifi` (DL3013) e a imagem do GDAL por digest (`@sha256:...`), para builds reproduzíveis.
3. Atualizar o GDAL para o 3.13 quando ele sair no `ndscprm/gdal`, por causa dos CVEs HIGH.

## Execução sem root e com filesystem somente leitura

Objetivo: as imagens do GeoNode rodam com um UID não root e com o filesystem raiz somente leitura. O código em
`/usr/src/geonode` e o venv continuam imutáveis, pertencentes ao root. Só os pontos de escrita são graváveis, e
eles vêm de volumes ou tmpfs. Por isso a base **não** libera escrita em `/usr/src/geonode`.

### O que a base já garante

Testado com
`podman run --read-only --tmpfs /tmp --user 12345:0 --security-opt no-new-privileges --cap-drop ALL`:

- **nss_wrapper**: cria o usuário virtual `sgb` para o UID sem entrada no `/etc/passwd` (`USER_NAME` muda o nome),
  com `HOME=/tmp`. Os arquivos virtuais ficam em `$TMPDIR` (`/tmp`). No podman, para reproduzir o comportamento do
  Docker e do Kubernetes, use `--passwd=false`, senão o podman cria a entrada no `/etc/passwd` por conta própria.
- **Python e GDAL**: imports (`osgeo`, `psycopg2`, `numpy`) e `ogr2ogr` gravando em `/tmp` funcionam. Os `.pyc` do
  venv já vêm compilados na imagem, então não há escrita em `__pycache__`.
- **Sem setuid/setgid**: os bits são removidos no build. Sem root, esses binários só serviriam para escalar privilégio.
- **Sem `USER` na base**: as imagens derivadas ainda precisam de root no build (o `apt-get` do Dockerfile do GeoNode).
  O `USER` numérico vai no fim da imagem final.

### O que a imagem do GeoNode e o compose precisam fazer

O GeoNode master (commit `c125d8f`) ainda assume root e escrita no filesystem raiz:

| Ponto | Problema sem root / somente leitura | Ajuste sugerido |
|---|---|---|
| `entrypoint.sh`: `service cron restart` | exige root e aborta o entrypoint (`set -e`) | remover a linha. O GeoNode não instala crontab: as tarefas periódicas ficam no Celery beat |
| `entrypoint.sh`: `source $HOME/.bashrc` | `HOME=/tmp` não tem `.bashrc`, e o `source` aborta o entrypoint | `[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"` |
| `entrypoint.sh`: `> /usr/src/geonode/invoke.log` | código somente leitura | `INVOKE_LOG_STDOUT=true` (log no stdout) |
| `tasks.py`: `$HOME/.override_env` e `/tmp/*.json` | precisam de escrita | atendidos pelo tmpfs em `/tmp` (`HOME=/tmp`) |
| `uwsgi.ini`: `logto = /var/log/geonode.log` | `/var/log` somente leitura | remover o `logto` (log no stdout) |
| `celery-cmd`: `/var/log/celery.log`, `/var/log/celery_beat.log` | `/var/log` somente leitura | `CELERY__LOG_FILE` e `CELERY__BEAT_LOG` em `/dev/stdout`, ou num volume |
| `celery-cmd`: `/tmp/celerybeat.pid` | precisa de escrita | atendido pelo tmpfs em `/tmp` |
| statics, uploads, `celerybeat-schedule`, `geonode_init.lock` | escrita em `/mnt/volumes/statics` | volume gravável pelo UID (ou pelo grupo 0) |
| `Dockerfile` | — | `USER 1000:0` (numérico, para o `runAsNonRoot` do Kubernetes) no fim |

Exemplo de compose:

```yaml
    user: "1000:0"
    read_only: true
    tmpfs:
      - /tmp
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    volumes:
      - statics:/mnt/volumes/statics
```

O `tmpfs` em `/tmp` também cobre os temporários do GDAL (`CPL_TMPDIR`) e do Django. Uploads grandes vão para esse
tmpfs (`FILE_UPLOAD_TEMP_DIR`), então ele precisa de tamanho compatível com o maior upload. Se a memória for um
limite, aponte `FILE_UPLOAD_TEMP_DIR` para um volume.

## Compatibilidade do cliente PostgreSQL

A imagem traz o cliente e o `libpq5` do PostgreSQL 17. Eles funcionam com servidores mais antigos, segundo a
documentação do PostgreSQL:

| Componente                          | Servidores suportados | Observação                                                      |
|-------------------------------------|-----------------------|-----------------------------------------------------------------|
| `libpq` (psycopg2, Django, GeoNode) | 7.4 em diante         | mesmo protocolo de conexão (v3)                                 |
| `psql`                              | 9.2 até 17            | com servidores mais novos que o cliente, comandos `\d…` podem falhar |
| `pg_dump`                           | 9.2 até 17            | um `pg_dump` mais antigo que o servidor se recusa a rodar       |

**Restauração de dumps**: um dump gerado pelo `pg_dump` 17 só tem garantia de carregar num servidor da mesma versão
do servidor de origem, ou mais novo. Restaurar no mesmo servidor de onde veio o dump (por exemplo, de 15 para 15) costuma funcionar.
Um dump de um servidor 17 restaurado num 15 pode falhar por causa de sintaxe nova. Isso vale para os comandos de
backup e restauração do GeoNode.

Referências: [psql](https://www.postgresql.org/docs/17/app-psql.html),
[pg_dump](https://www.postgresql.org/docs/17/app-pgdump.html).

## Atenção: versão do GDAL no GeoNode

O `pyproject.toml` do GeoNode fixa `GDAL==3.12.2`, e a imagem traz os bindings do GDAL **3.12.4**. Com isso,
`pip install -e .` tenta compilar o GDAL 3.12.2 e falha, porque a imagem final não tem compilador nem headers.

**Decisão**: no GeoNode derivado, o `pyproject.toml` passa a fixar a versão do GDAL desta imagem:

```toml
    "GDAL==3.12.4",
```

Com isso, o pip considera os bindings da imagem já instalados (`Requirement already satisfied: GDAL==3.12.4`) e
não compila nada. O pin precisa acompanhar a versão do GDAL de `GDAL_TAG`. Ao trocar a tag, o `pyproject.toml`
também precisa mudar.

Para testes rápidos, sem editar o `pyproject.toml`, dá para relaxar o pin no Dockerfile derivado, antes do
`pip install`:

```dockerfile
RUN sed -i 's/"GDAL==[^"]*"/"GDAL"/' pyproject.toml
```

## numpy e pyarrow

O GeoNode fixa `numpy==1.26.*`, e o venv da imagem do GDAL vem com numpy 2.5.4 e pyarrow 26. O `pyarrow` 26 exige
numpy 2.0 ou mais novo e falha no `import` com o numpy 1.x. O `pip check` não percebe, porque ele não declara o
numpy como dependência.

**Decisão**: a base já instala o numpy da versão que o GeoNode fixa (`NUMPY_VERSION`) e remove o `pyarrow`, que não é usado
(não há referência a ele no código do GeoNode). O Arrow fica só por conta do GDAL: os drivers Arrow e Parquet usam a
Arrow C++ de `/opt/geosgb/lib`, não o pyarrow. O build da base confere isso.

Testado com o GeoNode master (commit `c125d8f`, 10/11/2026) e `"GDAL==3.12.4"` no `pyproject.toml`:

| Componente                    | Com numpy 1.26.4 | Teste                                                                    |
|-------------------------------|------------------|--------------------------------------------------------------------------|
| bindings do GDAL (`osgeo`)    | funciona         | `gdal_array` (`ReadAsArray`/`WriteArray`), `ogr` `GetArrowStreamAsNumPy` |
| drivers Arrow/Parquet do GDAL | funciona         | drivers `Arrow` e `Parquet` disponíveis                                  |
| `pip install` do GeoNode      | funciona         | `Requirement already satisfied` para GDAL e numpy, nada compilado        |
| GeoNode                       | funciona         | `pip check` e `manage.py check` sem erros                                |

**Tamanho**: remover o pyarrow e o numpy 2 numa camada nova não reduz a imagem. Os arquivos continuam nas camadas da
imagem do GDAL, e o numpy 1.26 soma uma camada por cima: a base foi de 777 MB para 837 MB. A imagem final do GeoNode
fica igual (1,52 GB), porque o downgrade do numpy saiu dela e veio para a base. A economia de verdade exige uma variante
da imagem do GDAL sem pyarrow, com numpy 1.x.
