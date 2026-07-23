# Google Drive API — fatos verificados

Tudo aqui foi verificado na documentação oficial (datas anotadas). Regra do
projeto: **não inventar APIs/endpoints** — na dúvida, re-verificar na doc e
registrar aqui.

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


Fatos de API que os testes fixam: `size` e demais int64 chegam como STRING no
JSON do Drive; `changes.list` e `files.list` recebem `fields` com a projeção
exata usada no parser (incl. `shortcutDetails(targetId)`); um redirect OAuth sem `code`/`error` é malformado, e
state errado invalida qualquer resultado; httpc `{stream, path}` faz append
(ver FFI); md5 local em hex minúsculo como o Drive reporta.

Re-verificação da Drive API (docs oficiais, 2026-07):
- **`downloadRestrictedForRevision`** (GA jul/2025): dono/organizador pode
  restringir download até p/ writers — `alt=media` pode falhar PERMANENTE
  em arquivo legível. Hoje: retry 4x + re-despacho por rodada (SyncFailed
  visível). RESIDUAL documentado: sem backoff por-arquivo, um arquivo
  restrito custa ~4 requests/rodada p/ sempre. Fix seria classificar o 403
  por reason e marcar o file_id como unsyncable — decisão de produto nova.
- **0-byte `*/0` rebaixado de residual**: a client library do Google
  (google-resumable-media-python, `_EMPTY_RANGE_TEMPLATE`) faz EXATAMENTE
  `bytes */0` com corpo vazio — nossa escolha é a convenção do próprio
  Google, não invenção.
- **Quota 2026**: além dos 325k units/min/usuário e 1M/min/projeto,
  há teto DIÁRIO de 400M units/projeto e **1 TB/dia de egress** — limita o
  primeiro sync de Drives gigantes (>1 TB não desce num dia).
- **acknowledgeAbuse=true incondicional**: sem erro documentado p/ arquivo
  não-abusivo (comportamento p/ não-dono é indocumentado); prática do
  rclone (`--drive-acknowledge-abuse`) confirma seguro. Mantido.
- **Google Vids**: só baixa via `files.download` (LRO novo), `alt=media`
  falha — mas Vids é `google-apps.*` sem export de documento → já
  materializa como LINK em qualquer política (negativo verificado, nada a
  fazer).
- **Retry-After**: doc oficial recomenda SÓ backoff exponencial (grep no
  HTML: zero menções) — nosso backoff+jitter já é exatamente o recomendado.
- **Refresh 7 dias em Testing**: reconfirmado em 2 páginas oficiais;
  produção unverified tem warning + cap de 100 novos usuários, SEM
  expiração de token.
- **Events API (GA mai/2025)**: alternativa push ao polling de changes —
  candidato futuro, polling continua suportado sem mudanças.
