# Overlay de status do iaragon para o Dolphin (KDE)

Plugin `KOverlayIconPlugin` que mostra o estado de sincronização dos
arquivos do espelho (`~/GoogleDrive`) direto no Dolphin:

| Emblema | Significado |
|---|---|
| `vcs-normal` (check) | sincronizado |
| `vcs-update-required` | transferência em andamento |
| `vcs-conflicting` | transferência esgotou os retries (re-tenta na rodada seguinte) |
| (nenhum) | fora do espelho / desconhecido |

O plugin conversa com o daemon pelo socket de status
(`$XDG_RUNTIME_DIR/iaragon.sock`, ou `~/.local/share/iaragon/status.sock`
sem runtime dir) num protocolo de linha: um path absoluto por linha,
uma palavra de status por linha. `getOverlays` nunca bloqueia (contrato
do KIO): as respostas chegam num cache com TTL de 3 s e são anunciadas
via `overlaysChanged` — mudanças de estado aparecem em segundos.

## Compilar e instalar

Dependências (Ubuntu/Kubuntu): `extra-cmake-modules`, `libkf5kio-dev`
(KF5) ou `libkf6kio-dev` (KF6), `qtbase5-dev`/`qt6-base-dev`, `g++`,
`cmake`.

```sh
cd integrations/dolphin
# KF5 (Dolphin do Ubuntu 24.04) — para KF6 troque para -DQT_MAJOR_VERSION=6
cmake -B build -DQT_MAJOR_VERSION=5
cmake --build build
sudo cmake --install build
```

Reinicie o Dolphin (`kquitapp5 dolphin; dolphin &`). Os emblemas usam
nomes que o tema Breeze traz; outros temas de ícones podem variar o
desenho.
