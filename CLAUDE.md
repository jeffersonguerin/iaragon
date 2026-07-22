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
  `supervised()` pronto), gleam_crypto 1.6.x (PKCE), filepath 1.1.x,
  envoy 1.2.x ($HOME), sqlight 1.2.x (NIF esqlite — exige gcc/make no build).
- FFI Erlang só quando indispensável e fino: `src/iaragon_loopback_ffi.erl`
  (gen_tcp one-shot para o redirect OAuth) e `src/iaragon_download_ffi.erl`
  (httpc `{stream, path}` para download direto a disco; TLS confia no default
  verify_peer do httpc em OTP ≥ 26 — mesma premissa do gleam_httpc).
  Armadilha aprendida: `{stream, path}` FAZ APPEND em arquivo existente — por
  isso downloads vão para `<dest>.iaragon-partial` e são renomeados no
  sucesso (atomicidade de espelho de graça). Upload resumable será o próximo
  FFI (fase upload).
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

**SYNC BIDIRECIONAL COMPLETO, com resolução de conflito e watcher local.**

Fase conflitos + watcher (sessão 6): política decidida pelo usuário —
**edit-edit e both-created divergente viram cópia conflitada** estilo Dropbox
(`domain/conflicts.build_conflicted_copy_path`: "nome (conflicted copy
YYYY-MM-DD).ext"; local move-se p/ a cópia — sobe como arquivo novo — e o
remoto assume o path original; variantes numéricas se o nome colidir;
`EnqueueConflictCopy` no pool com `SettleConflict` de volta);
**edit-vs-delete: a edição vence** — resolução = `ForgetKnown` (o lado
sobrevivente vira criação nova na rodada seguinte). `pending_conflicts`
no reconciler evita re-despacho; `today()` injetado p/ o carimbo de data.
**Watcher local real**: polly (polling, sem dependência de inotify-tools)
supervisionado na árvore → `local_watcher` com debounce (1,5 s; poll 2 s)
→ `ReconcileNow` — edição local sincroniza em segundos; a rodada periódica
de 30 s vira backstop. filespy/inotify pode substituir atrás do mesmo
comando `NoticeLocalActivity`.

Fase upload (sessão 5): leitura em chunks (`fs/chunked_read` + FFI `file`);
upload resumable (`drive/upload`: POST/PATCH inicia sessão via Location,
PUT chunks múltiplos de 256 KB — 8 MiB na composição — com Content-Range,
308 até o 200/201 final com a projeção `fields` do parser); mutações
(`drive/mutate`: `create_folder`; **delete local propaga como TRASH**,
nunca delete permanente); `transfer_pool` com `EnqueueUpload`/
`EnqueueTrashRemote` (pastas remotas faltantes criadas uma vez — cache por
parent+nome — e observadas de volta ao modelo) e feedback
`SettleUpload`/`SettleTrash`; `reconciler` monta `UploadPlan` (âncora = pasta
remota existente mais profunda + cadeia de pastas faltantes), atualiza
in-place via file_id do known, **rastreia transferências em voo** (nunca
re-despacha antes do settle; falha settled re-despacha na rodada seguinte) e
roda **rodadas periódicas** (30 s) — o gatilho local até o watcher chegar.
Invariante crítico do feedback: upload concluído entra NO MODELO REMOTO na
hora via settle; esperar o próximo poll deixaria janela em que o arquivo
parece remoto-ausente e seria apagado localmente.

Fases anteriores: domínio puro
(`SyncDecision`, `reconcile`/`reconcile_all`, `paths.resolve_paths`); OAuth
desktop completo (PKCE, loopback FFI, `token_manager` com refresh por margem
de 60 s); clientes Drive (Changes paginado, `files.list` + `files/root` em
`drive/listing`); persistência SQLite (write-through via porta `StateStore`);
download streaming (FFI httpc, parcial+rename); scan local
(`fs/local_scan`, exclui `.iaragon-partial`) e md5 sob demanda
(`fs/hashing`); **pipeline completo**: `remote_poller` (1º ciclo SEMPRE
semeia: token → snapshot `files.list`+root id → `SeedMirror`; depois
`ApplyRemoteChanges`; entrega ANTES de avançar o token) → `reconciler`
(modelo remoto em memória, resolve paths, hash de gêmeos nunca-sincados,
despacha por funções injetadas; UploadLocal/DeleteRemote/Conflict ignorados
nesta fase) → `transfer_pool` (blob/folder/nativo-link/shortcut-link, delete
local, `PutKnown` pós-sucesso, retry limitado 4x) → `state_owner`.

Regra DDD aplicada no pipeline: o reconciler define os contratos de intake
(`RemoteSighting`/`RemoteObservation`) e o poller traduz o formato do Drive
para eles; despachos saem por records de função (a composição embrulha o
subject do pool). Espelho local: `~/GoogleDrive` (composition root); nativos
materializam como links `.desktop` (`https://drive.google.com/open?id=…`)
com sufixo `.desktop` decidido no reconciler.

Login interativo: `gleam run -m iaragon/login`. Config em `~/.config/iaragon/`:
`oauth_client.json` (`{"client_id":…,"client_secret":…}` de um client
"Desktop app" do Google Cloud, criado à mão) e `tokens.json` (gerado, 600).
Estado do daemon: `~/.local/share/iaragon/state.db` (SQLite). `gleam run`
sobe a árvore e o main envia o primeiro `Poll` — sem credenciais, o poller
só fica em retry (a porta Drive carrega tudo lazy).

Limitações conhecidas (para as próximas sessões): modelo remoto do reconciler
é só memória (crash do reconciler = mudanças ignoradas até novo seed/restart);
adoção de gêmeos idênticos não grava `PutKnown` (re-hash a cada rodada — falta
uma decisão de bookkeeping no domínio); shortcuts ficam fora do espelho
(precisam de `shortcutDetails` na projeção); export de nativos
(ExportOffice/ExportOdf) ainda materializa como link.

**Próximas sessões**: renames como renames (hoje viram delete+create —
funcional, mas re-transfere), export real de nativos
(ExportOffice/ExportOdf), shortcutDetails, watcher inotify (filespy) como
alternativa ao polling do polly, overlays de file manager, e as limitações
acima (modelo remoto só em memória; adoção de gêmeos sem bookkeeping).

Fatos de API que os testes fixam: `size` e demais int64 chegam como STRING no
JSON do Drive; `changes.list` e `files.list` recebem `fields` com a projeção
exata usada no parser; um redirect OAuth sem `code`/`error` é malformado, e
state errado invalida qualquer resultado; httpc `{stream, path}` faz append
(ver FFI); md5 local em hex minúsculo como o Drive reporta.

## Ambiente de dev/CI (containers Ubuntu 24.04)

- **Erlang/OTP ≥ 26 obrigatório em runtime**: o OTP 25 do apt compila, mas
  `bit_array.base64_url_encode` do stdlib explode em runtime ("OTP/26 or
  higher is required"). Usar OTP pré-compilado do builds.hex.pm:
  `curl https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-27.3.4.14.tar.gz`,
  extrair p/ /opt/otp27, rodar `/opt/otp27/Install -minimal /opt/otp27`,
  `export PATH=/opt/otp27/bin:$PATH` (exportar em cada shell novo).
- `rebar3` via apt (necessário para compilar a dep Erlang `fs` do filespy).
- Binário do Gleam: GitHub releases; se o GitHub estiver bloqueado pelo proxy da
  sessão, extrair da imagem OCI oficial `ghcr.io/gleam-lang/gleam:vX.Y.Z-scratch`
  (binário musl estático em `/bin/gleam`, baixável com curl + Bearer token
  anônimo do ghcr.io).
- O "backend port not found: inotifywait" nos testes é a app `fs` do filespy
  avisando que inotify-tools falta — inofensivo enquanto o watcher é stub.
