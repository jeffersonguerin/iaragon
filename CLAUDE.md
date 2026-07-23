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


## Documentação (`docs/`)

O log completo do projeto vive em `docs/`, dividido por tipo — consultar
ANTES de mexer na área correspondente:

| Arquivo | Conteúdo |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Camadas, atores, núcleo de reconciliação, decisões de produto |
| [docs/drive-api.md](docs/drive-api.md) | Fatos verificados da Drive API v3 (armadilhas, quotas, projeções) |
| [docs/data-safety.md](docs/data-safety.md) | Válvulas contra perda de dados (mass-delete, lixeira local) |
| [docs/security-log.md](docs/security-log.md) | Hardening, rodadas de pentest, revisões de credencial |
| [docs/performance.md](docs/performance.md) | Medições de escala/runtime e otimizações |
| [docs/development-log.md](docs/development-log.md) | Histórico cronológico das fases de feature |
| [docs/distribution.md](docs/distribution.md) | Instalador curl, Formula Homebrew, units systemd |

## Arquitetura (mapa mínimo — detalhes em docs/architecture.md)

Árvore de supervisão (OneForOne):
`state_owner` (índice fileId↔path persistido em SQLite) · `local_watcher`
(inotify/polling → `ReconcileNow`) · `remote_poller` (Changes API, semeia o
espelho no 1º ciclo) · `reconciler` (three-way diff puro + despacho) ·
`transfer_pool` (upload/download/trash/move, serial) · `status_board` +
socket de status.

Invariantes que NUNCA podem quebrar:
- `reconcile` é puro, com **matching exaustivo sem `_` no nível de
  presença** — caso não tratado deve ser erro de compilação.
- Settle de upload/move atualiza o modelo remoto NA HORA (esperar o poll
  abriria janela de auto-deleção).
- Deleções passam pela válvula de mass-delete e a de blob local vai para
  `.iaragon-trash/` — nunca unlink direto de conteúdo do usuário.
- Identidade remota é `fileId`, nunca path; todo destino de escrita local
  passa por `sanitize_segment`.
- Nativo do Google NUNCA vira `UploadLocal` (download-only por política).

## Armadilhas do Drive — resumo (fatos completos em docs/drive-api.md)

- int64 (`size` etc.) chega como STRING no JSON; md5 só em blobs.
- `changes.list`: trashed chega como mudança normal (`trashed=true`);
  `removed=true` sem `file` = deleção/perda de acesso; token rejeitado
  (400/410) → re-seed, nunca retry cego.
- Upload resumable: chunks múltiplos de 256 KB; 0-byte finaliza com
  `bytes */0` (convenção das libs do Google).
- OAuth: app em "Testing" mata o refresh token em 7 dias — publicar
  "In production".
- Backoff exponencial com jitter é a ÚNICA recomendação oficial p/ 403/429.

## Estado do projeto

As 4 fases do roadmap (download-only → upload-only → bidirecional →
overlays) estão ENTREGUES, com hardening (3 rodadas de pentest), válvulas
de segurança de dados, doctor, instalador e benchmarks. **Backlog zerado**
— trabalho novo = decisão de produto nova (candidatos conhecidos: shared
drives, sync seletivo, backoff por-arquivo p/ `downloadRestrictedForRevision`).
Histórico e residuais documentados em `docs/`.

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
  verde — a regra "todo commit verde" agora é mecânica. O `pre-push`
  (sessão 21) recusa push com `gleam build --warnings-as-errors` sujo —
  em Gleam o compilador É o linter (não existe linter externo; format é
  só formatação), e warnings re-emitem até para módulo em cache (validado
  empiricamente), então nada sobe com warning. No pre-push e não no
  pre-commit por decisão do usuário: ciclo de commit barato, gate na
  saída. Bypass de emergência: `--no-verify`. O hook NÃO exporta o PATH do OTP (exigir isso
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
  PULADO).
- **LSPs das demais linguagens do repo (sessão 21)**: mesmo padrão de
  plugin, um por servidor — `.claude/skills/erlang-lsp/` (ELP,
  `elp server`, p/ os FFIs `.erl`/`.hrl`; binário estático nos releases
  do WhatsApp/erlang-language-platform — o GitHub é 403 atrás do proxy
  destes containers, instalar na máquina local), `clangd-lsp/` (plugin
  Dolphin C++; `apt install clangd`; `compile_commands.json` via
  `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON` p/ resolução completa de
  includes) e `bash-lsp/` (`npm i -g bash-language-server` +
  `shellcheck` p/ diagnostics; cobre `.sh` — os hooks sem extensão ficam
  de fora do mapeamento). Binário ausente = servidor pulado em silêncio,
  então as configs são inofensivas onde a ferramenta não existe. clangd
  e bash-language-server validados com um `initialize` LSP real neste
  container. Ruby (1 arquivo, a Formula) deliberadamente sem LSP.
