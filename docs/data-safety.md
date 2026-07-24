# Segurança de dados — válvulas

O que impede uma rodada de sync de destruir um dos lados. Desenho comparado
com rclone bisync, Drive for Desktop, Dropbox e Syncthing (docs oficiais).

Pesquisa comparativa (rclone bisync, Drive for Desktop, Dropbox, Syncthing —
docs oficiais) identificou 3 válvulas "table stakes" que faltavam; as 3
entraram com TDD:
- **Válvula de mass-delete** (`domain/safety.judge_mass_deletion`): rodada
  que deletaria ≥10 arquivos E >50% dos knowns tem SÓ as deleções suprimidas
  (o resto flui); uma linha de journal por streak com a causa provável
  (espelho desmontado / listing vazio) e o override
  `IARAGON_ALLOW_MASS_DELETE=1` (o `--force` do bisync, como env). Cobre os
  DOIS desastres: scan vazio (espelho desmontado → mass trash remoto) e
  seed falsamente vazio (→ mass wipe local, irrecuperável). bisync aborta
  em >50% por default pelo mesmo motivo; piso absoluto de 10 deixa
  espelhos/cleanups pequenos em paz. Renames de pasta grande NÃO disparam
  (viram Move*, não delete+create — só os ambíguos caem no delete).
- **Scan falho pula a rodada** (streak de report_trouble) em vez de crashar
  o reconciler — disco ilegível queimava o restart budget (10/30s) até
  derrubar o daemon inteiro.
- **Lixeira local** (`fs/local_trash`): DeleteLocal de BLOB move para
  `.iaragon-trash/` DENTRO do espelho (mesmo FS = rename atômico; padrão
  .stversions/.dropbox.cache/--backup-dir — nenhuma ferramenta madura
  responde a delete remoto com unlink seco), preservando o path relativo,
  com variantes numeradas em colisão. Falha no move = mantém known,
  re-tenta. Scan pula o dir por LOCALIZAÇÃO (como `.iaragon-partial/`).
  Retenção de 30 dias varrida UMA vez no boot (nunca no caminho do sync).
  Links `.desktop` gerados e dirs vazios seguem delete direto (não são
  conteúdo do usuário). O reconciler ganhou `report_trouble` +
  `allow_mass_deletion` no config; `start_daemon` ganhou o parâmetro.
- **Path UTF-8 nos FFIs** (sessão 22, achado em uso real contra um Drive em
  português): `binary_to_list/1` numa string do Gleam devolve os BYTES da
  UTF-8, e com `native_name_encoding = utf8` o Erlang relê esses bytes como
  codepoints — "ç" (`0xC3 0xA7`) vira "Ã§". No download o FFI gravava o
  parcial num nome sósia corrompido, o `rename` do lado Gleam procurava o
  nome certo, não achava, e **o arquivo nunca chegava ao espelho** — falha
  silenciosa, com o parcial órfão acumulando em `.iaragon-partial/`. O
  espelho ficava incompleto sem nada reclamar, que é a pior forma de perda:
  o usuário acredita que está sincronizado. O mesmo defeito estava no
  `iaragon_file_ffi` (upload não abriria arquivo acentuado). Corrigido com
  `unicode:characters_to_list(Path, utf8)` nos dois, com fallback para os
  bytes crus quando o path não é UTF-8 válido (um espelho pode conter
  qualquer sequência de bytes). Coberto por teste nos dois sentidos.
  Só escapou até aqui porque a suíte usava nomes ASCII.

Trilha de auditoria (sessão 27): as ações destrutivas e em massa agora
deixam registro no journal — a lacuna que tornou a investigação da lixeira
esvaziada uma reconstrução forense (o daemon tinha 2 linhas de log em horas
de operação, enquanto ~190 entradas de state sumiam em silêncio). Dois
mecanismos: (1) `decision.describe_workload` (puro, no domínio) resume cada
rodada que decidiu trabalho em contagens por categoria ("round: downloads 2,
forgotten 190") via `report_activity` injetado no reconciler — rodada sem
trabalho fica MUDA, então o regime estacionário de 30 s não polui o journal;
(2) o `sweep` da lixeira devolve os paths que destruiu (relativos, ordenados)
e o boot loga um por linha — o único registro que sobrevive à destruição.
Coberto por teste nas três camadas (domínio puro, sweep real em disco,
comportamento do ator com subject injetado).
