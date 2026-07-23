# Performance e escala

Medições feitas ANTES de otimizar (eprof nos BEAMs; FFI de bench para pico
de memória binária). Os benchmarks vivem em `test/iaragon/scale/` e
`test/iaragon/perf/` e imprimem os números a cada run da suíte; os asserts
são canários de propriedade, não micro-tempos.

Fase escala (medido ANTES de otimizar; eprof nos BEAMs): 100k arquivos
(1000 pastas × 100) — `resolve_paths` 3,1 s, `reconcile_all` steady state
3,1 s, state_db ~44 µs/put (seed 100k ≈ 4,5 s única vez; write-through
irrelevante). Perfil: ~30% do resolve era a dança de codepoints do
`sanitize_segment` em nomes LIMPOS; 60% do reconcile eram 800k
`dict.insert`, metade DUPLICADA (reconcile_all e infer_local_renames
construíam os mesmos dois índices de 100k). Otimizações
comportamento-preservantes: **fast path por scan de bytes** no sanitize
(`/`, controles e DEL são single-byte em UTF-8 — nome limpo não aloca
nada); **índices compartilhados** via `infer_renames_with` interno (o
público `infer_local_renames` continua construindo os seus); **early-exit
sem vanished** (nenhum known sumido localmente = nenhum rename possível =
toda rodada steady-state — pula sets de paths e mapas de assinatura).
Resultado: 1,4 s / 1,5 s (2× cada). `test/iaragon/scale/scale_test.gleam`
fica de canário (100k, imprime wall time, trava correção — steady state =
zero decisões). Sem O(n²) acidental; o custo restante é intrínseco de
mapas funcionais nesse tamanho e aceitável (rodada de 30 s a 100k ≈ <10%
de um core; Drives típicos ≤ 10k são triviais).


Fase perf de runtime (sessão 21, continuação): benchmarks do que a fase de
escala NÃO cobria — o runtime. FFI de teste `iaragon_bench_ffi`
(`peak_binary_memory`: sampler do pico de `erlang:memory(binary)` durante um
closure — binários grandes são refc/off-heap, é onde conteúdo de arquivo
aparece; `deep_size_bytes`: `erts_debug:size` do termo). Medido:
- **local_scan** 10k arquivos reais: ~200-800 ms (I/O; canário <10 s) —
  a rodada de 30 s comporta o scan com folga até ~100k.
- **Pipeline inteiro** (`start_daemon` real contra o fake Drive): 1000
  arquivos semeados → espelho convergido em ~1,3 s ≈ **1,3 ms/arquivo**
  (pool serial sobre loopback; primeiro sync de 100k ≈ 2-3 min de overhead
  de pipeline — rede real domina).
- **Modelo remoto a 100k**: 23 MiB de heap (dict de RemoteSighting medido
  com erts_debug) — leve; canário <500 MiB.
- **Download streaming** 32 MiB: pico binário +0 MiB (o `{stream, path}`
  não segura payload no cliente) — fixado por assert.
- **Upload resumable** 32 MiB (chunks 10 MiB): pico ≈ 2 chunks, limitado
  pelo chunk e nunca pelo arquivo — fixado por assert.
- **ACHADO CORRIGIDO (TDD): md5 slurpava o arquivo inteiro** —
  `hash_mirror_file` fazia `read_bits` do arquivo todo (pico +32 MiB num
  arquivo de 32 MiB; um blob de 5 GB nunca-sincado = 5 GB de heap no
  momento em que o reconciler hasheia gêmeos). Reescrito em janelas de
  1 MiB sobre o MESMO `chunked_read` do upload + hasher incremental do
  gleam_crypto (`new_hasher`/`hash_chunk`/`digest`); pico agora +1 MiB
  (uma janela), independente do tamanho. Teste de perf trava a
  propriedade (pico < 4 MiB).
Os benchmarks vivem em `test/iaragon/perf/` e imprimem os números a cada
run; asserts são canários generosos (propriedades, não micro-tempos).
