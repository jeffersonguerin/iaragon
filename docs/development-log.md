# Log de desenvolvimento

Histórico cronológico das fases de feature, sessão a sessão. As fases de
hardening/pentest vivem em [security-log.md](security-log.md); escala e
performance em [performance.md](performance.md); fatos da Drive API em
[drive-api.md](drive-api.md).

## Roadmap (ordem de implementação)

1. Download-only espelhando o remoto
2. Upload-only
3. Bidirecional com detecção de conflito
4. Overlays no gerenciador de arquivos

**AS 4 FASES DO ROADMAP ENTREGUES**: sync bidirecional com resolução de
conflito, watcher local por inotify (fallback polling) e overlays de
status — GVfs metadata (file managers GTK) e plugin KOverlayIconPlugin +
socket de status (Dolphin/KDE).

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

Fase doctor: **`iaragon-doctor`** — health check passivo em 6 checks (oauth
client, tokens com refresh REAL exercitado — pega a expiração de 7 dias do
modo Testing antes do sync travar —, state.db via `count_known` novo (COUNT,
não carrega o índice), liveness do daemon por 1 linha no status socket,
espelho, watcher). Núcleo puro `application/diagnostics` (render + wording de
expiração, testados); comando = composição fina como o login; exit ≠ 0 em
falha. Launcher em install.sh/Formula; **timer systemd opcional**
(`iaragon-doctor.timer`, diário, instalado mas não habilitado — rodar
"automático" é o timer, NUNCA código no daemon: custo zero para o sync).
`status_server.resolve_socket_path` extraído e compartilhado
(daemon+doctor): `XDG_RUNTIME_DIR` VAZIO conta como ausente (paridade com o
plugin Dolphin; antes o daemon tentaria bindar `/iaragon.sock`). FFI probe
captura `badarg` do gen_tcp (path > ~107 bytes) como erro limpo. Unicode do
stdout configurado no próprio doctor (launcher `erl -noshell` sai em latin1).

Fase fricção OAuth: **login assistido** — sem `oauth_client.json`, o
`iaragon-login` imprime o passo-a-passo completo do Google Cloud
(`application/onboarding`, conteúdo fixado por teste: links diretos
projectcreate / apis/library/drive / auth/branding / auth/clients /
auth/audience, tipo "Desktop app", shape exato do JSON, armadilha dos 7
dias + publicar "In production"). README com o mesmo guia. **Poller reporta
streaks**: `report_trouble` injetado — UMA linha de journal quando uma
sequência de falhas começa (razão verbatim) e UMA na recuperação; nunca
linha-por-retry. A composição escreve o texto acionável no erro na origem
("not logged in — run iaragon-login"; refresh falho com a dica dos 7 dias).

Fase e2e sem credenciais: **fake Drive local** (FFI de teste
`iaragon_fake_drive_ffi`: HTTP/1.1 multi-request keep-alive em porta
efêmera, roteamento e payloads em Gleam). Fato verificado: Google NÃO tem
sandbox/emulador oficial da Drive API. O teste sobe a ÁRVORE REAL
(`start_daemon`) contra ele: httpc real (send injetado redirecionado a
127.0.0.1 — a mesma costura de injeção da produção), parsers reais, FFI de
download streaming real, cliente de upload resumable real (inclusive a
validação googleapis da session URI — o fake devolve Location googleapis e
o send redireciona). Cenário prova as duas direções: arquivo remoto chega
byte a byte no espelho; arquivo criado localmente sobe com os bytes exatos.

Fase validação do bump OTP 29 (sessão 23): revisão da subida do piso para
OTP 29 contra a doc oficial + auditoria de segurança das versões de deps.
Achados: **nenhuma API que o daemon usa mudou** em OTP 29 (file/gen_tcp/
uri_string/unicode/crypto/httpc/os intactos; encoding de nome de arquivo
sem mudança, o decode `unicode:characters_to_list(Path, utf8)` continua
certo); **nenhuma dep Hex tem bump disponível** — as 15 + esqlite/fs + o
compilador Gleam já estão na última estável (nada mais novo para carregar
fix). Verificação empírica no OTP real do piso (baixado do builds.hex.pm,
OTP 29.0.3 / inets 9.7.1): build limpo `--warnings-as-errors` recompilando
o NIF C do esqlite e a dep Erlang `fs` sob os novos diagnósticos default do
OTP 29 (deprecated `catch`, comprehension-rebind) — zero warnings — e suíte
completa (307) verde. Fecha o gap de desenvolver em OTP 27 abaixo do piso 29.
Correção de usuário no `install.sh`: gate `rebar3_new_enough` (≥ 3.27.0,
espelhando o do Gleam) — o instalador exigia OTP ≥ 29 mas aceitava qualquer
rebar3, e rebar3 < 3.27 morre com `rebar_uri:parse undef` em OTP 29
(reproduzido com o 3.19 do apt); rebar3 presente-mas-velho agora cai no
escript oficial sem tocar o do sistema. Nada a corrigir no código; só
toolchain e precisão de doc (o fix do CVE em inets 9.7.1 é OTP 29.0.2+,
mitigado independentemente pelo FFI). Item observado p/ o futuro (OTP 30):
`httpc` fecha `max_connections_open` ilimitado hoje — irrelevante com pool
serial, mas setar explícito se surgir uso concorrente do httpc.

## Sessão 24 (cont.) — revisão profunda de todo o repositório

Três revisores adversariais em paralelo (domínio+aplicação; infraestrutura+
FFIs; scripts+packaging+docs), com verificação própria de cada achado antes
de corrigir. **Corrigidos nesta sessão** (cada um com teste de regressão):

- **CRITICAL — colisão de path materializado**: a extensão de nativo/shortcut
  era aplicada DEPOIS da desambiguação; Doc `notes` + blob `notes.desktop`
  caíam no MESMO path local → sobrescrita local e corrupção remota em
  ping-pong. Agora o nome materializado entra na resolução de paths.
- **HIGH — inferência de rename limitada a Blob**: renomear o `.desktop` de um
  nativo casava o par vanished/fresh (md5 ausente = checagem vazia) e
  renomeava o Google Doc REMOTO, vazando a extensão.
- **HIGH — relógio de retenção da lixeira**: `rename` preserva mtime, então o
  sweep media "última edição do conteúdo", não tempo-na-lixeira — arquivo
  antigo trashado hoje morria no boot seguinte (janela ~zero). `touch_now`
  no destino ao trashar.
- **MED — double-encoding de path nos FFIs do status socket**
  (`binary_to_list`): com `$HOME` acentuado o daemon bindava um socket
  sósia; plugin/tray não achavam e o doctor (igualmente mangleado)
  mascarava. Binário UTF-8 passa como-está; teste fixa o nome no disco.
- **LOW — probe de emblema no scan**: `.iaragon-emblem-probe` remanescente
  não vira mais "conteúdo do usuário" (skip por localização).
- Lote operacional: release `latest` era `--prerelease` (o alias
  `releases/latest` do GitHub o ignora → fast-path prebuilt NUNCA disparava;
  install.sh agora usa o path de TAG); `set -e` suprimido dentro de
  `install_prebuilt` (falha pós-`rm -rf $LIBDIR` seguia e imprimia sucesso —
  agora `|| die`); PKGBUILD não reescrevia o ExecStart da unit do doctor
  (203/EXEC); pre-push tratava `git diff` FALHO como "nada mudou" (agora
  fail-safe); tray saía invisível quando o serviço SNI morria (agora exit 1
  p/ o systemd reiniciar) e vazava zumbis do xdg-open; bundle sem
  LICENSE/NOTICE (compliance Apache na redistribuição do OTP); ERTS por
  glob alfabético; .deb sem Depends/copyright; rpm sem %license; docs
  dessincronizadas (unit "copiada" que nunca foi, 4 FFIs → 6, launchers).

**Residuais: TODOS os MED/LOW acima foram corrigidos na própria sessão 24**
(cada um com teste de regressão, salvo os dois indicados):

- status_board ganhou `ClearStatus` (pool limpa no delete/move) — SyncFailed
  órfão não prende mais o agregado do tray, e o board acompanha o espelho
  vivo em vez de crescer para sempre.
- Pendências do reconciler taggeadas com o pid do pool de despacho; o DOWN
  limpa só as do pool morto — DOWN atrasado não duplica mais arquivo no
  Drive.
- Timer periódico virou `TickRound(generation)` (geração aleatória por
  encarnação): crash não multiplica cadeias — e o `ReconcileNow` do watcher
  NÃO re-arma mais (cada rajada de FS adicionava uma cadeia eterna, pior
  que o cenário de crash do achado original).
- Cache `created_folders` é esvaziado em qualquer erro de upload (id morto
  não envenena mais os retries até o restart). [sem teste dedicado — 3
  linhas, racional no código]
- `record_downloaded` recusa gravar known quando o tamanho no disco diverge
  do remoto (edição na janela rename→record vira conflito preservado, não
  sobrescrita silenciosa).
- Refresh de token: temp de nome ÚNICO por escrita (corrida
  poller×pool×doctor não corrompe mais tokens.json).
- Loopback OAuth aceita em LOOP até o request real (preconnect especulativo
  de browser não trava mais o login; fatia de 2s por conexão muda).
- Watcher usa sends best-effort (reconciler reiniciando não derruba mais a
  cadeia watcher/filespy — não queima o budget de restart).
- `run_command` (gio/emblemas) com timeout de 10s de silêncio — filho
  pendurado não congela mais o pool. [sem teste dedicado — cláusula after]
- Boot: asserts viraram `require()` com UMA linha acionável no journal +
  halt(1); status socket que não binda (path >107 bytes) vira aviso, não
  morte da árvore inteira.
- Doctor: doc honesta ("mostly passive" — refresh grava tokens.json;
  state_db.open garante schema).
- Domínio: edição local do `.desktop` de um Shortcut vira conflito
  NativeLocalEdit (nunca UploadLocal no id do shortcut — livelock); pasta
  renomeada remotamente emite MoveLocal do diretório (sem dir órfão nem
  known com path velho).
- Plugin Dolphin: sweep oportunista de entradas expiradas quando o cache
  passa de 4096 entradas (recompilado e lintado).

**Aberto (decisão de produto, não defeito):** nativo both-created sobrescreve
arquivo local nunca sincronizado sem conflicted-copy (deliberado e testado,
mas a justificativa cobre não-subir, não cobre não-preservar).
