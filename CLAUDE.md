# iaragon — contexto para sessões de trabalho

Daemon de sincronização **bidirecional** do Google Drive para Linux, replicando o
modo "Mirror" do Google Drive for Desktop: sync contínuo nos dois sentidos, cópia
local completa (resiliente a perder acesso ao Drive), navegável pelo gerenciador
de arquivos.

## Regras de trabalho (permanentes)

- Conversas em **português**; código/identificadores em **inglês idiomático**.
- **TDD estrito** (red → green → refactor): todo código de produção nasce de um
  teste falhando. Falha de compilação por tipo/função inexistente conta como red.
  Todo commit tem a suíte verde.
- **DDD**: camadas `domain/` (pura: zero I/O, zero OTP), `application/`
  (orquestração dos casos de uso), `infrastructure/` (adaptadores para FS, Drive,
  persistência, supervisão). Regra de dependência: domain não importa nada das
  outras camadas; application não importa infrastructure concreta (só recebe
  `Subject`s tipados). Gleam não tem interfaces/typeclasses — "ports" são
  contratos de mensagem e records de funções injetados na inicialização; a regra
  é mantida por disciplina de imports (verificar em review).
- **Verb-first em toda fronteira de chamada**: tipos do domínio são substantivos
  (o quê — `SyncDecision`, `RemoteFile`); operações e mensagens são verbos de
  intenção (o que se faz — `reconcile`, `PutKnown`, `EnqueueUpload`,
  construtores `UploadLocal`, `ForgetKnown`). Exceção única e documentada:
  `pub fn supervised()` nos módulos de ator, nome canônico do padrão
  gleam_otp 1.2 (`supervision.ChildSpecification`).
- **Rolling release**: sem tags de versão, sem V1/V2, sem changelog.
- Planejar antes de codar; explicitar suposições e trade-offs; separar fato de
  especulação; **não inventar APIs/endpoints** — verificar na doc oficial e dizer
  quando não houver certeza. Avisar de erros/riscos ANTES de propagarem.

## Stack (decidida — não propor alternativa sem pedido explícito)

- **Gleam** (compilador 1.17.0), alvo **Erlang/BEAM**. NÃO usar alvo JS/Deno; não
  propor Rust/Node.
- **OTP** (gleam_otp 1.2) para atores e árvore de supervisão. Escolha deliberada:
  um sync daemon é um conjunto de processos de vida longa que falham de forma
  independente; a supervisão dá isolamento de falha (poller cai num erro
  transitório de API → reinicia só ele, sem derrubar o daemon).
- Deps fixadas em `gleam.toml`: gleam_stdlib 1.0.x, gleam_otp 1.2.x,
  gleam_erlang 1.3.x, gleam_json 3.1.x, gleam_httpc 5.0.x, gleam_time 1.8.x
  (preferida a birl), simplifile 2.6.x, filespy 0.7.x (inotify; exige
  inotify-tools em runtime), polly 3.1.x (watcher por polling, fallback; tem
  `supervised()` pronto).
- Testes: gleeunit. Rodar com `gleam test`; build com `gleam build`.
- **API gleam_otp 1.2** (pós-1.0, mudou muito — não usar API antiga):
  `actor.new(state) |> actor.on_message(fn) |> actor.named(name) |> actor.start`;
  handler devolve `actor.continue(state)` / `actor.stop()`. Supervisão:
  `supervision.worker(fn() -> actor.StartResult(data))`,
  `static_supervisor.new(supervisor.OneForOne) |> add(child) |> start`,
  aninhamento via `supervised()`. Nomes: `process.new_name(prefix:)` +
  `process.named_subject(name)` (gleam_erlang 1.3).

## Arquitetura

Árvore de supervisão (OneForOne) com cinco atores:

| Ator | Camada | Papel |
|---|---|---|
| `state_owner` | application | Dono do "último estado conhecido" (fileId ↔ path + metadados da última sync) e do startPageToken |
| `local_watcher` | infrastructure/fs | Eventos de FS (inotify via filespy; polly como fallback) |
| `remote_poller` | infrastructure/drive | Changes API do Drive com startPageToken persistido |
| `reconciler` | application | Chama a reconciliação pura e despacha decisões |
| `transfer_pool` | infrastructure/drive | Pool de workers de upload/download |

### Núcleo correção-crítico (domain/, 100% puro)

- União `SyncDecision`: `UploadLocal`, `DownloadRemote`, `DeleteLocal`,
  `DeleteRemote`, `Conflict(kind)`, `ForgetKnown` (ambos os lados sumiram —
  limpar índice, senão a tabela de estado vaza), `Noop`.
- `reconcile(local, remote, last) -> SyncDecision` — **three-way diff puro**
  sobre `Option`s. **Pattern matching exaustivo obrigatório, sem `_` catch-all
  no nível de presença**: caso não tratado deve ser erro de compilação — é a
  defesa contra perda de dados silenciosa.
- Sem o "último estado conhecido" não dá para distinguir mudou-local,
  mudou-remoto e conflito — por isso o estado persistido guarda modifiedTime,
  md5Checksum, headRevisionId e tamanho da última sync.
- Detecção de mudança: local = size+mtime vs last (hash como desempate);
  remoto = md5Checksum para blobs, modifiedTime para nativos do Google.

## Decisões de produto

- **Arquivos nativos do Google (Docs/Sheets/Slides): download-only**, política
  configurável `NativeDocPolicy = LinkFile | ExportOffice | ExportOdf`, default
  `LinkFile` (arquivo-atalho que abre no navegador). Motivo: nativos não têm
  bytes nem md5; export é lossy e limitado a 10 MB; re-importar destruiria
  formatação. Edição local de um nativo **nunca** vira `UploadLocal`.
- **Estado persistido: SQLite via sqlight** (decidido; a dep entra na sessão de
  persistência — hoje o state_owner é Dict em memória). Motivo: lookup por duas
  chaves (fileId e path), transações por lote, inspeção com `sqlite3` CLI.
  DETS descartado (limite 2 GB, sem índice secundário); Mnesia descartado
  (schema management incômodo, semântica distribuída sem uso aqui).

## Armadilhas do Drive (fatos verificados na doc oficial, 2026-07)

- **Identidade é `fileId`**, nunca path: nomes não são únicos dentro de pasta;
  parent é único desde 2020 (multi-parent acabou; atalhos o substituem).
  Mapear para POSIX é lossy — disambiguar nomes duplicados de forma determinística.
- **Changes API**: `GET /drive/v3/changes/startPageToken` (token não expira) →
  `GET /drive/v3/changes?pageToken=...`; paginar por `nextPageToken`; ao chegar
  ao fim vem `newStartPageToken` (persistir). `removed=true` (sem `file`) =
  deleção permanente/perda de acesso; **lixeira chega como mudança normal com
  `file.trashed=true`** — tratar trashed como delete remoto. Setar
  `includeRemoved`/`restrictToMyDrive` explícitos (defaults não documentados).
- **Nativos**: sem `md5Checksum`/`sha*Checksum`/`headRevisionId` (só blobs têm);
  nativos têm `modifiedTime` e `size`. Export: `files/{id}/export?mimeType=...`,
  **limite 10 MB**.
- **Download**: `files/{id}?alt=media` (aceita `Range`). **Upload resumable**
  (obrigatório p/ arquivo grande): POST inicia sessão → PUT chunks **múltiplos
  de 256 KB** → `308 Resume Incomplete`; sessão expira em 1 semana.
- **Rate limit**: modelo de quota units (leitura 5, lista 100, download 200,
  edit 50; 325k units/min/usuário). 403/429 `userRateLimitExceeded` → backoff
  exponencial truncado com jitter. Batch `POST /batch/drive/v3` (máx 100 calls,
  **não serve para media**).
- **OAuth desktop**: loopback `http://127.0.0.1:{port}` + PKCE (OOB foi
  removido). Auth: `accounts.google.com/o/oauth2/v2/auth`; token:
  `oauth2.googleapis.com/token`. client_secret de app instalado é
  não-confidencial. Escopo para mirror completo:
  `https://www.googleapis.com/auth/drive` (**restricted** — verificação/CASA só
  para app publicado de verdade). **App em modo "Testing" (external): refresh
  token expira em 7 dias** — para uso pessoal, publicar "In production" sem
  verificação (fica o warning de não verificado) ou reautenticar semanalmente.
- **gleam_httpc 5.x não faz streaming de corpo** (corpo inteiro em memória).
  Para transferir arquivo grande será preciso FFI fino sobre o `httpc` do Erlang
  (`{stream, ...}`) ou outro cliente — decidir na sessão de transferência.

## Roadmap (ordem de implementação)

1. Download-only espelhando o remoto
2. Upload-only
3. Bidirecional com detecção de conflito
4. Overlays no gerenciador de arquivos

Feito até aqui: scaffold; domínio puro (`SyncDecision` + `reconcile`) com testes;
esqueleto de supervisão com atores stub. **Próximas sessões**: OAuth (loopback +
PKCE), cliente Drive (Changes API + backoff), transferência real de bytes
(resumable upload; resolver streaming), persistência SQLite no state_owner,
watcher inotify real.

## Ambiente de dev/CI (containers Ubuntu 24.04)

- Erlang/OTP via apt (OTP 25 funciona com Gleam 1.17); `rebar3` via apt
  (necessário para compilar a dep Erlang `fs` do filespy).
- Binário do Gleam: GitHub releases; se o GitHub estiver bloqueado pelo proxy da
  sessão, extrair da imagem OCI oficial `ghcr.io/gleam-lang/gleam:vX.Y.Z-scratch`
  (binário musl estático em `/bin/gleam`, baixável com curl + Bearer token
  anônimo do ghcr.io).
