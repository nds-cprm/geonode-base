# geonode-base
Imagem base mais segura e enxuta de geonode 5.x para instâncias do SGB

Imagem base do GeoNode derivada de [`ndscprm/gdal`](https://hub.docker.com/r/ndscprm/gdal)
(GDAL compilado com Oracle, Arrow/Parquet e bindings Python), no lugar da imagem
`geonode/geonode-base` baseada em Ubuntu.

É um port do [`docker/base/ubuntu/26/Dockerfile`](https://github.com/GeoNode/geonode/blob/master/docker/base/ubuntu/26/Dockerfile)
do GeoNode. Ela substitui `geonode/geonode-base` no `FROM` do `Dockerfile` do GeoNode ou de um geonode-project.

## Build

```sh
docker build -t geonode-base:local .

# sobre um build fixo da imagem base (tag datada, opcionalmente com o digest), como no CI:
docker build \
    --build-arg GDAL_IMAGE_DEVEL=docker.io/ndscprm/gdal:3.12.4-py3.12-devel-20261026 \
    --build-arg GDAL_IMAGE_PY=docker.io/ndscprm/gdal:3.12.4-py3.12-20261026 \
    -t geonode-base:local .
```

O build precisa do BuildKit (padrão no Docker atual), por causa do `RUN --mount`.

Argumentos:

| Argumento          | Padrão                   | Uso                                                              |
|--------------------|--------------------------|------------------------------------------------------------------|
| `GDAL_IMAGE_DEVEL` | `docker.io/ndscprm/gdal:3.12.4-py3.12-devel` | imagem do estágio `build`, pelo nome completo |
| `GDAL_IMAGE_PY`    | `docker.io/ndscprm/gdal:3.12.4-py3.12` | imagem do estágio `release`, pelo nome completo. Vai para o label `org.opencontainers.image.base.name` |
| `GEONODE_VERSION`  | `5.2.0`                  | versão do GeoNode para a qual a base é feita. É a tag da imagem e o label `org.opencontainers.image.version` |
| `UWSGI_VERSION`    | `2.0.30`                 | uWSGI, igual ao pin do GeoNode                                   |
| `PSYCOPG2_VERSION` | `2.9.13`                 | psycopg2, igual ao pin do GeoNode                                |
| `INVOKE_VERSION`   | `2.2.0`                  | invoke                                                           |
| `SHERLOCK_VERSION` | `0.4.1`                  | sherlock                                                         |
| `NUMPY_VERSION`    | `1.26.*`                 | numpy, igual ao pin do GeoNode                                   |

## CI e publicação

A imagem é publicada como [`ndscprm/geonode-base`](https://hub.docker.com/r/ndscprm/geonode-base), com o mesmo
fluxo da [mapproxy-oci](https://github.com/nds-cprm/mapproxy-oci). O workflow
[`publish-image.yml`](.github/workflows/publish-image.yml) chama o
[workflow reutilizável do gdal-oci](https://github.com/nds-cprm/gdal-oci#workflow-reutilizável). Ele:

1. constrói as imagens `amd64` e `arm64` em runners nativos e publica cada uma só por digest, com attestations de
   SBOM e de provenance;
2. roda o teste de fumaça [`.github/scripts/smoke-test.sh`](.github/scripts/smoke-test.sh) em cada arquitetura;
3. analisa CVEs com o Trivy e o Grype e envia os relatórios para a aba *Security*;
4. só então cria as tags.

Uma falha no teste ou na análise impede a criação das tags. As vulnerabilidades só são reportadas, não bloqueiam.

| Tag | Exemplo | Conteúdo |
|---|---|---|
| `<versão do GeoNode>` | `5.2.0` | **Móvel**: republicada a cada rebuild da imagem base, com as correções de segurança. Recomendada no `FROM` |
| `<versão>-<AAAAMMDD>` | `5.2.0-20261116` | Um build específico (data UTC; `.2`, `.3`... nos builds seguintes do mesmo dia). Nunca é sobrescrita: use-a, de preferência com o digest, para fixar a imagem ou voltar a uma anterior |

Não há tag `latest`. A base exata de cada build fica no label `org.opencontainers.image.base.name`.

**Disparo:**

- **Manual**, pela aba *Actions*, com as entradas opcionais `image_devel` e `image_py`: nomes completos das imagens
  `ndscprm/gdal`. Vazias, valem os padrões do Dockerfile. O job `check` recusa qualquer imagem fora de
  `docker.io/ndscprm/gdal:`. A entrada `image_nopy` é aceita e ignorada: o gdal-oci manda as mesmas três entradas
  para todas as imagens derivadas.
- **Pelo CI do gdal-oci**, depois que ele publica a `ndscprm/gdal` (toda semana), com as tags datadas e o digest
  das imagens que acabou de publicar. Não há build agendado próprio: uma base nova invalida todas as camadas, e o
  apt e o pip pegam os pacotes atuais.

**Configuração necessária:**

- **Neste repositório:** os secrets `DOCKERHUB_USERNAME` e `DOCKERHUB_TOKEN`, com permissão de push em
  `ndscprm/geonode-base`. O repositório precisa existir no Docker Hub.
- **No gdal-oci:**
  - acrescentar `geonode-base` na matriz `repository` do job `dispatch` do `publish-image.yml`;
  - dar à GitHub App (`DERIVED_IMAGES_APP_CLIENT_ID`) acesso a este repositório.

  Sem isso, o build semanal da base não dispara este workflow, e a imagem só é atualizada manualmente.

**Versão.** A tag vem da linha `ARG GEONODE_VERSION=X.Y.Z` do [Dockerfile](Dockerfile), que o workflow lê com
`sed`. Mantenha esse formato. Ao passar para outra versão do GeoNode:

1. atualize `GEONODE_VERSION`;
2. alinhe `UWSGI_VERSION`, `PSYCOPG2_VERSION` e `NUMPY_VERSION` ao `pyproject.toml` daquela versão;
3. confira o pin do GDAL (veja [Atenção: versão do GDAL no GeoNode](#atenção-versão-do-gdal-no-geonode));
4. faça o commit e dispare o workflow.

**Teste de fumaça.** Roda o container como as imagens derivadas rodam em produção:
`--user 12345:0 --read-only --tmpfs /tmp --cap-drop ALL`. Ele confere:

- a configuração da imagem: sem `USER`, `WORKDIR` e `ENTRYPOINT`;
- o nss_wrapper (usuário `sgb`, `HOME=/tmp`);
- `/usr/src/venv`, `invoke` e `uwsgi`;
- `pip check`;
- os bindings do GDAL iguais à biblioteca, com numpy 1.x, sem pyarrow, e com os drivers usados pelo GeoNode;
- o psycopg2 ligado à `libpq` do sistema, e o `psql` com a mesma versão major da `libpq`;
- a `libmagic`;
- o `ogr2ogr` gravando em `/tmp`, e nada fora dele gravável;
- nenhum arquivo setuid/setgid e nenhum compilador.

Para rodar localmente: `sh .github/scripts/smoke-test.sh <imagem>` (com Podman:
`DOCKER=podman sh .github/scripts/smoke-test.sh <imagem>`).

## Multi-stage

| Estágio   | Imagem                         | Função                                                                 |
|-----------|--------------------------------|------------------------------------------------------------------------|
| `build`   | `GDAL_IMAGE_DEVEL`             | compila as wheels (uWSGI, psycopg2 e as demais) e lista as bibliotecas Debian que os binários usam (`ldd` + `dpkg -S`) |
| `release` | `GDAL_IMAGE_PY`                | instala só essas bibliotecas e as wheels, sem compiladores nem headers |

As duas imagens têm o mesmo Debian, o mesmo Python e o mesmo `/opt/geosgb`, por isso as wheels compiladas no
estágio `build` funcionam na imagem final.

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
  junto com o psycopg2, compilado no estágio `build`.
- **Compiladores e headers** (`build-essential`, `gcc`, `libpq-dev`, `libxml2-dev` etc.): ficam só no estágio `build`.
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
| Labels OCI | 4 (herdados do Ubuntu) | 12 (todas as chaves definidas no Dockerfile; `created` e `revision` vêm do CI) |
| SBOM de componentes fora do apt | não | sim (`/opt/geosgb/share/sbom`) |
| Usuário | root | root na base (o `USER` fica para a imagem final). Veja [Sem root, somente leitura](#execução-sem-root-e-com-filesystem-somente-leitura) |
| UID arbitrário | sem suporte | nss_wrapper no entrypoint |
| Filesystem somente leitura | não testado | testado (`--read-only`, com `/tmp` em tmpfs ou volume) |
| `HEALTHCHECK` | não | não |
| setuid/setgid | 14 | 0 (bits removidos) |

Observações:

- **Dockle DKL-DI-0005** ("Clear apt-get caches") é falso positivo aqui. As camadas apontadas, a do `python:slim`
  (`apt-get dist-clean`) e a nossa (`rm -rf /var/lib/apt/lists/*` com `RUN --mount`), limpam as listas, e
  `/var/lib/apt/lists` está vazio na imagem.
- **Usuário root e `HEALTHCHECK`**: numa imagem base, as duas coisas cabem à imagem do GeoNode ou ao compose.
  A base não define `USER`, porque o Dockerfile do GeoNode ainda roda `apt-get` depois do `FROM`.
- **Hadolint, nossos avisos**: DL3008 (versões do apt sem pin; prática comum no Debian, para receber as correções de
  segurança), DL3013 (`certifi` sem pin) e SC3011 (here-string no estágio `build`, que roda em bash; falso positivo).

### Melhorias possíveis

1. `apt-get -y upgrade` no estágio final, para pegar as correções do Debian entre uma publicação e outra da imagem do GDAL.
2. Fixar o `certifi` (DL3013) e a imagem do GDAL por digest (`@sha256:...`), para builds reproduzíveis.
3. Atualizar o GDAL para o 3.13 quando ele sair no `ndscprm/gdal`, por causa dos CVEs HIGH.

## Execução sem root e com filesystem somente leitura

Objetivo: as imagens do GeoNode rodam com um UID não root e com o filesystem raiz somente leitura. O código em
`/usr/src/geonode` e o venv continuam imutáveis, pertencentes ao root. Só os pontos de escrita são graváveis, e
eles vêm de volumes (ou tmpfs). Por isso a base **não** libera escrita em `/usr/src/geonode`.

### O que a base já garante

Testado com
`podman run --read-only --tmpfs /tmp --user 12345:0 --security-opt no-new-privileges --cap-drop ALL`, e também com
um volume nomeado novo em `/tmp` (`-v tmp:/tmp`) no lugar do tmpfs, como no compose do GeoNode:

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
| `tasks.py`: `$HOME/.override_env` e `/tmp/*.json` | precisam de escrita | atendidos pelo volume `tmp` em `/tmp` (`HOME=/tmp`) |
| `uwsgi.ini`: `logto = /var/log/geonode.log` | `/var/log` somente leitura | remover o `logto` (log no stdout) |
| `celery-cmd`: `/var/log/celery.log`, `/var/log/celery_beat.log` | `/var/log` somente leitura | `CELERY__LOG_FILE` e `CELERY__BEAT_LOG` em `/dev/stdout`, ou num volume |
| `celery-cmd`: `/tmp/celerybeat.pid` | precisa de escrita | atendido pelo volume `tmp` em `/tmp` |
| statics, uploads, `celerybeat-schedule`, `geonode_init.lock` | escrita em `/mnt/volumes/statics` | volume gravável pelo UID (ou pelo grupo 0) |
| `Dockerfile` | — | `USER 1000:0` (numérico, para o `runAsNonRoot` do Kubernetes) no fim |

Exemplo de compose, sobre o `x-common-django` do GeoNode, que já monta os volumes (inclusive `tmp:/tmp`):

```yaml
x-common-django:
  &default-common-django
  user: "1000:0"
  read_only: true
  security_opt:
    - no-new-privileges:true
  cap_drop:
    - ALL
  volumes:
    - statics:/mnt/volumes/statics
    - geoserver-data-dir:/geoserver_data/data
    - backup-restore:/backup_restore
    - data:/data
    - tmp:/tmp
```

O `/tmp` gravável já vem da instalação padrão: o compose do GeoNode monta o volume nomeado `tmp` em `/tmp` no
django, no celery e no geoserver. Não é preciso tmpfs. Esse volume compartilhado tem algumas consequências:

- **Permissão**: na primeira montagem, o Docker e o podman copiam para o volume o `/tmp` da imagem, com modo `1777`.
  Qualquer UID grava nele. Um volume criado antes, por outra imagem, mantém as permissões que já tinha.
- **UID**: o GeoNode não depende de os serviços terem o mesmo UID. Os arquivos que o django passa para o celery
  (uploads do importer) não ficam no `/tmp`: vão para diretórios criados em `MEDIA_ROOT`, no volume `statics`, e o
  GeoNode aplica `FILE_UPLOAD_DIRECTORY_PERMISSIONS` e `FILE_UPLOAD_PERMISSIONS` (`0o777`, em `settings.py`). No
  `/tmp`, cada serviço só lê o que ele mesmo gravou. Com UIDs diferentes, o sticky bit apenas impede que um apague
  os arquivos do outro.
- **`HOME=/tmp` compartilhado**: com o nss_wrapper, o django e o celery passam a ter o mesmo `HOME`, e o
  `$HOME/.override_env` que o `tasks.py` grava no entrypoint vira um arquivo só. Como root, cada container tinha o seu
  em `/root`. O conteúdo vem do mesmo `.env`, então isso só muda algo se os serviços tiverem variáveis diferentes.
  Nesse caso, defina `HOME` para um diretório próprio em cada serviço, dentro de um volume.
- **nss_wrapper**: os arquivos virtuais ficam num diretório exclusivo, criado com `mktemp -d`, então os containers
  não colidem nem leem arquivos plantados por outro.
- **Tamanho**: uploads (`FILE_UPLOAD_TEMP_DIR` não é definido no GeoNode, então o Django usa o `/tmp`), os
  `mkdtemp()` do importer (`geonode/storage/data_retriever.py`) e os temporários do GDAL ficam no disco do volume,
  e não na memória.

Sem esse volume, use um `emptyDir` (ou `--tmpfs /tmp`, como no teste acima). Ele precisa ter espaço para o maior
upload.

### OpenShift

Na execução padrão (SCC `restricted-v2`), o OpenShift ignora o `USER` da imagem e escolhe o UID:

- **UID**: o menor valor da faixa do namespace (anotação `openshift.io/sa.scc.uid-range`), quando o pod não define
  `runAsUser`. Os pods do mesmo namespace costumam receber o mesmo UID, mas isso não é garantido: muda entre
  namespaces, entre clusters e quando um pod é admitido por outra SCC. Não conte com ele.
- **Grupos**: o grupo primário é sempre o `0`, e o `fsGroup` (faixa `openshift.io/sa.scc.supplemental-groups`) entra
  como grupo suplementar. A permissão deve vir do grupo, não do dono.
- **nss_wrapper**: o UID não existe no `/etc/passwd`, e o entrypoint cria o usuário virtual `sgb` com `HOME=/tmp`.

O que isso muda em relação ao compose:

| Ponto | No OpenShift |
|---|---|
| `/tmp` | `emptyDir` por pod. Volumes `emptyDir` não são compartilhados entre pods, e o GeoNode não precisa disso (veja acima). Também resolve o `HOME=/tmp` compartilhado |
| `statics` (`MEDIA_ROOT`, `STATIC_ROOT`) | PVC `ReadWriteMany` montado no django e no celery. Em volumes com suporte a `fsGroup`, o kubelet ajusta o grupo e libera escrita para ele. Em NFS, o kubelet não faz esse ajuste: veja [Volumes em NFS](#volumes-em-nfs). Sem sticky bit: o celery apaga os diretórios temporários que o django cria |
| Arquivos fora do upload (`geonode_init.lock`, `celerybeat-schedule`, `collectstatic`) | criados com o umask padrão (`022`), sem escrita para o grupo. Hoje só um serviço escreve cada um, então funciona. Se outro pod precisar regravá-los com outro UID, use `umask 0002` no entrypoint |
| `USER 1000:0` no `Dockerfile` | continua útil no Docker e no compose. No OpenShift, ele é substituído pelo UID da faixa |

Teste com dois UIDs diferentes, ambos no grupo `0`, num volume com modo `2775` e grupo `0`:

- **Diretório do importer** (criado com `mkdtemp` e `chmod 0o777`, como faz o GeoNode): o outro UID lê o arquivo e
  apaga o diretório.
- **Arquivo comum** (umask `022`, modo `644`): o outro UID não consegue alterá-lo, mas consegue apagá-lo, porque o
  diretório pai é gravável pelo grupo.
- **Com o pai em modo `1777`** (sticky bit, como o `/tmp`): o outro UID lê o arquivo, mas não apaga o diretório.

### Volumes em NFS

Com o UID arbitrário do OpenShift, o NFS é o ponto mais sensível, por três motivos:

- **O kubelet não ajusta permissões em NFS.** O `fsGroup` não tem efeito: o dono e o modo dos diretórios são os que
  estão no servidor.
- **O grupo `0` não funciona com `root_squash`,** que é o padrão do `exports`. O `nfsd` do Linux troca o UID `0` e
  também o GID `0` (primário e suplementares) pelo `anongid`. A permissão dada ao grupo `0` no servidor não vale
  para os pods.
- **Os UIDs podem mudar** entre namespaces, clusters ou reinstalações, e o NFS guarda o UID numérico de quem criou
  cada arquivo. Um arquivo criado com o UID antigo pode deixar de ser gravável.

Por isso, cada export do GeoNode mapeia todos os clientes para uma identidade fixa, com `all_squash`. O servidor
passa a tratar qualquer UID do pod como o mesmo dono, e os problemas de UID diferente, umask e arquivos criados por
outro pod deixam de existir.

#### Servidor

Uma identidade dedicada, sem login e sem uso em outros exports (os valores são exemplos):

```sh
groupadd -g 5000 geonode
useradd -u 5000 -g 5000 -M -s /usr/sbin/nologin geonode

install -d -o 5000 -g 5000 -m 2770 /export/geonode
for v in statics geoserver-data-dir backup-restore data; do
    install -d -o 5000 -g 5000 -m 2770 "/export/geonode/$v"
done
```

`/etc/exports`, liberado só para a rede dos nós do cluster (ou dos hosts do compose):

```text
/export/geonode  10.0.0.0/24(rw,sync,no_subtree_check,all_squash,anonuid=5000,anongid=5000)
```

```sh
exportfs -ra
```

| Opção | Por quê |
|---|---|
| `all_squash,anonuid=5000,anongid=5000` | todo acesso, qualquer que seja o UID do pod, vira `5000:5000`. Inclui o `chmod` que o GeoNode faz nos uploads, porque o servidor vê o mesmo dono |
| `sync` | a resposta só volta depois da gravação em disco. Evita perder uploads e o `geonode_init.lock` numa queda do servidor |
| `no_subtree_check` | padrão recomendado. Evita erros quando arquivos são renomeados com o export em uso |
| sem `no_root_squash` | com `all_squash`, root também vira `5000`. Um container comprometido não ganha root no servidor |
| `2770` | só o dono e o grupo acessam. O setgid mantém o grupo nos diretórios novos |

Não exporte esse diretório para outros usos: todo cliente dele tem acesso total aos dados do GeoNode.

#### OpenShift

PV e PVC estáticos, um por volume (o exemplo mostra o `statics`):

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: geonode-statics
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  mountOptions:
    - nfsvers=4.1
    - hard
  nfs:
    server: nfs.example.internal
    path: /export/geonode/statics
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: geonode-statics
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  volumeName: geonode-statics
  resources:
    requests:
      storage: 100Gi
```

- **`ReadWriteMany`**: o django, o celery e o geoserver montam o mesmo volume.
- **`Retain`**: apagar o PVC não apaga os dados.
- **`hard`**: numa falha do servidor, a gravação espera em vez de devolver erro de I/O e corromper o arquivo.
- **NFS 4.1**: o lock fica no próprio protocolo, sem `rpc.statd`.

Nos pods, nada muda na `securityContext`: a SCC `restricted-v2` continua escolhendo o UID, e o `all_squash` resolve
as permissões no servidor. O `/tmp` continua num `emptyDir`, fora do NFS.

#### Compose

O mesmo export, montado pelo driver `local` do Docker ou do podman:

```yaml
volumes:
  statics:
    driver: local
    driver_opts:
      type: nfs
      o: "addr=nfs.example.internal,nfsvers=4.1,hard,rw"
      device: ":/export/geonode/statics"
```

Repita para `geoserver-data-dir`, `backup-restore` e `data`. O volume `tmp` continua local.

#### Alternativa sem `all_squash`

Se o servidor precisar preservar o UID de cada cliente (auditoria, cotas):

1. Use `root_squash`, que é o padrão, e um GID dedicado diferente de `0`. Os diretórios ficam com modo `2770` e esse
   grupo.
2. Adicione o GID aos pods com `securityContext.supplementalGroups: [5000]`. A `restricted-v2` aceita qualquer valor
   em `supplementalGroups`. No compose, use `group_add`.
3. Coloque `umask 0002` no entrypoint do GeoNode. Senão, diretórios e arquivos criados fora dos uploads (o GeoNode
   só aplica `0o777` nos uploads) saem sem escrita para o grupo, e outro UID não consegue gravar neles.

Essa alternativa tem mais pontos de falha que o `all_squash`. Use-a só se precisar.

> As duas configurações seguem o comportamento documentado do `nfsd` do Linux ([`exports(5)`](https://man7.org/linux/man-pages/man5/exports.5.html))
> e do OpenShift. Elas não foram testadas aqui, porque o ambiente local não tem servidor NFS.

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
não compila nada. O pin precisa acompanhar a versão do GDAL de `GDAL_IMAGE_PY`. Ao trocar a imagem, o `pyproject.toml`
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
