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
  não duplicadas. `test do` roda o login launcher.
- **`dist/iaragon.service`**: template versionado da unit (usa `%h` p/ o
  prefixo padrão). Atenção: o `install.sh` GERA a própria unit (heredoc, path
  absoluto) em vez de copiar este template; `.deb`/`.rpm` carregam cópias
  próprias e o PKGBUILD instala o template com sed no `ExecStart`. Mudou uma
  diretiva → espelhar nos quatro lugares (aviso no cabeçalho do template).
- **Pacotes nativos** (`packaging/`, detalhes em
  [packaging/README.md](../packaging/README.md)): `.deb` (bundle autocontido,
  **construído+`dpkg -i`/run/remove validado** aqui), `.rpm` (`spec`, bundle,
  validar no host RPM), `PKGBUILD` AUR (**build-from-source** dependendo do
  `erlang` da distro — idiomático no rolling e ainda herda updates de OTP via
  pacman). Versão derivada do git (`0.0.<n>+g<sha>`, rolling sem tags).
- **Publicação** (`scripts/publish-release.sh`): sem CI remoto (decisão), o
  mantenedor roda isto num host de build (um por arch) e sobe o tarball
  autocontido para um único release rolling GitHub taggeado `latest` (ponteiro
  de distribuição, NÃO tag de versão) via `gh`. O `install.sh` consome
  `releases/latest/download/…`.
- **Repo apt assinado** (`scripts/publish-apt.sh`, sessão 25): auto-update de
  `.deb` via `apt upgrade` EXISTE — repositório dedicado
  `github.com/<owner>/iaragon-apt` servido por raw.githubusercontent.com
  (o `Filename:` do apt é relativo à raiz do archive, então GitHub Releases
  não serve; Pages é opcional/cosmético). Repo SEPARADO de propósito: cada
  publish commita um `.deb` de ~65 MB e git nunca esquece — no repo de código
  isso incharia todo clone para sempre; no dedicado o peso fica em quarentena
  e a história pode ser squashada sem tocar no código (clientes apt leem só a
  ponta). Assinatura ed25519 com chave dedicada (GNUPGHOME próprio, fora de
  qualquer repo; pública versionada como `iaragon-archive-keyring.gpg` na
  raiz do iaragon-apt junto com o snippet deb822 de instalação). O script
  builda o `.deb`, poda o pool (`IARAGON_APT_KEEP`, default 2 — limite rígido
  do GitHub é 100 MB/arquivo, o bundle tem ~65), regenera
  Packages/Release, assina (InRelease + Release.gpg, SHA512) e pusha.
  Validado e2e nesta máquina: `apt update` reconhece a assinatura,
  `apt install iaragon` baixa 67 MB do repo remoto, serviço volta, doctor
  verde. Cache do raw: ~5 min entre o push e os clientes verem.
  **Auto-update de `.rpm`** segue exigindo repo yum assinado (mesma receita,
  `createrepo_c`, não montado).
- Fato verificado: `gleam export erlang-shipment` produz um release
  autocontido; `entrypoint.sh run` execa `erl -pa "$BASE"/*/ebin -eval
  "iaragon@@main:run(iaragon)" -noshell`. E2e validado clonando `main`,
  compilando e rodando ambos launchers.
