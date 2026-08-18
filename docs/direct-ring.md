# Direct SHM: контракт, варианты и методика оптимизации

## Область измерения

Этот этап рассматривает только путь

```text
producer -> shared-memory ring -> consumer
```

Сеть, `sender` и `receiver` в эти сравнения не входят. Изменения SHM layout
должны сохранять их компилируемость, но сетевой профиль не используется как
критерий выбора реализации очереди.

Локальный стенд отвечает на два вопроса:

1. сколько стоит обычная передача ownership между двумя pinned-процессами;
2. какую работу выполняют hot loops по данным PMU и ассемблера.

Дальний хвост на ноутбуке фиксируется, но не оптимизируется как свойство
очереди. В синхронном четырёхсекундном прогоне на каждом CPU `4`–`7` произошло
по 534 thermal interrupts при нулевых context switches и migrations. В
per-message CSV видны серии вида `36.9 -> 33.1 -> ... -> 6.0 us`: consumer был
остановлен, затем последовательно разгребал накопившиеся сообщения. Такой шум
нельзя надёжно отделить от P99.99 алгоритма без целевого серверного железа.

## Целевой контракт

Текущий direct-кейс — bounded SPSC:

- один producer и один consumer;
- число слотов — степень двойки;
- producer резервирует слот и строит сообщение непосредственно в SHM;
- release-store publication sequence передаёт слот consumer;
- consumer получает immutable view и обязан вызвать `commit()` до следующего
  обращения producer к этому слоту;
- при полной очереди producer не ждёт и отбрасывает новое сообщение;
- `live_edge()` позволяет позднему consumer начать с текущего края.

Контракт `reserve -> publish` / `acquire -> commit` делает payload обычной
памятью без data race: одновременно слотом владеет только одна сторона. Это и
есть end-to-end zero-copy внутри direct SHM — промежуточного frame buffer и
`memcpy` между producer/consumer нет.

## Рассмотренные семейства

| Семейство | Представитель | Что проверяем |
|---|---|---|
| Overwrite snapshot | исходный `shm::Ring` | Позволяет независимых readers, но корректный overwrite требует атомарного snapshot и копирования payload. Оставлен как regression baseline. |
| Shared head/tail | `experimental::CursorRing` | Классический SPSC с padded cursors и cached чужим индексом; добавлен честный zero-copy API. |
| Per-slot generation | `shm::spsc::SequenceRing` | Каждый слот чередует producer-owned и consumer-owned generation; production default. |
| Batched reader cursor | серия `cached` | Producer перечитывает общий read cursor только на границе capacity. |
| Handshake-only generation | серия `lean` | Не обновляет глобальный write cursor после каждой публикации; late attach не поддерживается. |
| Split metadata/payload | `experimental::SplitPaddedSequenceRing` и `SplitDenseSequenceRing` | Проверяет control working set, false sharing и TLB при разных capacity. |
| Bulk/burst | benchmark-only направление | Амортизирует coordination на пачку, но меняет latency/throughput contract. |

Эти варианты соответствуют основным практическим направлениям:

- cached head/tail и разнесение shared cursors описаны в
  [SPSC Queue](https://rigtorp.se/ringbuffer/);
- sequence/gating и preallocated entries — в
  [LMAX Disruptor](https://lmax-exchange.github.io/disruptor/user-guide/);
- bulk, burst и трёхфазный zero-copy reserve/copy/finish — в
  [DPDK Ring Library](https://doc.dpdk.org/guides/prog_guide/ring_lib.html);
- различие overwrite и producer/consumer mode и явная commit-фаза — в
  [Linux lockless ring design](https://docs.kernel.org/trace/ring-buffer-design.html).

Многопоточные MPSC/MPMC-схемы с CAS не входят в direct-контракт: они решают
другую задачу и добавляют coordination, которого при одном writer и одном
reader быть не должно.

Production header содержит один concrete `SequenceRing` без policy-ветвлений.
Воспроизводимые альтернативы собраны под семантическими именами в
`shm::spsc::experimental` в `spsc_ring_variants.h`. Runtime enum выбирается до
входа в templated hot loop, поэтому внутри обработки сообщения нет virtual
dispatch или проверки варианта. Experimental header и startup-dispatch можно
удалить независимо от production queue.

## Воспроизводимый прогон

Для локальных A/B частота CPU `4`–`7` ограничивается одним значением, после
серии обязательно восстанавливается:

```bash
make cpu-frequency-set CPU_MAX_FREQ_KHZ=1200000
make run-direct-test MESSAGE_COUNT=500000 MESSAGE_RATE=250000 SHM_SLOTS=1024
make cpu-frequency-restore
```

Каждая пара вариантов запускается interleaved не менее пяти раз. Внутри пары
не меняются CPU, frequency cap, rate, message kind, capacity, compiler и способ
измерения. Результат принимается по медиане серии, а не по лучшему запуску.

PMU по ролям:

```bash
make perf-stat-direct-producer
make perf-stat-direct-consumer
```

По умолчанию сохраняются cycles, instructions, branches, branch misses,
cache references/misses, L1D loads/misses, dTLB loads/misses, context switches,
migrations и page faults. Пути можно разделить параметрами
`DIRECT_PRODUCER_PERF_OUTPUT` и `DIRECT_CONSUMER_PERF_OUTPUT`.

Изолированный thread-бенч вариантов:

```bash
make ring-handoff-benchmark \
  RING_HANDOFF_IMPL=sequence-zero-copy \
  MESSAGE_COUNT=500000 MESSAGE_RATE=250000 SHM_SLOTS=1024
```

Форма inlined hot loop проверяется в итоговом бинарнике:

```bash
objdump -d -C -M intel --disassemble=main harness/bin/consumer
```

В production sequence path publication check имеет форму `load -> cmp -> jne`
назад на empty-loop; runtime dispatch находится перед входом в этот path.

Сырые interleaved latency-серии находятся в
`data/direct-ring-ablation.csv`, выбранные role-level PMU-счётчики — в
`data/direct-ring-pmu.csv`.

## Подтверждённые изменения

### Корректный ownership вместо overwrite payload

Исходный snapshot ring мог принять frame во время overwrite. Детерминированный
тест останавливает writer после изменения payload, но до publication новой
sequence. Исправленная snapshot-версия атомарна, а новый SPSC contract вообще
не допускает одновременного доступа к payload. Unit-тесты и TSAN проверяют обе
модели отдельно.

### Zero-copy reserve/acquire

В `SequenceRing` producer строит `Trade`, `Bbo` или `OrderBook` сразу в
зарезервированном slot, consumer читает его через immutable view. Для frame
576 B thread-бенч снизился примерно с 502–547 ns у snapshot-copy до 200–203 ns
у reserve/view. В полном pinned direct-прогоне текущая реализация стабильно
держит P50 около 190 ns и P99 около 0.33–0.36 us при 250k msg/s.

### Layout и branch direction

Publication sequence находится в отдельной cache line, payload начинается с
cache-line boundary, а producer/consumer cursors разнесены. Empty branch помечен
как ожидаемый. Проверка ассемблера показала короткий backward branch polling
loop; PMU после hint показал примерно на 6.8% меньше instructions и на 5%
меньше branches без устойчивого ухудшения latency.

## Отрицательные результаты

### Shared cursor SPSC

Честный zero-copy shared-cursor вариант выбирается как
`DIRECT_RING=cursor`. В пяти process-level A/B медианы составили:

| Вариант | P50 | P99 | P99.9 | P99.99 локально |
|---|---:|---:|---:|---:|
| per-slot sequence | 193 ns | 351 ns | 4.04 us | 7.65 us |
| shared cursor | 193 ns | 1.97 us | 6.11 us | 10.05 us |

У cursor consumer было 4.271 B instructions против 3.920 B (`+9%`), 812.5 M
branches против 698.2 M (`+16%`) и 3.368 M L1D load misses против 3.222 M.
Producer стал легче, но reader hot loop и latency quality ухудшились. Вариант
оставлен для воспроизводимости, production default не менялся.

### Cached reader cursor

Кэширование reader cursor сократило aggregate L1 load misses примерно на 45%
и cache references на 56%, а P50 местами выиграл несколько наносекунд. При
этом process-level P99 вырос примерно с 0.35 до 0.58 us, P99.9 — примерно с
3.8 до 6.5 us. Оптимизация throughput/coherence не прошла latency gate.

### Удаление relaxed read cursor store

Удаление вспомогательной записи consumer уменьшило его instructions примерно
на 1.25% и L1D misses примерно на 6.5%, но median P50 вырос примерно с 192 до
198 ns, P99 — примерно с 0.35 до 0.48 us. Более агрессивный poll увеличил
coherence pressure; запись восстановлена.

### Глобальный write cursor и ранняя metadata preparation

`LeanSequenceRing` без per-message write cursor store не показал устойчивого
выигрыша. Перенос `frame_len` до send timestamp сделал P50 хуже: ранняя запись
инвалидировала publication cache line, polling reader забирал её обратно до
release-store. Сырые результаты сохранены в ablation CSV; policy-реализации
удалены из production header.

### Раздельные массивы metadata и payload

При capacity `1024` отдельный плотный control array выглядел перспективно:
медианы пяти process-level запусков снизились с `189/354 ns` до `180/336 ns`
по P50/P99. Padded control array дал `186/325 ns`. У dense producer стало
примерно на 1.1% меньше instructions, на 16.6% меньше cache references и на
7.7% меньше L1D load misses; consumer также сократил instructions и cache
references.

Проверка штатной capacity `65536` опровергла переносимость эффекта. Median P99
вырос примерно с `460 ns` до `3.0 us` у обеих split-раскладок. Control и frame
оказались в удалённых массивах, поэтому каждая доставка требует двух
независимых стримов памяти; выигрыш компактного control working set не
компенсировал локальность interleaved slot. Production layout оставлен
interleaved, а обе семантически именованные реализации сохранены только для
ablation.

### Clock и compiler flags

Raw invariant TSC дал около 472 cycles, то есть примерно 205 ns при TSC
2.304 GHz, совпав с realtime P50. Следовательно, текущий P50 — реальный
handoff, а не артефакт пересчёта `clock_gettime`. Калиброванный TSC, `-O3`,
`-fno-plt` и `-march=native` не дали воспроизводимого улучшения всей
percentile-кривой и не включены в production flags.

## Batching

При 250k msg/s producer создаёт одно сообщение каждые 4 us. Для фиксированного
write batch размера `B` среднее дополнительное ожидание равно
`2 us * (B - 1)`, худшее — `4 us * (B - 1)`. Уже `B=2` добавляет в среднем
`2 us` к direct floor около `0.19 us`, поэтому batching публикации не проходит
single-message latency contract.

Consumer уже естественно дренирует несколько готовых слотов без повторного
ожидания: после `commit()` следующая итерация сразу делает `acquire()`. Один
release-store на слот сохраняется намеренно, потому что именно он возвращает
ownership producer; откладывание его на пачку удерживает slots дольше и не
ускоряет ненасыщенный direct path.

Bulk/burst остаётся отдельным throughput-сценарием для насыщенного потока. Его
результат нельзя смешивать с single-message latency: отдельно фиксируются batch
size, offered rate, drops и время ожидания первого сообщения пачки.

## Критерий принятия и AWS-гейт

На локальной машине изменение принимается, если повторный interleaved A/B:

1. улучшает P50/P99; либо уменьшает доказанную PMU-работу без устойчивого
   ухудшения P99/P99.9;
2. не меняет drops и sequence integrity;
3. проходит unit-тесты и TSAN;
4. имеет объяснимый ассемблерный или coherence-эффект.

Локальный P99.99 приводится только как диагностика machine noise. Финальный
P99.99 gate выполняется на целевых AWS-инстансах с тем же бинарником и
параметрами, isolated physical cores, зафиксированной частотой, interleaved
серией и interrupt/thermal counters. Только там far-tail используется для
выбора production-варианта.
