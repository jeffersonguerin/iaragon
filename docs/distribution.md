# Distribuição e instalação

Dois caminhos de instalação (curl e Homebrew), o template systemd e as
decisões/princípios do instalador.

Dois caminhos de instalação, ambos compilando o release Erlang precompilado
(`gleam export erlang-shipment` → `build/erlang-shipment/` com `entrypoint.sh`)
e instalando dois launchers: `iaragon` (daemon = `entrypoint.sh run`) e
`iaragon-login` (`erl -pa …/*/ebin -noshell -eval 'iaragon@login:main(),
halt(0)'`). O módulo Gleam `iaragon/login` compila para o átomo Erlang
`iaragon@login`; o `main/0` volta Nil e o login trata o erro (sai 0 mesmo sem
`oauth_client.json`), o que dá um smoke test barato.

- **`install.sh`** (`curl -sSL …/install.sh | sh`): POSIX sh, daemon
  **por-usuário** sob `~/.local`. Princípios decididos:
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
    iaragon.service`, `Restart=on-failure`); o dir do `erl` é embutido no PATH
    dos launchers (funciona sob o PATH mínimo do systemd `--user`).
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
  prefixo padrão; o instalador reescreve o `ExecStart` p/ prefixo custom).
- Fato verificado: `gleam export erlang-shipment` produz um release
  autocontido; `entrypoint.sh run` execa `erl -pa "$BASE"/*/ebin -eval
  "iaragon@@main:run(iaragon)" -noshell`. E2e validado clonando `main`,
  compilando e rodando ambos launchers.
