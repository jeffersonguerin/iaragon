# Distribuição e instalação

Os caminhos de instalação, o release autocontido, o template systemd e as
decisões/princípios do instalador.

## Release autocontido (relocável) — `scripts/build-release.sh`

O maior atrito histórico era "instalar = compilar do fonte" (exige toolchain
Erlang/OTP ≥ 29 + Gleam + rebar3 + gcc/make). O `build-release.sh` produz um
**bundle autocontido**: um tarball que roda em qualquer Linux compatível SEM
Erlang/Gleam/rebar3/gcc no alvo — a sensação de "baixei algo e rodou".

Layout do bundle:

```
iaragon-<os>-<arch>/
  otp/            # ERTS + lib OTP + scripts (a BEAM inteira, embutida)
  app/*/ebin      # a app Gleam compilada (todas as deps + NIFs esqlite/fs)
  bin/iaragon           # daemon  (erl bundleado -eval iaragon@@main:run)
  bin/iaragon-login     # login OAuth
  bin/iaragon-doctor    # health check
```

**Por que é relocável (fato verificado no `erl` do OTP 29, sessão 24):** o
`otp/bin/erl` bundleado deriva o `ROOTDIR` subindo a partir do próprio caminho
até achar um irmão `erts-<vsn>` — a função `find_rootdir`, cujo próprio
comentário diz *"It is likely that the files have been copied or moved"*. Logo,
invocar o erl bundleado pelo caminho-de-dentro-do-bundle faz ele achar o OTP
bundleado — sem passo de install, sem prefixo fixo, sem poluir o PATH. Os
launchers ainda exportam `ERL_ROOTDIR` como cinto-e-suspensório. **Provado
empiricamente**: num host com OTP 25 no sistema, o bundle roda seu OTP 29
(`code:root_dir()` aponta pra dentro do bundle) e continua rodando depois de
movido de diretório.

**Restrição que o empacotador carrega:** ERTS e os NIFs (esqlite, fs) são
código nativo compilado contra a libc/arch da MÁQUINA DE BUILD. O tarball é
portanto por-(os, arch) e só roda em alvo com libc compatível-ou-mais-nova —
buildar na glibc MAIS ANTIGA que se pretende suportar. O nome do arquivo grava
a arch; a baseline de OS é a do builder e cabe ao empacotador rastreá-la.
`inotify-tools` NÃO é bundleado (é um executável externo que o filespy/fs
invoca); sem ele o daemon cai no watcher por polling (polly) — dep opcional de
runtime, documentada, nunca um bloqueio.

## Caminhos de instalação

Dois caminhos de instalação (curl e Homebrew), o template systemd e as
decisões/princípios do instalador.

O `install.sh` instala três launchers (`iaragon`, `iaragon-login`,
`iaragon-doctor`) — por padrão a partir do release autocontido; no fallback
source, compilando o shipment (`gleam export erlang-shipment` →
`build/erlang-shipment/` com `entrypoint.sh`; daemon = `entrypoint.sh run`,
login = `erl -pa …/*/ebin -noshell -eval 'iaragon@login:main(), halt(0)'`).
O módulo Gleam `iaragon/login` compila para o átomo Erlang `iaragon@login`;
o `main/0` volta Nil e o login trata o erro (sai 0 mesmo sem
`oauth_client.json`), o que dá um smoke test barato.

- **`install.sh`** (`curl -sSL …/install.sh | sh`): POSIX sh, daemon
  **por-usuário** sob `~/.local`. **Dois modos:**
  - **Prebuilt (padrão)**: baixa o tarball autocontido (`releases/latest/
    download/iaragon-linux-<arch>.tar.gz`), extrai em `$LIBDIR` (que passa a
    conter `otp/ app/ bin/`) e instala launchers finos em `$BINDIR` que só
    `exec` o launcher do bundle — **zero toolchain no alvo**. É o que dá a
    sensação de "baixei um programa". `release_arch` mapeia x86_64/aarch64;
    arch não suportada, download ou unpack falho → cai no source. Knobs:
    `IARAGON_FROM_SOURCE=1` (pula o prebuilt), `IARAGON_RELEASE_BASE` (base
    URL — aceita `file://` p/ teste/self-host). Validado e2e servindo o
    tarball por `file://` num host com só OTP 25 no sistema: o launcher
    instalado sobe o OTP 29 do bundle.
  - **Source (fallback)**: compila do fonte. Princípios decididos:
  - **Não conflita com o toolchain existente**: cada dependência já presente
    (por QUALQUER meio — apt, brew, kerl, asdf, build manual) é detectada e
    MANTIDA; nada é reinstalado nem duplicado. Só o que falta é instalado. A
    checagem é o primeiro passo de cada `ensure_*` (`have`/`otp_ok`).
  - **Método preservado**: as faltantes vêm do ÚNICO gerenciador detectado
    (apt→tudo do apt, brew→tudo do brew). Download direto (binário do Gleam,
    escript do rebar3) SÓ quando o gerenciador não empacota (Gleam não está em
    apt/dnf/zypper), e o script anuncia o fallback. `IARAGON_PM` fixa o
    gerenciador p/ casar com o toolchain do usuário.
  - **Transparente**: imprime um PLANO (presente × instalar, e como) antes de
    agir, ecoa o comando exato por pacote, e um resumo no fim.
  - **Guard de OTP ≥ 29**: Erlang mais velho não é "consertado" — o script
    PARA com instruções (kerl/asdf ou tarball builds.hex.pm), senão o daemon
    crasharia no primeiro uso.
  - Instala unit **systemd de usuário** (`~/.config/systemd/user/
    iaragon.service`, `Restart=on-failure` + `RestartSec=5`); o dir do `erl` é
    embutido no PATH dos launchers (funciona sob o PATH mínimo do systemd
    `--user`).
  - **Guarda anti-crash-loop** (`StartLimitIntervalSec=300` +
    `StartLimitBurst=5`): crash transitório se recupera sozinho, mas um daemon
    que falha de forma persistente (5× em 5 min) para em estado `failed` em vez
    de reiniciar para sempre — não martela a Drive API nem enterra a falha real
    no journal; o `iaragon-doctor` e `systemctl --user status` expõem o estado.
    Autocura não pode virar loop que esconde defeito.
  - Hardening do instalador (revisão de segurança/robustez por subagente
    adversarial — sem CRITICAL; negativos confirmados: sem `eval`/injeção,
    sudo com escopo só nos installs, traps limpas, truncamento seguro):
    toda a lógica imperativa vive em `main()` chamada na ÚLTIMA linha — um
    `curl | sh` truncado nunca executa script parcial; guard de `IARAGON_PREFIX`
    (absoluto, ≠ `/`, charset `[A-Za-z0-9._/-]` — fecha injeção via heredoc nos
    launchers/unit) antes do `rm -rf "$LIBDIR"`; downloads via temp+`mv` (sem
    artefato parcial); modelo de confiança documentado (pacotes = assinatura do
    gerenciador; Gleam/rebar3 = HTTPS de release oficial no GitHub, TLS, sem
    checksum fixado — quem quiser mais instala à mão e eles são detectados).
    Achados corrigidos: **Erlang presente-mas-antigo NÃO é sobrescrito** (não
    duplica o toolchain do usuário — vai direto à orientação de upgrade);
    **piso de versão do Gleam** (>= 1.17, mesmo gate do OTP — presente-mas-antigo
    para com mensagem clara em vez de `gleam export` confuso); `REBAR3_VERSION`
    opcional p/ pin reprodutível (default latest); `IARAGON_PM` validado contra
    o conjunto conhecido; idiom frágil `A && B || C` do compilador C virou `if`.
- **`Formula/iaragon.rb`** (Homebrew): fórmula **HEAD-only** (rolling release,
  sem tags → `brew install --HEAD`). Via Homebrew TODO o toolchain vem do
  Homebrew (`depends_on` gleam/rebar3 build + erlang runtime + `on_linux
  depends_on "inotify-tools"`); instalações brew já existentes são reusadas,
  não duplicadas. `test do` roda o login launcher. **Validada e2e no Linux
  (sessão 25, Homebrew 6 / Linuxbrew)**, com dois fatos pagos em bug:
  `Pathname#write` cria launcher **0644** — sem o `chmod 0755` explícito todo
  uso morre em "Permission denied" (o install chega a reportar "Empty
  installation" na primeira tentativa); e `brew reinstall` NÃO aceita
  `--HEAD` no brew 6 — atualizar é `brew uninstall` + `brew install --HEAD`.
  Supervisão com paridade aos pacotes nativos via `service do` block:
  `brew services start` gera unit systemd de usuário no Linux
  (`homebrew.iaragon.service`, validado: daemon sobe, socket responde,
  doctor verde), launchd no macOS. Tap direto no repo principal funciona
  (`brew tap <owner>/iaragon https://github.com/<owner>/iaragon`). Atenção
  operacional: brew e `.deb` instalados juntos = risco de DOIS daemons no
  mesmo espelho — manter só um serviço ativo.
- **`dist/iaragon.service`**: template versionado da unit (usa `%h` p/ o
  prefixo padrão). Atenção: o `install.sh` GERA a própria unit (heredoc, path
  absoluto) em vez de copiar este template; `.deb`/`.rpm` carregam cópias
  próprias e o PKGBUILD instala o template com sed no `ExecStart`. Mudou uma
  diretiva → espelhar nos quatro lugares (aviso no cabeçalho do template).
- **Publicação** (`scripts/publish-release.sh`): sem CI remoto (decisão), o
  mantenedor roda isto num host de build (um por arch) e sobe o tarball
  autocontido para um único release rolling GitHub taggeado `latest` (ponteiro
  de distribuição, NÃO tag de versão) via `gh`. O `install.sh` consome
  `releases/latest/download/…`.
- **Decisão de produto (sessão 26): brew é O canal de pacote — "uma coisa
  bem feita em vez de várias mais-ou-menos".** O que mudou:
  - **Aposentados**: os pacotes nativos (`packaging/` — `.deb`/`.rpm`/AUR,
    removidos do repo; a história do git guarda as receitas) e o **repo apt
    assinado** da sessão 25 (`iaragon-apt`, arquivado no GitHub com nota de
    descontinuação; `scripts/publish-apt.sh` removido). O canal apt foi
    validado e2e antes de aposentar — funcionava; morreu por custo de
    manutenção (segundo repositório + chave + metadados) frente a zero
    clientes reais, não por defeito.
  - **Mantidos**: a Formula (canal primário, agora com `stable` na tag
    `v1.0.0` + sha256 pinado e `--HEAD` rolling; supervisão via
    `brew services`) e o **curl/install.sh como compatibilidade** — o release
    autocontido rolling continua publicado, SEM assinatura (confiança =
    TLS + GitHub, como o cabeçalho do install.sh documenta). O gate de
    release do pre-push continua: ele testa o produto (o bundle roda no
    próprio OTP), não o canal.
  - Racional do trade-off de segurança: o apt era o único canal com trava
    criptográfica própria; o `stable` do brew recupera integridade via
    sha256 do tarball da tag; `--HEAD` e curl confiam no git/TLS.
- Fato verificado: `gleam export erlang-shipment` produz um release
  autocontido; `entrypoint.sh run` execa `erl -pa "$BASE"/*/ebin -eval
  "iaragon@@main:run(iaragon)" -noshell`. E2e validado clonando `main`,
  compilando e rodando ambos launchers.

## Versionamento odômetro automático (sessão 28)

O `pre-push` versiona cada push que atualiza `main`: computa a próxima
`vX.Y.Z` a partir da maior tag existente, cria a tag anotada no commit
pushado e a envia junto (`--no-verify` — o conteúdo acabou de passar pelos
gates; push só-de-tags não re-executa os gates, guarda de recursão).
Rodas: **patch 0-9, minor 0-99**, carry ao estourar — `0.5.9`+patch→`0.6.0`,
`0.99.9`+patch→`1.0.0`, `1.99.x`+minor→`2.0.0`; o **major nunca anda
sozinho**, só por carry (num rolling a versão é hodômetro, não promessa de
compatibilidade). Critério mecânico de roda: push que muda `src/` = minor
(comportamento do daemon); resto = patch. Idempotente (commit já taggeado
não ganha outra) e nunca falha o push por contabilidade de versão (tag que
não subiu fica local com aviso). Aritmética autotestável sem push:
`.githooks/pre-push --next-version 1.99.9 patch` → `2.0.0` (validado com
tabela de 8 casos, carry duplo incluído). O `stable` da Formula NÃO segue as
tags automaticamente — atualizar o pin (url+sha256) segue decisão deliberada.

Tags de canal `stable`/`latest` (sessão 28, na sequência do odômetro): além
da `vX.Y.Z` imutável, o pre-push mantém dois ponteiros móveis (forçados —
mover é a semântica; consumo exige `git fetch --tags --force`):
- **`latest`** → o commit mais novo de `main`, deliberadamente o MESMO nome
  do release rolling que o install.sh consome — "latest" significa uma coisa
  só em todo lugar. E o ASSET acompanha: quando o gate 3 reconstrói o bundle
  (push que muda insumos do release), o pre-push publica ESSE bundle — que
  acabou de passar no smoke — via `gh release upload --clobber` (token do
  mesmo credential helper que os pushes de tag já usam). Push só-de-docs
  pula o gate 3 e mantém o asset, que é idêntico por construção (o bundle
  não carrega docs). Sem gh/token o push NUNCA falha por isso — avisa e o
  `publish-release.sh` manual continua sendo o fallback.
- **`stable`** → o commit da tag pinada no `stable` block da Formula (a
  Formula é a fonte de verdade do canal estável); o hook lê o pin do commit
  pushado e alinha a tag mecanicamente — mover o pin move a tag no push
  seguinte. Mover o pin segue decisão deliberada.
O nome `canary` existiu por um push (v1.0.2) e foi renomeado para `latest`
na sequência, a pedido — unificação com o nome que o install.sh já usava.
