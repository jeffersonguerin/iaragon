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

Fase hardening (sessão 15): revisão adversarial em 3 frentes (segurança,
OTP/concorrência, segurança de dados) via subagentes; achados verificados
por leitura antes de corrigir, cada fix com TDD. Corrigido:
- **Path traversal (crítico)**: nome remoto `..`/`.`/`""` escapava do
  espelho (`root_dir <> "/" <> path`). `paths.sanitize_segment` neutraliza
  os três com `_` à frente; `/` já virava `_`.
- **Poller auto-start (crítico)**: só o `main` mandava `Poll` (uma vez);
  um crash do poller parava o sync remoto→local para sempre. Agora
  `new_with_initialiser` manda `Poll` a si no boot E em todo restart.
- **Scan não segue symlinks (alto)**: `get_files` seguia links
  (exfiltração de fora do espelho; ciclo = loop infinito). Travessia
  própria com `link_info` (lstat), pula symlink/special.
- **Segredos (alto)**: `Corrupted` sem payload (não vaza token/secret em
  `string.inspect`); `tokens.json` via temp+rename 0600, dir 0700.
- **Corrida upload (alto)**: `record` de upload usa size/mtime do SCAN, não
  stat pós-transferência — edição no meio do upload re-sobe na rodada
  seguinte em vez de congelar remoto corrompido como synced.
- **Delete não-recursivo (alto)**: branch de arquivo usa `delete_file`
  (não `delete`, que é recursivo) — kind drift não vira wipe de árvore.
- **Rename de pasta (alto)**: pasta nunca entra no conjunto `vanished` de
  `infer_local_renames` (o scan não lista dirs, então parecia sempre
  sumida e podia renomear a pasta remota inteira sobre um arquivo novo de
  assinatura coincidente).
- **Socket (médio)**: `chmod 0600` no bind (protocolo revela paths do
  espelho) + `{packet_size, 4096}` (linha ilimitada = OOM).
- **Supervisão (médio)**: `restart_tolerance(10, 30)` (default 2/5 s
  derrubava o daemon numa cascata a partir de 1 erro transitório de SQLite);
  scan pula entrada com lstat falho (não crasha a rodada); reconciler sem
  modelo pede `Reseed` em gatilho local (não só em ApplyRemoteChanges).

Fase hardening — recheck destrutivo (sessão 15, resolvido o residual):
**delete e download re-verificam o arquivo antes de destruir**. Uma
decisão feita no scan pode executar minutos depois (fila serial do pool);
se o usuário editou nesse meio, apagar/sobrescrever perderia a edição sem
virar conflito. Agora `EnqueueDeleteLocal(known)` e `EnqueueDownload(remote,
expected)` carregam a metadata esperada; o pool compara size+mtime do
arquivo em disco imediatamente antes: divergiu → pula (mantém o known), a
rodada seguinte re-decide e o domínio produz o conflito certo
(LocalEditRemoteDelete / EditEdit — edição sobrevive). Delete só rechecka
BLOB (pasta = empty-check; link `.desktop` gerado = force). Download só
rechecka quando `expected = Some` (remoto mudou); remoto novo (`None`) não
rechecka (não quebra re-download idempotente). Sub-janela residual
ESTREITA: edição DURANTE o stream de um download longo — o rename atômico
acontece dentro do `download.gleam`; fechar exige um guard pré-rename lá
(a maior janela, a de espera-na-fila, está fechada).

Fase hardening — verificação de conteúdo no rename (sessão 15, resolvido):
**o rename local agora confirma o md5** antes de confiar na assinatura
size+mtime. `reconcile.infer_local_renames` (agora público) checa
`content_compatible` — quando ambos os lados têm md5, o checksum é
autoritativo; o reconciler hasheia os candidatos (`hash_rename_candidates`)
ANTES do `reconcile_all`, então um arquivo não-relacionado que só colide na
assinatura é rejeitado (cai no delete+create seguro) em vez de renomear o
remoto errado. Hash falho → fallback ao size+mtime (comportamento antigo).

Fase hardening — decoração best-effort (sessão 15, resolvido F8): os
sends/calls que só alimentam o overlay (`signal_status` → board,
`locate_known` e o `answer_status` do socket) checam `subject_owner` antes:
alvo mid-restart (nome não-registrado) → pula/responde "unknown" em vez de
explodir no remetente. Crucial: o send de `signal_status` era um dos
gatilhos de crash do PROPRIO pool (abortava transferência); agora não é.
Os `settle_*` (feedback, não decoração) NÃO são best-effort de propósito —
perder um settle vazaria estado.

Fase hardening — pending no DOWN do pool (sessão 16, resolvido F2):
**o reconciler monitora o `transfer_pool` e limpa TODO o pending no DOWN**.
Se o pool cai com upload/trash/move em voo, o settle correspondente nunca
chega e aquele path/id parava de sincronizar até o reconciler reiniciar
(liveness, não perda de bytes). Agora o reconciler usa
`new_with_initialiser` com um seletor `select_monitors` catch-all instalado
UMA vez → todo `process.monitor` posterior entrega o DOWN como o comando
`ForgetInFlight`. `ensure_pool_monitored` (topo de cada mensagem) mantém um
monitor vivo enquanto o pool é resolvível (`resolve_pool_pid` injetado =
`subject_owner` do nome do pool; erra durante o (re)start, re-tenta na
mensagem seguinte). `ForgetInFlight` zera os quatro pending
(`pending_uploads/trashes/conflicts/move_paths`) e esquece o monitor (None →
re-monitora o pool reiniciado). **Não roda rodada no DOWN** (o pool pode
estar mid-restart e o send explodiria); o re-despacho fica com a próxima
rodada — o backstop periódico de 30 s no pior caso. Re-despacho é seguro:
nada do pool morto está mesmo em voo, e trash/move/upload re-despachados são
idempotentes. O seletor do `process.call` ao state_owner (monitor próprio,
com demonitor) não interfere no catch-all.

Backlog de residuais zerado.

Fase pentest de segurança (sessão 16): 3 subagentes adversariais em
paralelo (auth/OAuth, persistência/injeção, FS/paths/FFI/socket), cada
achado verificado por leitura antes do fix, cada fix com pentest TDD.
Corrigido:
- **Injeção em `.desktop` (HIGH)**: `write_link_file` interpolava o NOME e
  o file_id crus do Drive no arquivo `.desktop`. Nome com `\n` injeta
  `Type=Application`+`Exec=` (GKeyFile honra o último valor de chave
  duplicada) → RCE ao clicar no file manager. Novo módulo PURO
  `domain/link_file.build` escapa todo valor por spec Desktop Entry
  (backslash primeiro, depois `\n`/`\r`/`\t`); o pool delega. Vale para
  nativo-LinkFile E shortcut.
- **Loopback OAuth sem `packet_size` (MED)**: qualquer processo local
  alcança a porta efêmera do redirect na janela de login; request line
  ilimitada = OOM. Capado em `{packet_size, 8192}` (paridade com o status
  socket). Linha longa vira `{error, emsgsize}` limpo.
- **file_id sem percent-encode nos URL builders (LOW)**: `build_media_url`
  /`build_export_url` concatenavam o file_id cru; `uri.percent_encode` nos
  dois (ids são opacos hoje, mas não depender disso).
- **Acceptor do status socket (LOW)**: `ok = gen_tcp:controlling_process`
  podia badmatch em `{error, closed}` (peer aborta no meio do handoff) e
  derrubar o acceptor; agora casa `{error,_}` e dropa só aquele cliente.
  Corrida timing-dependente NÃO reproduzida (barrage de 400 aborts com RST
  não disparou) — guard de robustez adicionado; fix é defesa de qualquer
  forma.
- **Corrida de startup do poller (robustez, exposta pelo pentest)**: o
  poller inicia ANTES do reconciler e auto-dispara Poll; semear rápido
  mandava `SeedMirror` ao subject nomeado do reconciler ainda não
  registrado → `send` a nome não-registrado CRASHAVA o poller (deixava o
  smoke test flaky, queimava restart budget). Entrega agora via guard
  `deliver` (checa `subject_owner`; erra transiente → retry do Poll);
  seeded/token só avançam após entrega OK (seed/mudanças nunca perdidos).

Negativos verificados (não é vulnerabilidade): SQLi — todas as queries
parametrizadas; parsing de int64-como-string crash-safe; CSRF/state e PKCE
(S256, verifier CSPRNG) corretos; segredos sem payload em erros; path
traversal (`sanitize_segment`) cobre os vetores reais no alvo Linux;
emblems FFI sem shell (argv vector); delete não-recursivo p/ blob; scan
pula symlink.

**Resíduo do `.iaragon-partial` resolvido (sessão 17)**: downloads vão
agora para um diretório de controle reservado `.iaragon-partial/` DENTRO da
pasta do destino, e o scan pula esse diretório por LOCALIZAÇÃO (não mais por
sufixo de nome). Um arquivo remoto literalmente terminado em
`.iaragon-partial` sincroniza normal. Rename no mesmo diretório segue
atômico; manter o basename original evita estouro de comprimento de nome em
paths fundos.

Fase pentest de segurança (sessão 17): 3 subagentes em superfícies não
cobertas antes (upload resumable/mutate, token/OAuth sob respostas hostis,
parsers JSON + resolução de paths sob grafo malicioso). Verificado que
`resolve_paths` TERMINA sob ciclo de parents (guard de visitados + grafo
funcional de parent único — negativo importante). Corrigido, cada um com
pentest TDD:
- **Colisão de desambiguação em paths (HIGH)**: `assign_final_names` tecia o
  file_id num nome duplicado mas não re-checava o resultado; um colaborador
  num Drive compartilhado lê os fileIds e forja um irmão cujo nome natural
  == nome tecido de outro → dois fileIds no MESMO path → overwrite
  silencioso. Agora aplica variantes numeradas (disciplina da cópia
  conflitada) até um nome livre.
- **Vazamento de token em erro OAuth (MED-HIGH)**: `RefusedByServer(status,
  body)`/`UnexpectedPayload(body)` carregavam a resposta do token endpoint;
  o login faz `string.inspect` no stderr → token vivo vazava. Variantes agora
  sem payload (disciplina do `Corrupted`).
- **SSRF via Location no upload resumable (MED-HIGH)**: a session URI do
  header vinha usada sem validar; resposta hostil redirecionava os BYTES do
  arquivo p/ host do atacante. Agora só aceita HTTPS em `*.googleapis.com`
  antes de qualquer PUT. (Bearer NÃO vaza — o PUT não leva Authorization.)
- **file_id sem encode no write path (MED)**: `mutate.rename_file`/
  `trash_file` e o `UpdateFile` do upload concatenavam file_id cru →
  injeção de query em chamada MUTANTE (ex. addParents/removeParents num
  trash). `uri.percent_encode` nos três.
- **expires_in sem limite (MED)**: valor astronômico fixava o token como
  "nunca expira" → auto-refresh nunca dispara → sync trava em silêncio.
  Clampado a `[0, 86400]` no parse.
- **Paginação O(n²)/ilimitada (MED)**: `changes`/`listing` usavam
  `list.append` no acumulador (O(n²)) sem cap → CPU quadrática + heap sem
  limite; feed que só devolve nextPageToken loopava eterno. Agora prepend +
  `reverse` no fim (O(n), ordem preservada) + cap de páginas (erro limpo, o
  poller re-tenta).
- **sanitize_segment sem controle (LOW)**: NUL/control chars passavam p/ o
  segmento → op de arquivo trunca/erra. Substituídos por `_` (< 0x20 e 0x7f).

Residuais desta rodada, RESOLVIDOS (fecham a sessão 2 de pentests):
- **`descend` → worklist explícito (P3)**: a resolução de paths era recursiva
  (uma frame por nível de aninhamento) — sobrevivia a centenas de milhares de
  níveis no BEAM, mas era DoS de memória/latência em profundidade patológica.
  Reescrita como `walk` tail-recursivo sobre um worklist na heap → stack
  CONSTANTE, profundidade-independente. Semântica idêntica (guard de visitados
  termina ciclos; desambiguação por pasta é ordem-independente, logo o dict
  resultante é o mesmo) — os testes de paths fixam isso; teste novo resolve
  cadeia de 200k níveis.
- **Upload de 0-byte (U3)**: arquivo vazio não tem chunk → `send_chunks` erra
  em EndOfFile no byte 0 (nunca subia). Agora finaliza a sessão com corpo
  vazio e `Content-Range: bytes */0` (a forma documentada `bytes */TOTAL` com
  TOTAL=0, como as client libs do Google fazem). Guard preciso
  (`total_size == 0 && offset == 0`) — short read em arquivo não-vazio segue
  erro. RESÍDUO honesto: não verificado e2e contra um upload 0-byte real do
  Drive (doc do Drive não detalha o caso; segue a forma documentada + convenção
  das libs).

**Backlog de residuais zerado** (2 rodadas de pentest encerradas).

Fase pentest de segurança (sessão 18): 3 subagentes focados em penetração
forçada, vazamento de DADOS e vazamento de CREDENCIAIS. Corrigido:
- **`state.db` world-readable (HIGH, vazamento de dados)**: o DB indexa a
  árvore inteira do Drive (fileId↔path + metadados) e era criado 0644 num dir
  0755 → qualquer usuário local lia `~/.local/share/iaragon/state.db` e
  enumerava todo o Drive do usuário. `state_db.open` agora faz chmod 0600 no
  arquivo (best-effort; `:memory:` não tem arquivo) e o composition root
  restringe o data dir a 0700 (guard mais forte — cobre DB, socket e journal).
  Sem credenciais no DB (é disclosure de metadados). Espelha o hardening do
  `tokens.json`.

Negativos verificados (não é vulnerabilidade):
- **Credenciais em crash report de ator**: NENHUM ator guarda token/secret no
  state — `token_manager` é FUNÇÃO (não ator; carrega da disco por chamada, só
  na stack), e as closures dos transfer/drive ops capturam apenas `config_dir`
  (um path); Erlang renderiza funs como refs opacas no `~p`/SASL. Um crash de
  qualquer ator imprime refs de fun + path + metadata, nunca uma credencial.
- **Header Authorization em redirect de download**: o download stream manda
  `Bearer` no request inicial; o pentest provou (teste direto="leaked-auth",
  redirect="no-auth") que o httpc do Erlang REMOVE o header Authorization ao
  seguir um redirect — o token nunca acompanha o redirect (o alt=media 302 vai
  p/ URL assinada do googleusercontent que não precisa dele). Guardas de
  regressão adicionadas; sem mudança de código.
- **Bearer em erros/logs**: nenhum `string.inspect`/print/panic transitivamente
  contém token/secret (login imprime `OauthError` já sem payload; os FFI de
  download formatam só `Reason`, nunca URL/headers).
- **argv option injection nos emblemas**: o path passado ao `gio` é sempre
  ABSOLUTO (`/home/.../GoogleDrive/...`), nunca começa com `-`; emblema é valor
  fixo. Não alcançável.
- **Escrita fora do espelho**: todo destino de write/delete/rename/mkdir é
  `root_dir <> "/" <> P` com `P` só de segmentos sanitizados (control-strip
  ANTES do check de `..`); `conflicts` só reescreve o último segmento de um
  path já sanitizado. Não construível.

Residual rastreado (documentado, NÃO alcançável no modelo de ameaça):
- **Symlink TOCTOU em diretório intermediário (LOW)**: um processo do MESMO
  usuário troca um dir intermediário do espelho por symlink entre a decisão e
  o rename → write segue p/ fora. Sem ganho real: o daemon roda como o próprio
  usuário, que já tem os direitos de FS. Fix exigiria travessia `openat`
  por-componente (não exposto pelo simplifile). Nota de produto: o conteúdo do
  espelho sob `~/GoogleDrive` é 0644/0755 (como o Google Drive for Desktop);
  se confidencialidade do conteúdo entre usuários locais virar requisito, o
  root do espelho precisaria de 0700.

**Backlog de residuais de segurança zerado** (3 rodadas encerradas).

Fase alinhamento com a API oficial (sessão 19): comparação com o campo
(rclone bisync/mount, ocamlfuse, Insync, gvfs/KIO, grive) + revisão da doc
Drive v3 atual. Confirmado que o iaragon é o único desenho FOSS
daemon+espelho+Changes-API; escolhas validadas (conflito estilo Dropbox,
SQLite por fileId, nativo-como-link). Corrigido a partir da revisão:
- **`pageSize=1000` no `changes.list`** (default era 100) — menos requests e
  quota; `files.list` já usava 1000.
- **`acknowledgeAbuse=true` no `alt=media`** — arquivo que o Drive marca como
  abusivo falha o download p/ sempre sem isso; é arquivo do próprio usuário.
- **Reseed em page token rejeitado**: `changes.list` 400 (invalidPageToken) /
  410 (gone) agora vira `StalePageToken` (tipo `ChangesError` no `DrivePort`;
  a composição classifica) → o poller busca um `startPageToken` fresco,
  sobrescreve o stale e força re-seed completo (pode ter perdido mudanças no
  gap). Antes: retry infinito com o mesmo token → sync remoto travado.
- **Notas de doc atualizadas**: `sha1Checksum`/`sha256Checksum` EXISTEM p/
  blobs (só blobs, como md5) — o parser segue com md5 (suficiente); quota é
  325k units/min/USUÁRIO **e** 1M/min/PROJETO, com revisão dependente da
  idade do projeto (2026-05-01) — verificar no Console; `pageSize` máx 1000.
- **0-byte (U3) mantido como `bytes */0`**: a alternativa doc-blessed
  (multipart) exigiria um path de upload novo só p/ um caso raro; `*/0` segue
  a forma documentada `bytes */TOTAL`. Decisão registrada, não é invenção.

Edit-back de nativos — resolvido pela via SEGURA (sessão 19): atualizar o
Google Doc a partir do `.docx` editado é INSEGURO na API v3 (`files.update`
com media substitui/converte o conteúdo; conversão é só de `files.create`)
→ arriscaria virar o Doc num blob. Então NÃO fazemos isso. Em vez disso,
**edição local de um nativo exportado vira cópia conflitada** (decisão do
usuário, estilo Dropbox): `reconcile` reporta `Conflict(NativeLocalEdit)`
(o nativo NUNCA sobe — só reporta a condição); o `reconciler` resolve por
política — sob export (`ExportOffice`/`ExportOdf`) reusa a máquina de
conflito existente (a cópia move-se p/ nome datado e sobe como `.docx` blob
NOVO, sem conversão, o Doc intacto; `run_conflict_copy` re-exporta o nativo
no path original); sob `LinkFile` o arquivo é um link `.desktop` gerado,
então só re-escreve. `record_known` faz `file_info` no `.docx` re-exportado
→ o nativo assenta na rodada seguinte sem loop de conflito. Detecção por
size+mtime (nativo não tem md5); um `touch` puro sem edição de conteúdo
pode gerar uma cópia conflitada espúria (inócua). Não implementável de
outra forma sem violar "não inventar API"/"zero perda silenciosa".

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
- **CI local via `.githooks/` (sessão 16)**: rodar `./scripts/setup-dev.sh`
  no início de cada sessão (seta `core.hooksPath`, config não versionada).
  O `pre-commit` recusa commit sem `gleam format --check` limpo e suíte
  verde — a regra "todo commit verde" agora é mecânica. Bypass de
  emergência: `--no-verify`. O hook NÃO exporta o PATH do OTP (exigir isso
  do shell chamador); commits via ferramenta precisam do
  `export PATH=/opt/otp27/bin:$PATH` no mesmo comando.
- **LSP do Gleam para Claude Code (sessão 16)**: plugin versionado em
  `.claude/skills/gleam-lsp/` (`.claude-plugin/plugin.json` + `.lsp.json`
  com `command: gleam, args: [lsp], extensionToLanguage: {".gleam":
  "gleam"}`). Fato verificado na doc oficial: `.lsp.json` na RAIZ do
  projeto NÃO é lido — LSP é config de plugin; o diretório
  `.claude/skills/` do repo carrega automático (trust gate) na PRÓXIMA
  sessão. Não usar `restartOnCrash`/`shutdownTimeout` (exigem CC ≥
  2.1.205; em versões anteriores a presença deles faz o servidor ser
  PULADO). Sem LSP para os `.erl` (erlang_ls não instalado; FFI é fino).
