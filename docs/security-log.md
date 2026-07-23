# Log de segurança

Hardening, rodadas de pentest e revisões de credencial — cada achado foi
verificado por leitura antes do fix e cada fix entrou com TDD. Os negativos
verificados (o que provamos NÃO ser vulnerabilidade) estão registrados junto
de cada rodada. Modelo de ameaça das credenciais: a fronteira é o modelo
Unix de usuário (dir 0700 + arquivos 0600); processo malicioso rodando como
o MESMO usuário lê 0600 por definição — o mesmo modelo de gcloud/gh/rclone/
Drive for Desktop.

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


Fase revisão final de credenciais (sessão 20): resposta ao "o que protege o
JSON do OAuth de um serviço malicioso?" — a fronteira é o modelo Unix de
usuário: `~/.config/iaragon` 0700 + `tokens.json` 0600 (temp+rename) bloqueiam
qualquer OUTRO UID (inclusive contas de serviço); processo malicioso rodando
COMO O MESMO usuário lê 0600 por definição — mesmo modelo de gcloud/gh/rclone/
Drive for Desktop (keyring não muda isso num desktop destravado). Achado
corrigido (TDD): **janela pré-primeiro-login** — só o `save_tokens` apertava o
dir; antes do primeiro login concluído (ou daemon rodando sem login) o dir
criado pelo usuário ficava no umask default (0755) com `oauth_client.json`
0644 legível por outros UIDs. `client_store.protect_config_dir` (dir 0700 +
client 0600 se existir) chamado nos DOIS pontos de entrada: início do
`run_login` e boot do daemon. Negativo verificado: injeção de escape ANSI via
`MalformedRedirect(target)` impressa no terminal do login NÃO é explorável —
`string.inspect` escapa controle (`\u{001B}`), confirmado empiricamente.
Reconfirmados nesta passada: segredos só em corpo POST HTTPS (nunca query),
erros OAuth sem payload, loopback 127.0.0.1 one-shot com packet_size + state
CSRF + PKCE S256 (verifier nunca sai do processo; roubo do code é inútil sem
ele), clamp de expires_in, temp do token dentro de dir já-0700.
