# Сравнение текущего решения с agent baseline

## Контекст и границы сравнения

Сравниваются:

- текущий working tree `spectral-task` поверх коммита `a93321a`;
- agent baseline из remote-репозитория
  [`challenge/agent-solution`](https://gitlab.spectral.tech/challenge/agent-solution),
  коммит `c9c7085` (`agent solution`).

Новые performance-прогоны для этого сравнения не выполнялись. Выводы основаны
на исходниках, `SOLUTION.md` agent baseline и уже сохранённых результатах нашего
исследования direct SHM в [direct-ring.md](direct-ring.md) и
`data/direct-ring-*.csv`.

Прямое сравнение абсолютных latency некорректно: измерения выполнены на разном
железе, agent baseline изменяет формат сообщений и включает полностью
реализованный сетевой тракт, тогда как мы пока целенаправленно оптимизировали
direct SHM. Сравнивать можно архитектуру, относительные эффекты внутри каждого
стенда и декомпозицию latency по стадиям.

## Краткий вывод

Как полное конкурсное решение agent baseline сейчас существенно впереди: в нём
есть реальные AWS L2-прогоны, оптимизированный формат сообщений, opportunistic
batching, loss policy и unicast fan-out.

В слое shared memory наше решение глубже и корректнее. Мы нашли оставшуюся в
agent baseline гонку overwrite-ring, воспроизвели её детерминированным тестом,
исправили snapshot-вариант и построили ownership-based zero-copy SPSC-ring.
Полученный direct floor находится как минимум в том же субмикросекундном классе,
несмотря на исходные более крупные сообщения. Признаков, что направление выбрано
неверно, нет.

| Область | Текущее решение | Agent baseline | Оценка |
|---|---|---|---|
| Корректность SHM | Ownership SPSC и исправленный snapshot | Data race при overwrite | Наше решение сильнее |
| Direct SHM | Zero-copy `reserve/acquire/commit` | Несколько копирований payload | Наше направление перспективнее |
| Формат сообщений | Исходный, в среднем 320 B | В среднем 101 B | Baseline существенно впереди |
| UDP transport | Один `sendto`/`recvfrom` на message | Batching, busy-poll, несколько send backends | Baseline впереди |
| Loss handling | Воспроизводимый `netem`-стенд, без protocol policy | Monotonic gate и duplication experiments | Baseline впереди |
| Fan-out | Пока один receiver | Unicast в N destinations | Baseline впереди, но не решает масштаб 50 |
| Методика | Сильная SHM-ablation, PMU, TSAN | Сильная end-to-end AWS-методика | Сильные стороны дополняют друг друга |

## Что мы сделали лучше или не хуже baseline

### Корректность overwrite-ring

В agent baseline `shm::Ring::publish()` начинает менять неатомарные
`frame_len` и `frame`, пока в `seq` остаётся sequence предыдущей публикации:

См. [`harness/include/shm_ring.h:70-78`](https://gitlab.spectral.tech/challenge/agent-solution/-/blob/c9c7085/harness/include/shm_ring.h#L70-78).

Reader сначала читает старый подходящий `seq`, копирует неатомарный payload и
только затем повторно читает `seq`:

См. [`harness/include/shm_ring.h:90-112`](https://gitlab.spectral.tech/challenge/agent-solution/-/blob/c9c7085/harness/include/shm_ring.h#L90-112).

Если writer обернул кольцо и остановился после изменения payload, но до
publication store нового `seq`, reader может:

1. принять старый `seq`;
2. скопировать новый или смешанный payload;
3. снова увидеть тот же старый `seq`;
4. вернуть `kOk` для некорректного snapshot.

Помимо возможного torn frame, одновременные обычные `memcpy` writer и reader
образуют формальную C++ data race, то есть поведение undefined. Уменьшение
максимального frame с 576 до 160 B сокращает окно гонки, но не исправляет её.

Мы добавили детерминированный regression test, останавливающий writer внутри
этого окна (`harness/test/test_harness.cpp:148`), сделали data-race-free
атомарный snapshot и проверили его под TSAN. В agent baseline имеются тесты
roundtrip и lapping, но этого adversarial случая нет.

Это не обнуляет все опубликованные baseline-измерения: если sender/consumer ни
разу не пересекались с overwrite одного слота, гонка могла не проявиться. Но
корректность поведения при перегрузке, lapping и broadcast reading исходный код
baseline не гарантирует.

### Ownership и end-to-end zero-copy внутри direct SHM

Production `shm::spsc::SequenceRing` использует per-slot generations и передаёт
слот между единственным producer и единственным consumer:

```text
producer: reserve -> construct in SHM -> publish_reserved
consumer: acquire immutable view -> process -> commit
```

Одновременно payload принадлежит только одной стороне, поэтому он остаётся
обычной памятью без data race. Producer не создаёт промежуточный frame, а
consumer не копирует frame перед чтением заголовка. Контракт и альтернативы
описаны в [direct-ring.md](direct-ring.md#целевой-контракт).

В agent baseline путь содержит следующие копии:

```text
producer stack -> source ring
source ring -> sender scratch
sender scratch -> datagram
receiver buffer -> destination ring
destination ring -> consumer stack
```

Компактный формат сильно уменьшает цену этих копий, но не устраняет их. Наш
ownership API создаёт хорошую основу для последующей интеграции с registered или
provided buffers в `io_uring`.

### Изолированная оптимизация и отрицательные результаты

Мы отдельно проверили:

- корректный ownership вместо concurrent overwrite;
- zero-copy reserve/view;
- cache-line alignment и направление polling branch;
- shared-cursor и per-slot-generation семейства;
- cached cursors;
- split metadata/payload layouts на capacity 1024 и 65536;
- invariant TSC и compiler flags;
- role-level PMU counters и форму итогового ассемблера.

В production вошли только эффекты, прошедшие latency/correctness gate.
Неустойчивые или ухудшившие tail варианты сохранены как воспроизводимые
эксперименты либо удалены из production header. В частности, `-O3`,
`-fno-plt` и `-march=native` не показали воспроизводимого улучшения всей
percentile-кривой и не были включены только ради ожидаемого результата.

Для 576-байтового frame zero-copy thread hand-off уменьшился примерно с
502–547 ns у корректного snapshot-copy до 200–203 ns. Полный pinned direct-run
стабильно держит P50 около 190 ns и P99 около 0.33–0.36 us при 250k msg/s.

### Измерительная инфраструктура

У нас уже есть:

- isolated CPU configuration и pinning процессов;
- IRQ/thermal diagnostics;
- fixed-frequency interleaved A/B;
- PMU и TSAN-цели;
- rootless для обычного пользователя `make`-интерфейс к ограниченному sudo
  helper;
- namespace/veth/netem-стенд с воспроизводимыми delay/loss параметрами;
- preallocated, page-touched latency storage и dump после завершения hot loop.

Agent baseline сильнее в сетевых измерениях, но наше локальное окружение и
SHM-ablation не уступают по воспроизводимости в своей области.

## Что нашёл agent baseline, а мы пока упустили

### Оптимизация формата сообщений

Условия разрешают разумно менять harness и формат, сохраняя framing-поля
`seq_id` и `send_ts_ns` (`README.md:43-51` baseline-репозитория). Agent baseline
уменьшает:

| Message | Исходный размер | Новый размер |
|---|---:|---:|
| Trade | 192 B | 80 B |
| BBO | 192 B | 64 B |
| OrderBook | 576 B | 160 B |
| Mixed average | 320 B | 101 B |
| SHM slot | 640 B | 192 B |

Основные приёмы:

- numeric instrument ID вместо повторяющихся строк;
- только canonical integer ticks/lots вместо одновременных integer и double;
- удаление derived и reserved fields;
- фиксированный размер, выводимый из message type;
- timestamp deltas внутри одного self-contained frame;
- price offsets уровней book относительно top того же frame;
- cumulative trade totals для восстановления aggregate state после gap.

BBO и OrderBook остаются self-contained snapshots. Cumulative totals позволяют
восстановить volume/VWAP и количество сделок после пропуска, но не возвращают
сам потерянный trade event или его индивидуальные атрибуты.

Это один из крупнейших ещё не использованных нами рычагов: он одновременно
уменьшает cache footprint, объём копирования, размер SHM и packet rate. Заявленный
baseline-переход с collapse на 2.2M msg/s к 6M msg/s с zero loss выглядит
перспективно, хотя в отчёте нет полностью изолированной таблицы A/B, позволяющей
приписать весь трёхкратный эффект только формату, отдельно от остальных сетевых
изменений.

### Opportunistic network batching

Agent sender заполняет datagram только frames, уже опубликованными к моменту
чтения source ring, и отправляет его немедленно. Он не ждёт следующего message и
не использует timeout или минимальный batch size.

Это не противоречит нашему отрицательному выводу о batching direct publication:

- ожидание пачки до SHM-publication добавляет latency первому сообщению;
- упаковка уже накопившегося backlog не добавляет искусственного ожидания и
  уменьшает packets per second при высокой нагрузке.

По baseline-отчёту единственная потеря в rate sweep возникла около 840k
datagrams/s. При 1M msg/s в datagram помещалось в среднем 1.19 message и
наблюдалось 0.0088% loss; при 2M msg/s batching вырос до 2.53 message/datagram,
packet rate снизился примерно до 790k и loss снова стал нулевым.

Наш текущий sender отправляет один datagram на message. Если использовать 840k
pps baseline как опорную точку для похожего ENA-пути, текущая реализация не
сможет держать 2M msg/s даже для одного receiver, независимо от скорости SHM.

### Receive mode и socket tuning

На реальном NIC baseline сравнил userspace spin с blocking receive и
`SO_BUSY_POLL`:

| Mode на real NIC, 200k msg/s | P50 | P99 | P99.9 |
|---|---:|---:|---:|
| `SO_BUSY_POLL` | 34,521 ns | 39,194 ns | 54,517 ns |
| userspace spin | 58,965 ns | 82,893 ns | 184,721 ns |

На loopback результат оказался обратным, потому что там нет NAPI device для
polling. Это важная находка: локальный veth/loopback не определяет оптимальный
режим для ENA.

Baseline также настраивает socket buffers и `IP_TOS=IPTOS_LOWDELAY`, проверяет
path MTU и намеренно избегает IP fragmentation.

### Delivery и loss policy

Receiver пропускает frame только если его `seq_id` больше максимального уже
опубликованного. Один monotonic gate обеспечивает:

- deduplication;
- подавление reordering;
- отказ от слишком поздних repairs;
- gap accounting.

Agent экспериментировал с немедленной opportunistic duplication, но получил
важный отрицательный результат. Реальная потеря шла bursts примерно по 69–80
datagrams, а вторая копия отправлялась через несколько микросекунд и попадала в
тот же burst. Было спасено только 2 из 485 и 14 из 4007 потерянных datagrams.

Следовательно, формула `p -> p^2` для независимых потерь на этом пути
неприменима. Нужны temporal staggering, другой path или реалистичная модель
bursty loss. У нас уже есть средство воспроизводимо задавать loss через `netem`,
но protocol-level policy и burst profiles пока отсутствуют.

### Stage attribution и сетевой tail

Baseline размечает путь дополнительными timestamps:

```text
producer timestamp
  -> sender pre-send
  -> receiver arrival
  -> receiver SHM publication
  -> consumer read
```

Это позволило отделить source-ring queueing от kernel/NIC/wire и receiver
publication. На 20M messages при 200k msg/s опубликована следующая
декомпозиция:

| Stage | P50 | P99.9 | P99.99 | P99.999 | Max |
|---|---:|---:|---:|---:|---:|
| Source ring + sender | 305 ns | 670 ns | 731 ns | 748 ns | 4,777 ns |
| Wire | 34,338 ns | 49,143 ns | 67,273 ns | 1,055,667 ns | 1,960,424 ns |
| Arrival -> published | 50 ns | 222 ns | 276 ns | 7,072 ns | 12,984 ns |
| Published -> consumer | 264 ns | 634 ns | 743 ns | 6,347 ns | 108,465 ns |
| End to end | 34,996 ns | 49,818 ns | 68,089 ns | 1,056,468 ns | 1,961,160 ns |

Все 213 observations выше 1 ms были wire-dominated и образовывали drain
bursts, а не независимые случайные spikes. Это подтверждает наше решение не
оптимизировать laptop P99.99 как свойство очереди, но baseline делает следующий
важный шаг: локализует серверный tail до сетевой стадии.

## Нормализация performance-выводов

### Что можно сравнить

Наш direct-run измеряет один полный hand-off от producer timestamp через SHM до
consumer timestamp. Agent stage `published -> consumer` — наиболее близкая
граница, но она начинается уже после receiver publication.

Получается:

- наше значение: примерно 188–193 ns P50 с исходными frames до 576 B;
- agent `published -> consumer`: 264 ns P50 с compact frames до 160 B;
- agent полный receiver-side hand-off как сумма медиан
  `arrival -> published` и `published -> consumer`: около 314 ns.

Разное железо не позволяет объявить победителя. Тем не менее наш результат
попадает в тот же или лучший класс, измеряет более широкую границу и работает с
большими frames. Это сильный положительный сигнал для выбранного ring design.

### Сколько это может дать текущему socket/ENA пути

У agent baseline медианы non-wire стадий дают:

```text
305 + 50 + 264 = 619 ns
```

Относительно E2E P50 34,996 ns это около 1.8%. Даже гипотетическое полное
удаление всей userspace/SHM-работы не может улучшить median больше чем на эти
1.8%.

Если крайне щедро применить наше примерно 2.5-кратное ускорение snapshot-copy
ко всем 619 ns, включая не относящиеся к ring packing и gate operations,
получится:

```text
новая non-wire оценка: 619 / 2.5 ~= 248 ns
экономия:             619 - 248 ~= 371 ns
новая E2E P50:        34,996 - 371 ~= 34,625 ns
относительное улучшение: около 1.1%
```

Это заведомо оптимистичная верхняя оценка. Реалистичный выигрыш одной только
очереди на текущем kernel-UDP пути будет меньше процента. Поэтому agent baseline
обоснованно считает следующим сетевым рычагом `io_uring`, затем AF_XDP/DPDK.

При kernel bypass, меньшем wire leg или высокой fan-out нагрузке относительная
важность сотен наносекунд растёт. Кроме того, zero-copy влияет не только на
single-message median, но и на sender drain rate, queueing и способность
обрабатывать bursts.

### Неточность в baseline-отчёте

После таблицы baseline утверждает, что «our code» остаётся ниже 1 us даже на
P99.999. Это не согласуется с самой таблицей: `arrival -> published` имеет
P99.999 7.072 us, а `published -> consumer` — 6.347 us. Поскольку каждая из
неотрицательных стадий сама превышает 1 us, их pointwise aggregate не может
оставаться ниже 1 us на том же percentile.

Вероятно, утверждение предназначалось только для `source ring + sender`, где
P99.999 действительно равен 748 ns. Основной вывод о wire-dominated
миллисекундном tail остаётся корректным, но 620 ns следует использовать как
median decomposition, а не как доказанный far-tail bound всего userspace path.

## Fan-out

### Что реализовано в baseline

Agent baseline реализует первый практически полезный fan-out:

```text
producer -> source ring -> один sender -> N connected UDP sockets
                                      -> receiver 1 -> ring 1 -> consumer 1
                                      -> receiver 2 -> ring 2 -> consumer 2
                                      -> ...
```

Каждый receiver является независимым destination со своим socket, ring и
consumer. Sender поддерживает:

- connected socket на destination;
- `sendto` N раз;
- один `sendmmsg` с N destinations на unconnected socket.

При 10 destinations и 200k msg/s connected sockets дали лучшую P50/P99 и
наименьший skew. Декомпозиция показала, что преимущество возникло не из-за
нескольких микросекунд route lookup, а из-за более быстрого drain source ring:

| Method | P50 | P99 | Source-ring leg | Skew P50 |
|---|---:|---:|---:|---:|
| Connected | 47,764 ns | 59,451 ns | 5,841 ns | 10,234 ns |
| `sendmmsg` | 52,328 ns | 65,822 ns | 8,182 ns | 13,839 ns |
| `sendto` | 50,533 ns | 64,794 ns | 8,320 ns | 13,938 ns |

### Где заканчивается это решение

Это serial unicast, поэтому каждый новый receiver стоит дополнительного
datagram. Измеренный skew растёт примерно на 1.3 us на receiver и достигает
около 11.7 us при десяти destinations. При опорном бюджете 840k datagrams/s
baseline оценивает capacity для 50 receivers примерно в 100k msg/s даже при
batching около шести messages/datagram.

Следовательно, baseline реализует fan-out для стартового диапазона 1–3 и
полезный N-way benchmark, но не масштабируемое решение для десятков receivers.
Для такого масштаба нужны:

- network multicast, если его поддерживает fabric;
- relay tree с ограниченным branching factor;
- либо другая инфраструктурная репликация.

Multicast и relay tree в baseline отсутствуют.

### Влияние на нашу архитектуру

Network fan-out не требует превращать source ring в broadcast ring. Между одним
producer и одним sender по-прежнему корректен SPSC. На каждом удалённом сервере
также можно иметь отдельную пару receiver -> consumer.

Broadcast или несколько per-consumer SPSC rings нужны только если один receiver
на одном сервере должен кормить несколько локальных consumers. Исправленный
snapshot-ring формально может это делать, но его атомарное копирование дорого;
для production local fan-out понадобится отдельное исследование ownership и
per-reader progress.

Уже сейчас transport interface стоит проектировать с учётом:

- списка destinations;
- независимого учёта partial send/drop по receiver;
- worst-receiver latency и inter-receiver skew;
- отсутствия блокировки остальных из-за одного медленного destination;
- заменяемого fan-out backend.

Для стартовых 1–3 receivers connected UDP sockets являются разумной опорной
реализацией. Для 50 receivers нельзя закладываться на serial unicast как на
конечную архитектуру.

## Открытый вопрос нашего SPSC: freshness при заполнении

`SequenceRing::reserve()` возвращает `nullptr`, если producer догнал consumer.
Producer отбрасывает новое message и сохраняет уже накопившийся backlog.

Для underloaded direct-path это простой корректный non-blocking contract. При
перегрузке sender он может быть не лучшим HFT-policy: система продолжит
доставлять старые messages, пока новые отбрасываются. Agent baseline семантически
выбирает latest-wins через overwrite и reader lapping, хотя реализует concurrent
overwrite небезопасно.

Перед high-load сетевыми измерениями нам нужно явно выбрать и проверить policy:

- drop-new с сохранением очереди;
- reader fast-forward к live edge с освобождением пропущенного prefix;
- безопасный latest-wins ring;
- другой admission/backpressure contract.

Предпочтительное направление — управляемый fast-forward или иной безопасный
freshness mechanism, а не возврат к concurrent overwrite обычного payload.

## Предлагаемый порядок дальнейшей работы

Каждый пункт следует измерять отдельной серией, не смешивая эффекты:

1. **Stage instrumentation.** Добавить producer -> sender, wire,
   receiver-publication и consumer timestamps, чтобы следующие изменения можно
   было атрибутировать.
2. **Формат как отдельный вариант.** Реализовать compact self-contained format,
   сохранив исходный формат для A/B и отдельно проверив каждое семантическое
   сужение поля.
3. **Opportunistic wire batching.** Паковать только уже доступные messages, не
   ожидая заполнения datagram; измерять messages/datagram, pps, latency и drops.
4. **Интеграция ownership API в transport.** Убрать лишний source-ring copy в
   sender; исследовать receive непосредственно в reserved destination slot или
   registered buffers с корректным abort path для malformed datagram.
5. **Freshness policy.** Проверить поведение source и destination rings при
   saturation и bursts.
6. **Monotonic delivery gate.** Добавить deduplication/reordering/late-arrival
   policy и раздельные frame/datagram gap counters.
7. **Connected unicast fan-out.** Реализовать N destinations и измерять first,
   worst и skew для 1–3 receivers, затем на большем N определить точку смены
   архитектуры.
8. **`io_uring`.** Проверить multishot receive, provided/registered buffers,
   `DEFER_TASKRUN` и zero-copy send как следующий сетевой backend.
9. **AF_XDP/DPDK.** Переходить к kernel bypass только после stage evidence, что
   именно kernel/NIC path остаётся доминирующим на целевом AWS-стенде.

## Итоговая оценка

Текущее решение нельзя пока считать конкурентом полного agent baseline по
end-to-end функциональности: один-message-per-datagram transport без batching,
loss policy и fan-out заведомо проигрывает под высокой сетевой нагрузкой.

При этом работа над ring не была локальной косметикой. Мы:

- нашли correctness-дефект baseline;
- сделали data-race-free ownership model;
- получили zero-copy hand-off исходных больших messages;
- изолировали реальные и ложные оптимизации;
- построили воспроизводимую методику для дальнейшего attribution.

На socket/ENA пути этот выигрыш способен изменить E2E median лишь на доли
процента, потому что около 98% baseline latency приходится на wire/kernel/NIC.
Но очередь остаётся правильным фундаментом для burst drain, fan-out и будущего
kernel bypass. Следующий крупный прирост должен прийти не от дальнейшего
выжимания нескольких наносекунд из direct floor, а от сочетания compact format,
opportunistic batching, stage-aware network work и масштабируемой fan-out
архитектуры.
