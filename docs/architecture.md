# Arquitetura e decisões de produto

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
