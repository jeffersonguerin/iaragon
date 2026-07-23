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
