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
  (gen_tcp one-shot para o redirect OAuth), `src/iaragon_download_ffi.erl`
  (httpc `{stream, path}` para download direto a disco; TLS confia no default
  verify_peer do httpc em OTP ≥ 26 — mesma premissa do gleam_httpc),
  `src/iaragon_file_ffi.erl` (leitura em chunks p/ upload resumable) e
  `src/iaragon_exec_ffi.erl` (os:find_executable p/ detectar inotify-tools).
  Armadilha aprendida: `{stream, path}` FAZ APPEND em arquivo existente — por
  isso downloads vão para `<dest>.iaragon-partial` e são renomeados no
  sucesso (atomicidade de espelho de graça).
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

**AS 4 FASES DO ROADMAP ENTREGUES**: sync bidirecional com resolução de
conflito, watcher local por inotify (fallback polling) e overlays de
status — GVfs metadata (file managers GTK) e plugin KOverlayIconPlugin +
socket de status (Dolphin/KDE).

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

Fase correção/robustez (sessão 7): **renames remotos viram `MoveLocal`**
(bug corrigido: rename de arquivo sincado era silenciosamente ignorado — o
reconcile só comparava conteúdo, nunca path; agora path divergente decide
move ANTES da detecção de conteúdo; edit simultâneo resolve na rodada
seguinte); `EnqueueMoveLocal` idempotente no pool (pastas movem por rename
carregando filhos; filho já carregado = só bookkeeping; PutKnown SÓ no
sucesso); **`AdoptKnown`** grava gêmeos idênticos no índice (fim do re-hash
por rodada); **auto-reseed** — reconciler sem modelo (reiniciado) que recebe
mudanças pede `Reseed` ao poller; poller mantém CADEIA ÚNICA de polling
(timer pendente cancelado em Poll fora de banda — senão reseed duplicaria o
polling para sempre).

Fase renames locais (sessão 8): **renames locais viram `MoveRemote`**
(files.update de name/parents — metadado só, sem re-transferir bytes).
Inferência pura em `reconcile_all` (`infer_local_renames`): known sumido
localmente (remoto intacto, não-movido e não-trashed) casa com local novo
(sem known e sem remoto no path) pela assinatura que um `mv` preserva —
`#(size, mtime)`. **Só par ÚNICO um-pra-um conta**; qualquer ambiguidade
cai no delete+create (seguro, só desperdiça). O UploadLocal do destino é
suprimido via `renamed_to`. `mutate.rename_file` (PATCH files/{id} com
`name` + `addParents`/`removeParents`); `EnqueueMoveRemote(plan)` no pool
reusa `ensure_remote_folders_for` (cadeia de pastas faltantes, cache por
parent+nome); reconciler monta `MoveRemotePlan` (old_parent do modelo,
âncora como no upload) e segura DOIS pending keys (trash do file_id +
upload do path destino) até `SettleMove`, que atualiza o modelo remoto na
hora (mesmo invariante do settle de upload). **Bug latente corrigido**:
o scan local lista arquivos, nunca diretórios — pasta sincada sempre
parece localmente ausente; sem o guard `(None, Some(r), Some(k))` com
`k.kind == Folder -> Noop`, TODA pasta sincada seria trashed a cada
rodada. Consequência documentada: deleção local de pasta VAZIA não
propaga (a dos arquivos dela propaga).

Fase export de nativos + shortcuts (sessão 9): **ExportOffice/ExportOdf
exportam de verdade** Docs/Sheets/Slides (docx/xlsx/pptx e odt/ods/odp —
MIMEs re-verificados na doc oficial em 2026-07; ODS é
`application/vnd.oasis.opendocument.spreadsheet`, SEM o prefixo `x-` de
docs antigas). `domain/native_docs.choose_materialisation(mime, policy)`
→ `WriteLinkFile | ExportDocument(export_mime, extension)`; nativos sem
export de documento (drawing só exporta imagem/PDF; form/site/map não têm)
ficam link em qualquer política. Reconciler decide a EXTENSÃO no path
(materialized_path); pool decide os BYTES (`export_to_disk` injetado —
`files/{id}/export?mimeType=…` percent-encoded, mesmo FFI streaming de
download, mesmo retry/drop). **shortcutDetails na projeção**: changes e
files.list pedem `shortcutDetails(targetId)`; `ChangedFile`/`RemoteSighting`
carregam `shortcut_target_id`; shortcut com alvo entra no espelho como
link `.desktop` para o ALVO (`classify_sighting`); sem alvo visível fica
fora, como antes.

Fase robustez do espelho (sessão 10): **pasta deletada no Drive limpa o
diretório local** — `(None, None, Some(k))` com `k.kind == Folder` decide
`DeleteLocal` (não `ForgetKnown`): pasta é invisível ao scan, então "ambos
sumiram" só prova o lado remoto. No pool, `EnqueueDeleteLocal` de
diretório remove **SÓ se vazio** e só então esquece o known
(`simplifile.delete` em dir é RECURSIVO — sem o guard, bytes nunca-sincados
dentro da pasta seriam perdidos); não-vazio → nada, a rodada seguinte
re-decide e converge quando os filhos forem deletados. **Move com destino
ocupado limpa origem vazia**: filhos já carregados um a um → origem vazia
é removida e o move vira bookkeeping; origem com conteúdo mantém o erro.
**Guarda de 10 MB no domínio**: `choose_materialisation(mime, policy,
size:)` — nativo com size reportado acima do limite materializa como link
em vez de perder uma chamada de export por rodada (reconciler e pool usam
o MESMO ponto de entrada — extensão e bytes nunca divergem).

Limitações conhecidas: o size reportado do nativo é proxy do tamanho do
EXPORT (diferem nos dois sentidos: export grande com size pequeno ainda
re-tenta e falha por rodada; o inverso vira link sem tentar); deleção
local de pasta vazia não propaga (ver sessão 8); rename local com edição
simultânea do conteúdo muda a assinatura e vira trash+re-upload
(converge, mas re-transfere). (Troca de `NativeDocPolicy` com espelho
povoado: resolvida na sessão 14 — re-materializa.)

Fase watcher inotify (sessão 11): **eventos reais de FS via filespy**
atrás do mesmo `NoticeLocalActivity` — o debounce e o `ReconcileNow`
continuam no ator `local_watcher`, só a FONTE muda.
`local_watcher.add_watch_source(builder, root, notify, poll_interval_ms:,
use_inotify:)` adiciona à árvore o filho certo: filespy
(`new |> add_dir |> set_handler |> start`, embrulhado em
`supervision.worker` — filespy 0.7 não tem `supervised()`) ou polly como
fallback. A escolha é da composição: `detect_inotify_support()` via FFI
`os:find_executable("inotifywait")` — filespy exige inotify-tools em
runtime; sem ele o daemon cai no polling do polly sem mudança de
comportamento. O diretório do espelho é criado antes do watch (inotify
recusa dir inexistente). Rodada periódica de 30 s segue de backstop
(inotifywait não cobre todos os casos, ex. subdirs novos). O teste do
caminho inotify prova a origem do evento com polling de 1 h e é no-op em
máquina sem inotify-tools (lá roda o caminho polly, que tem teste
próprio).

Fase overlays (sessão 12): **emblemas de status no file manager via GVfs
metadata** — `gio set -t stringv <arquivo> metadata::emblems <emblema>`,
que Nautilus/Nemo/Caja renderizam no ícone SEM extensão C/Python.
`entry.SyncStatus` (`Syncing | Synced`) no domínio; o pool ganha
`signal_status` injetado e sinaliza Syncing no início de
download/upload e Synced no funil `record_known` (e no move local —
rename dropa gvfs metadata, o destino é re-pintado).
`infrastructure/fs/emblems`: `paint_status` (runner injetado; emblemas
`emblem-synchronizing`/`emblem-default`), `detect_emblem_support` (sonda
com um SET REAL num arquivo — o gio pode existir sem gvfsd-metadata, só
a escrita de verdade diferencia) e `build_status_painter` (no-op
silencioso em máquina sem suporte — emblema é decoração, nunca falha
transferência). FFI `run_command` roda executável SEM shell
(spawn_executable + vetor de args — path com espaço/aspas não injeta).
Limitações: aparência/existência dos emblemas depende do tema de ícones;
sem emblema de conflito (conflito se resolve em cópia, não é estado
persistente).

Fase overlays Dolphin/KDE (sessão 13): **socket de status + plugin
KOverlayIconPlugin**. O daemon expõe um servidor de linha em socket Unix
(`$XDG_RUNTIME_DIR/iaragon.sock`, senão `~/.local/share/iaragon/
status.sock` — a MESMA ordem no plugin): path absoluto entra, palavra de
status sai (`syncing|synced|unknown`), várias trocas por conexão. Fonte
da verdade: ator `status_board` (application) — dict path→status
alimentado pelo fan-out do `signal_status` do pool (emblema gvfs + board
num sinal só; o board entra na árvore ANTES do pool, senão o send a nome
não-registrado explode) — com fallback ao índice de knowns
(`state_owner.FindKnownByPath`, varredura linear: índice é por file_id).
FFI `iaragon_status_ffi` (gen_tcp `{local,path}`, packet line, socket
velho deletado no bind; listen socket pertence ao ator supervisionado —
`status_server.supervised` via `actor.new_with_initialiser`). Plugin C++
em `integrations/dolphin/` (COMPILADO contra KF5 no container p/ validar;
instalação no README): `getOverlays` NÃO PODE bloquear (contrato do KIO)
→ cache TTL 3 s + `QLocalSocket` assíncrono + `overlaysChanged`; Dolphin
carrega do namespace `kf5/overlayicon` (`kf6/` no Qt6 — verificado no
fonte do Dolphin); emblemas `vcs-normal`/`vcs-update-required` (os dos
plugins VCS, garantidos no Breeze). Limitação: atualização de estado
aparece em até TTL+re-query (sem canal de push do daemon p/ o plugin).

Fase limpeza de backlog (sessão 14): **trocar `NativeDocPolicy`
re-materializa o nativo** — decisão `MoveLocal` de nativo cuja EXTENSÃO
mudou (materialização diferente, ex. `.desktop` → `.docx`) não vira
rename (deixaria bytes velhos atrás da extensão nova): o reconciler
despacha `EnqueueDeleteLocal(old)` + `EnqueueDownload` e o PutKnown do
download conserta o índice; rename puro de nativo (mesma extensão)
continua move barato. **`SyncFailed`**: terceira variante de
`SyncStatus` sinalizada em TODO give-up do pool (download, upload,
cópia de conflito, move remoto — trash não tem path); gvfs
`emblem-important`, palavra `failed` no socket, `vcs-conflicting` no
plugin Dolphin. A rodada seguinte re-despacha e sobrescreve com
Syncing/Synced — falha é estado transitório visível, não terminal.

**Backlog zerado.** Próximo trabalho novo = decisão de produto nova.

Fatos de API que os testes fixam: `size` e demais int64 chegam como STRING no
JSON do Drive; `changes.list` e `files.list` recebem `fields` com a projeção
exata usada no parser (incl. `shortcutDetails(targetId)`); um redirect OAuth sem `code`/`error` é malformado, e
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
- `apt-get install inotify-tools`: necessário para o backend inotify real
  (filespy/fs) — sem ele a app `fs` loga "backend port not found:
  inotifywait" (inofensivo) e o daemon usa o fallback polly; o teste
  end-to-end do inotify vira no-op.
