## 1. Краткий вывод

Первым стоит реализовать **низкорисковый `SC24`**:

* явный wire-header дейтаграммы `24 Б`;
* события без ABI-padding: `BBO 60 Б`, `Trade 76 Б`, `OrderBook 150 Б`;
* полный одиночный кадр: `126 / 142 / 216 Б`;
* все три одиночных типа полностью входят в Wide LLQ `224 Б`;
* формат не имеет межпакетного состояния и сохраняет все текущие логические поля.

Даже промежуточный вариант «оставить DatagramHeader `32 Б`, удалить только reserved/padding из событий» уже даёт:

* BBO: `42 + 32 + 60 = 134 Б`;
* Trade: `42 + 32 + 76 = 150 Б`;
* OrderBook: `42 + 32 + 150 = 224 Б` ровно.

После него имеет смысл сделать **самодостаточный пакетный `PKT48`**: полный `base_seq`, полный базовый timestamp, instrument, reference price и общие timestamp-delta передаются один раз. Одиночные кадры становятся `122 / 138 / 208 Б`, а типичная пачка Trade+BBO — `170 Б`.

Агрессивный **сессионный `EPOCH24`** практически достижим так:

* BBO: `92 Б`, с запасом внутри обычного LLQ `96 Б`;
* Trade: `96 Б` ровно;
* полный OrderBook 5×2: **не помещается в `96 Б` без нереалистичных диапазонов или зависимости от предыдущего стакана**;
* консервативно суженный OrderBook получается `152 Б` с текущим checksum либо `148 Б` без него.

Рабочая production-схема поэтому должна быть гибридной:

1. собрать не более целевых `1..3` событий в рамках существующего дедлайна;
2. один раз проверить всю пачку на пригодность для `EPOCH24`;
3. если все события проходят — кодировать `EPOCH24`;
4. если хотя бы одно поле не проходит — всю дейтаграмму кодировать `PKT48`;
5. `SC24` оставить как максимально простой compatibility/pathological fallback.

Никаких varint-циклов и поиска конца числа на decoder fast path.

---

## 2. Общие правила wire-протокола

1. Все многобайтовые числа — **little-endian**.
2. Знаковые поля — two’s complement.
3. `u24/u48/u56` передаются младшим байтом первым.
4. Никаких C++ bitfields, `reinterpret_cast<Struct*>`, ABI-padding или packed-struct loads.
5. Используются явные `load_le16/24/32/48/56/64` и `store_*`.
6. `payload_len` не дублируется: он получается из UDP Length и фактического `mbuf->pkt_len`. Любое несовпадение длин — drop.
7. Длина записи определяется profile, type и явными mode-битами. После декодирования всех `event_count` конечный offset обязан точно совпасть с UDP payload length.
8. Все расчёты base+delta выполняются в расширенном временном типе либо с проверкой carry. Никакого modulo-восстановления, кроме самой сериализации полного unsigned значения.
9. Все размеры кадров ниже используют заданную арифметику `42 Б` и не включают FCS/preamble.

Физическое начало UDP payload находится после `42 Б`, поэтому естественного 8-байтового выравнивания всё равно нет. Добавлять wire-padding ради относительного alignment почти бессмысленно: нужны безопасные unaligned loads.

---

## 3. Аудит текущих полей

Обозначения:

* `SC24` — низкорисковый self-contained;
* `PKT48` — самодостаточный на уровне дейтаграммы;
* `EPOCH24` — сессионный;
* `→PKT48` — escape всей дейтаграммы в пакетный профиль.

| Поле                                                |        Текущие биты | Предложенные биты: `SC24 / PKT48 / EPOCH24`                           | База и диапазон                                                                 | Overflow / escape                                    | Семантический риск                                                                   |
| --------------------------------------------------- | ------------------: | --------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Datagram `payload_len`                              |                  32 | `0 / 0 / 0`                                                           | UDP Length                                                                      | Несовпадение длин → drop                             | Нет, поле дублирующее                                                                |
| Datagram `reserved`                                 |                  32 | `0 / 0 / 0`                                                           | —                                                                               | —                                                    | Нет                                                                                  |
| `frame_count`                                       |                  16 | `8 / 8 / 2`                                                           | `SC24`: до 149 BBO при jumbo; `PKT48`: protocol cap 255; `EPOCH24`: строго 1..3 | Разбить на две дейтаграммы                           | Нет                                                                                  |
| `datagram_seq`                                      |                  64 | `64 / 0 / 0`                                                          | В `PKT48/EPOCH24` пакет однозначно задаётся `first_seq + count`                 | В `SC24` полный u64                                  | Теряется только отдельный транспортный счётчик; event-level loss/reorder не страдает |
| Transport `send_ts_ns`                              |                  64 | `64 / base_ts+u32 / first_event_ts+u32`                               | `u32 ns = 4.294967296 с`                                                        | `PKT48→SC24`, `EPOCH24→PKT48`                        | Нет, значение восстанавливается точно                                                |
| Event `seq_id`                                      |                  64 | `64 / base_seq u64 + index / epoch seq_base u64 + u24 + index`        | `u24 = 0..16,777,215`                                                           | Новая эпоха либо `→PKT48`                            | Нет                                                                                  |
| Event `send_ts_ns`                                  |                  64 | `64 / base_ts u64 + u16 / epoch ts_base u64 + u32 + u16`              | Packet span `u16`: `65,535 нс`; epoch offset `u32`: `4.295 с`                   | Закрыть пакет; новая база. Никакого ожидания         | Нет                                                                                  |
| `instrument`                                        |                  16 | `16 / 16 или per-event 16 / slot u8`                                  | IDs `0..65534`; `0xffff` зарезервирован. Session slots `0..254`                 | Версия с u32 либо `→PKT48`                           | Session-профиль требует recoverable control state                                    |
| `type` + 7 flags                                    |  16, используется 9 | `16 / 16 / 16`                                                        | В `EPOCH24` оставшиеся 7 бит используются как точный timing dictionary index    | Version bump при появлении восьмого логического flag | Нет для текущей схемы                                                                |
| `exchange_ts_delta_ns` + `match_engine_ts_delta_ns` |                  64 | `64 / packet common 64 + local escape / exact 7-bit dictionary index` | До 127 точных пар значений                                                      | Нет пары → `PKT48`                                   | Hit-rate может быть низким, если значения почти всегда уникальны                     |
| Trade `price_ticks`                                 |                  64 | `64 / i32 от packet price_ref, wide i64 / i32 от epoch price_ref`     | `−2^31..2^31−1` ticks                                                           | Wide в `PKT48`; `EPOCH24→PKT48`                      | Нет                                                                                  |
| Trade `quantity_lots`                               |                  64 | `64 / 64 / u32`                                                       | `0..4,294,967,295` lots                                                         | Отрицательное или больше → `PKT48`                   | Нужен реальный bound для высокого hit-rate                                           |
| `trade_id`                                          |                  64 | `64 / 64 / i32 от epoch base`                                         | ±2,147,483,648                                                                  | `→PKT48`                                             | Не зависит от `seq_id`                                                               |
| Trade cumulative quantity                           |                  64 | `64 / 64 / u48 от immutable epoch base`                               | `0..281,474,976,710,655`                                                        | Ранняя эпоха либо `→PKT48`                           | Сохраняет восстановление aggregate после gap                                         |
| Trade cumulative notional                           |                  64 | `64 / 64 / u56 от immutable epoch base`                               | `0..72,057,594,037,927,935`                                                     | Ранняя эпоха либо `→PKT48`                           | Сохраняет восстановление aggregate после gap                                         |
| Trade cumulative count                              |                  64 | `64 / 64 / u24 от immutable epoch base`                               | `0..16,777,215`                                                                 | Новая эпоха либо `→PKT48`                            | Сохраняет восстановление aggregate после gap                                         |
| BBO/Book `update_id`                                |                  64 | `64 / 64 / i32 от epoch base`                                         | ±2,147,483,648                                                                  | `→PKT48`                                             | Не зависит от `seq_id`                                                               |
| BBO `spread_ticks`                                  |                  32 | `32 / 32 / 32`                                                        | Полный i32                                                                      | —                                                    | Сужать без данных не следует                                                         |
| BBO sizes                                           |           32 каждое | `32 / 32 / 32`                                                        | Полный i32                                                                      | —                                                    | Нет                                                                                  |
| OrderBook top prices                                |           64 каждое | `64 / i32 или wide i64 / i32 от epoch ref`                            | i32 delta                                                                       | Wide/`→PKT48`                                        | Нет                                                                                  |
| OrderBook offsets                                   |           32 каждое | `32 / 32 / i16`                                                       | `−32768..32767` ticks                                                           | `→PKT48`                                             | Нужны venue-specific гистограммы                                                     |
| OrderBook sizes                                     |           32 каждое | `32 / 32 / u24`                                                       | `0..16,777,215` lots                                                            | Отрицательное/больше → `PKT48`                       | Нужны реальные bounds                                                                |
| Order counts                                        |           16 каждое | `16 / 16 / 16`                                                        | `0..65535`                                                                      | —                                                    | Не сужать без данных                                                                 |
| `previous_update_gap`                               |                  16 | `16 / 16 / 16`                                                        | `0..65535`                                                                      | —                                                    | Не выводить из `update_id`                                                           |
| Current checksum                                    |                  32 | `32 / 32 / 32 compatibility`                                          | Сейчас функция только от `seq_id`                                               | Можно удалить только в новой семантической версии    | Текущий checksum не защищает содержимое стакана                                      |
| Event reserved/padding                              | Trade/BBO 32; OB 80 | `0 / 0 / 0`                                                           | —                                                                               | —                                                    | Нет                                                                                  |

Текущий `checksum = low32(seq_id * const)` не проверяет ни цены, ни sizes, ни counts. Он способен заметить лишь часть случайных повреждений пары `seq/checksum`, но не является book-integrity checksum. Для production есть два честных варианта:

* оставить его как compatibility marker;
* в новой версии заменить на CRC32C канонических байтов полного снимка.

Молча переименовывать старую формулу в «checksum стакана» нельзя.

---

# 4. Формат 1: низкорисковый `SC24`

## 4.1. Datagram header, 24 байта

| Offset | Size | Поле            | Кодирование                                                      |
| -----: | ---: | --------------- | ---------------------------------------------------------------- |
|      0 |    4 | magic           | фиксированные байты, например `4D 44 57 32` (`MDW2`)             |
|      4 |    1 | version         | `0x10` для `SC24`                                                |
|      5 |    1 | transport_flags | все текущие 8 бит                                                |
|      6 |    1 | event_count     | `1..255`; фактически ≤149 при текущем jumbo и минимальном record |
|      7 |    1 | header_bytes    | `24`                                                             |
|      8 |    8 | datagram_seq    | LE u64                                                           |
|     16 |    8 | tx_send_ts_ns   | LE u64, transport-stage timestamp                                |

`payload_len` получается из UDP Length. Для `SC24` u8 count доказан MTU:

```text
floor((8973 - 24) / 60) = 149
```

## 4.2. Общий префикс события, 24 байта

Поля переставлены ради более удобных relative offsets, но логическое значение не меняется.

| Offset | Size | Поле                                |
| -----: | ---: | ----------------------------------- |
|      0 |    1 | type: `1=Trade, 2=BBO, 3=OrderBook` |
|      1 |    1 | logical flags, bit 7 обязан быть 0  |
|      2 |    2 | instrument                          |
|      4 |    4 | exchange_ts_delta_ns                |
|      8 |    8 | seq_id                              |
|     16 |    8 | event_send_ts_ns                    |

`match_engine_ts_delta_ns` расположен в type-specific части, чтобы не вставлять 4 байта padding перед 64-битовыми market fields.

## 4.3. Trade, 76 байт

|    Offset |   Size | Поле                      |
| --------: | -----: | ------------------------- |
|         0 |     24 | общий префикс             |
|        24 |      8 | price_ticks               |
|        32 |      8 | quantity_lots             |
|        40 |      8 | trade_id                  |
|        48 |      8 | cumulative_quantity_lots  |
|        56 |      8 | cumulative_notional_ticks |
|        64 |      8 | cumulative_trade_count    |
|        72 |      4 | match_engine_ts_delta_ns  |
| **Итого** | **76** |                           |

## 4.4. BBO, 60 байт

|    Offset |   Size | Поле                     |
| --------: | -----: | ------------------------ |
|         0 |     24 | общий префикс            |
|        24 |      8 | update_id                |
|        32 |      8 | bid_price_ticks          |
|        40 |      4 | spread_ticks             |
|        44 |      4 | bid_size_lots            |
|        48 |      4 | ask_size_lots            |
|        52 |      4 | match_engine_ts_delta_ns |
|        56 |      2 | bid_order_count          |
|        58 |      2 | ask_order_count          |
| **Итого** | **60** |                          |

## 4.5. OrderBook, 150 байт

|    Offset |    Size | Поле                        |
| --------: | ------: | --------------------------- |
|         0 |      24 | общий префикс               |
|        24 |       8 | update_id                   |
|        32 |       8 | bid_top_price_ticks         |
|        40 |       8 | ask_top_price_ticks         |
|        48 |      16 | bid price offsets, `i32[4]` |
|        64 |      16 | ask price offsets, `i32[4]` |
|        80 |      20 | bid sizes, `i32[5]`         |
|       100 |      20 | ask sizes, `i32[5]`         |
|       120 |       4 | checksum                    |
|       124 |       4 | match_engine_ts_delta_ns    |
|       128 |      10 | bid order counts, `u16[5]`  |
|       138 |      10 | ask order counts, `u16[5]`  |
|       148 |       2 | previous_update_gap         |
| **Итого** | **150** |                             |

### Loss/reorder

Каждое событие независимо. Потеря дейтаграммы удаляет только содержащиеся в ней события.

Следующий Trade по-прежнему несёт полные cumulative totals до этой сделки, поэтому aggregate volume/notional/count восстанавливаются после gap в прежнем смысле.

### Fast path

* одна проверка Datagram header;
* один switch на type на событие;
* фиксированная длина по type;
* нет range branches и session lookup;
* только прямые LE stores/loads;
* на LE CPU endian conversion компилируется в no-op;
* нет encoder slow path.

Это формат с минимальным риском p99.9.

---

# 5. Формат 2: самодостаточный `PKT48`

Вся база находится в той же UDP-дейтаграмме. Потеря пакета никак не влияет на декодирование следующего.

## 5.1. Packet header, 48 байт

| Offset | Size | Поле                     | Семантика                          |
| -----: | ---: | ------------------------ | ---------------------------------- |
|      0 |    4 | magic                    | `MDW2`                             |
|      4 |    1 | version                  | `0x11`                             |
|      5 |    1 | transport_flags          | полные 8 бит                       |
|      6 |    1 | event_count              | `1..255`                           |
|      7 |    1 | header_bytes             | `48`                               |
|      8 |    8 | base_seq                 | полный `seq_id` первого события    |
|     16 |    8 | base_event_ts_ns         | полный timestamp первого события   |
|     24 |    4 | tx_delta_ns              | `tx_send_ts_ns - base_event_ts_ns` |
|     28 |    4 | common_exchange_delta_ns | common value                       |
|     32 |    4 | common_match_delta_ns    | common value                       |
|     36 |    2 | common_instrument        | либо instrument, либо `0xffff`     |
|     38 |    2 | context_flags            | bit 0 `MIXED_INSTRUMENT`           |
|     40 |    8 | price_ref_ticks          | полный i64 packet-local reference  |

`datagram_seq` здесь не нужен: пара `(base_seq, event_count)` лучше связана с реальными потерянными событиями.

Для события с индексом `i`:

```text
seq_id = base_seq + i
```

Это допустимо только для последовательных событий. При внутреннем gap/duplicate sender закрывает текущий пакет и начинает новый с полным `base_seq`. Ожидания это не добавляет.

## 5.2. Event prefix, common path, 4 байта

| Offset | Size | Поле                                  |
| -----: | ---: | ------------------------------------- |
|      0 |    1 | tag                                   |
|      1 |    1 | logical flags                         |
|      2 |    2 | `event_send_ts_ns - base_event_ts_ns` |

`tag`:

| Биты | Значение                                           |
| ---- | -------------------------------------------------- |
| 0..1 | `00=Trade`, `01=BBO`, `10=OrderBook`, `11=invalid` |
| 2    | `WIDE_PRICE`                                       |
| 3    | `LOCAL_TIMING`                                     |
| 4..7 | обязаны быть 0                                     |

`dt_ns` — unsigned `0..65535`. Если следующее событие не помещается либо CLOCK_REALTIME пошёл назад, пакет закрывается перед ним. Новое событие становится базой следующей дейтаграммы. Никакого дополнительного ожидания.

Если `LOCAL_TIMING=1`, в конец записи добавляются:

| Size | Поле                     |
| ---: | ------------------------ |
|    4 | exchange_ts_delta_ns     |
|    4 | match_engine_ts_delta_ns |

Если `MIXED_INSTRUMENT=1`, после 4-байтового prefix добавляется полный `instrument u16`; остальные поля сдвигаются на 2 байта.

## 5.3. Trade, common path, 48 байт

|    Offset |   Size | Поле                                 |
| --------: | -----: | ------------------------------------ |
|         0 |      4 | event prefix                         |
|         4 |      4 | `price_ticks - price_ref_ticks`, i32 |
|         8 |      8 | quantity_lots                        |
|        16 |      8 | trade_id                             |
|        24 |      8 | cumulative_quantity_lots             |
|        32 |      8 | cumulative_notional_ticks            |
|        40 |      8 | cumulative_trade_count               |
| **Итого** | **48** |                                      |

`WIDE_PRICE=1`: вместо i32 передаётся полный i64; размер `52 Б`.

## 5.4. BBO, common path, 32 байта

|    Offset |   Size | Поле                              |
| --------: | -----: | --------------------------------- |
|         0 |      4 | event prefix                      |
|         4 |      4 | bid_price_ticks − price_ref_ticks |
|         8 |      8 | update_id                         |
|        16 |      4 | spread_ticks                      |
|        20 |      4 | bid_size_lots                     |
|        24 |      4 | ask_size_lots                     |
|        28 |      2 | bid_order_count                   |
|        30 |      2 | ask_order_count                   |
| **Итого** | **32** |                                   |

`WIDE_PRICE=1`: полный bid price u64/i64, итог `36 Б`.

## 5.5. OrderBook, common path, 118 байт

|    Offset |    Size | Поле                  |
| --------: | ------: | --------------------- |
|         0 |       4 | event prefix          |
|         4 |       4 | bid top − price_ref   |
|         8 |       4 | ask top − price_ref   |
|        12 |       4 | checksum              |
|        16 |       8 | update_id             |
|        24 |      16 | bid offsets, `i32[4]` |
|        40 |      16 | ask offsets, `i32[4]` |
|        56 |      20 | bid sizes, `i32[5]`   |
|        76 |      20 | ask sizes, `i32[5]`   |
|        96 |      10 | bid counts, `u16[5]`  |
|       106 |      10 | ask counts, `u16[5]`  |
|       116 |       2 | previous_update_gap   |
| **Итого** | **118** |                       |

`WIDE_PRICE=1`: два полных i64 top price, размер `126 Б`.

### Escape-правила `PKT48`

* price delta не помещается в i32 → `WIDE_PRICE`;
* разные timestamp-delta пары внутри пакета → `LOCAL_TIMING` на соответствующей записи;
* разные instruments → `MIXED_INSTRUMENT` либо закрыть пакет;
* `dt_ns > 65535` или timestamp уменьшился → закрыть пакет;
* `tx_delta_ns > u32` или отрицателен → кодировать дейтаграмму как `SC24`.

Все escapes определяются при encode. Decoder выполняет один предсказуемый mode branch, а не varint loop.

### Trade aggregate recovery

`PKT48` передаёт cumulative поля полными u64 в каждой Trade. Гарантия после gap полностью совпадает с текущей.

---

# 6. Формат 3: сессионный `EPOCH24`

## 6.1. Data header, 24 байта

|    Offset |   Size | Поле                                       |
| --------: | -----: | ------------------------------------------ |
|         0 |      2 | magic bytes `4D 32` (`M2`)                 |
|         2 |      1 | version/profile + старшие 2 transport flag |
|         3 |      1 | `count_minus_1` + младшие 6 transport flag |
|         4 |      8 | epoch_key                                  |
|        12 |      3 | first_seq_delta, u24                       |
|        15 |      1 | instrument_slot                            |
|        16 |      4 | first_event_ts_delta_ns, u32               |
|        20 |      4 | tx_delta_from_first_event_ns, u32          |
| **Итого** | **24** |                                            |

Биты byte 2:

| Биты | Значение             |
| ---- | -------------------- |
| 0..3 | version              |
| 4..5 | profile              |
| 6..7 | transport flags 6..7 |

Биты byte 3:

| Биты | Значение                            |
| ---- | ----------------------------------- |
| 0..1 | `event_count - 1`, допустимы `0..2` |
| 2..7 | transport flags 0..5                |

Таким образом сохраняются все 8 транспортных flags.

Восстановление:

```text
first_seq_id = epoch.seq_base + first_seq_delta
first_event_ts_ns = epoch.ts_base_ns + first_event_ts_delta_ns
tx_send_ts_ns = first_event_ts_ns + tx_delta_from_first_event_ns

event[i].seq_id = first_seq_id + i
event[0].send_ts_ns = first_event_ts_ns
event[i>0].send_ts_ns = first_event_ts_ns + event_dt_u16
```

`datagram_seq` отсутствует. Дубликаты, reorder и gaps определяются точным event `seq_id`.

## 6.2. Двухбайтовый event prefix

В `EPOCH24` свободные биты type/flags используются для exact timing dictionary, без потери точности.

Byte 0:

| Биты | Поле                                       |
| ---- | ------------------------------------------ |
| 0..1 | type: `00 Trade`, `01 BBO`, `10 OrderBook` |
| 2..7 | timing_code bits 0..5                      |

Byte 1:

| Биты | Поле                  |
| ---- | --------------------- |
| 0..6 | текущие logical flags |
| 7    | timing_code bit 6     |

`timing_code 0..126` индексирует точную пару:

```text
(exchange_ts_delta_ns, match_engine_ts_delta_ns)
```

в immutable epoch control. Значение `127` зарезервировано как escape: вся дейтаграмма кодируется `PKT48`.

Для первого события prefix равен `2 Б`. Для каждого последующего сразу после prefix добавляется `dt_from_first_event_ns u16`; запись становится на 2 байта длиннее.

Это позволяет не предполагать, что оба timestamp delta всегда равны `4200/130`. Но если в реальном потоке почти каждая пара уникальна, hit-rate `EPOCH24` будет низким — это нужно измерить.

## 6.3. Trade, первое событие, 30 байт

|    Offset |   Size | Поле                           | Диапазон                 |
| --------: | -----: | ------------------------------ | ------------------------ |
|         0 |      2 | packed prefix                  | type, flags, timing code |
|         2 |      4 | price_delta_ticks, i32         | epoch price ref ±2³¹     |
|         6 |      4 | quantity_lots, u32             | `0..2³²−1`               |
|        10 |      4 | trade_id_delta, i32            | epoch ID base ±2³¹       |
|        14 |      6 | cumulative_quantity_delta, u48 | от epoch cumulative base |
|        20 |      7 | cumulative_notional_delta, u56 | от epoch cumulative base |
|        27 |      3 | cumulative_count_delta, u24    | от epoch cumulative base |
| **Итого** | **30** |                                |                          |

Для последующего Trade:

* offset всех body-полей увеличивается на 2;
* перед body находится `dt_ns u16`;
* размер `32 Б`.

Все cumulative delta считаются от **неизменяемой базы эпохи**, а не от предыдущей сделки.

Поэтому при потере Trade-пакета следующая дошедшая Trade всё равно восстанавливает:

```text
absolute_cumulative = epoch_base + encoded_delta
```

Это сохраняет нынешнюю lossless aggregate recovery.

## 6.4. BBO, первое событие, 26 байт

|    Offset |   Size | Поле                 |
| --------: | -----: | -------------------- |
|         0 |      2 | packed prefix        |
|         2 |      4 | update_id_delta, i32 |
|         6 |      4 | bid_price_delta, i32 |
|        10 |      4 | spread_ticks, i32    |
|        14 |      4 | bid_size_lots, i32   |
|        18 |      4 | ask_size_lots, i32   |
|        22 |      2 | bid_order_count      |
|        24 |      2 | ask_order_count      |
| **Итого** | **26** |                      |

Последующий BBO: `28 Б`.

Это полноценный самостоятельный BBO snapshot; предыдущая BBO-запись не нужна.

## 6.5. OrderBook, первое событие, 86 байт

Основной компактный вариант сохраняет текущий checksum.

|    Offset |   Size | Поле                  | Диапазон             |
| --------: | -----: | --------------------- | -------------------- |
|         0 |      2 | packed prefix         | —                    |
|         2 |      4 | update_id_delta, i32  | epoch base ±2³¹      |
|         6 |      4 | bid_top_delta, i32    | epoch price ref ±2³¹ |
|        10 |      4 | ask_top_delta, i32    | epoch price ref ±2³¹ |
|        14 |      8 | bid offsets, `i16[4]` | ±32768 ticks         |
|        22 |      8 | ask offsets, `i16[4]` | ±32768 ticks         |
|        30 |     15 | bid sizes, `u24[5]`   | 0..16,777,215 lots   |
|        45 |     15 | ask sizes, `u24[5]`   | 0..16,777,215 lots   |
|        60 |     10 | bid counts, `u16[5]`  | полный диапазон      |
|        70 |     10 | ask counts, `u16[5]`  | полный диапазон      |
|        80 |      2 | previous_update_gap   | полный u16           |
|        82 |      4 | checksum              | текущая семантика    |
| **Итого** | **86** |                       |                      |

Последующий OrderBook: `88 Б`.

Если текущий synthetic checksum удалён в новой версии, record равен `82/84 Б`, а полный одиночный кадр уменьшается с `152` до `148 Б`.

Этот OrderBook всё ещё самостоятельный: он зависит только от immutable epoch price reference, но не от предыдущего снимка.

### Почему полный OrderBook не помещается в 96 байт

При `24 Б` session header на событие остаётся:

```text
96 - 42 - 24 = 30 Б
```

Даже заведомо нереалистичная нижняя оценка без checksum:

* event prefix: `2 Б`;
* update ID delta всего `2 Б`;
* два top price delta по `2 Б`: `4 Б`;
* восемь price offsets по `1 Б`: `8 Б`;
* десять sizes по `1 Б`: `10 Б`;
* десять counts по `1 Б`: `10 Б`;
* previous gap: `1 Б`.

Итого:

```text
2 + 2 + 4 + 8 + 10 + 10 + 1 = 37 Б
```

Уже больше доступных `30 Б`, хотя ranges совершенно неприемлемы.

OrderBook `≤96 Б` возможен только при одном из трёх нарушений:

1. выводить часть levels из предыдущего book;
2. держать в epoch почти полный book-template и передавать diffs;
3. предположить крайне узкие venue-specific ranges с частыми escapes.

Первое и второе ухудшают loss independence и фактически ослабляют самостоятельность snapshot. Третье даст нестабильный p99.9 encoder path. Основным форматом это быть не должно.

---

## 7. Epoch control wire-layout

Control не находится на data fast path и может быть крупнее `96 Б`, но он также должен быть полной immutable-снимковой записью.

### 7.1. Control header, 64 байта

|    Offset |   Size | Поле                              |
| --------: | -----: | --------------------------------- |
|         0 |      4 | control magic                     |
|         4 |      1 | version                           |
|         5 |      1 | message_type                      |
|         6 |      1 | chunk_index                       |
|         7 |      1 | chunk_count                       |
|         8 |      8 | epoch_key                         |
|        16 |      8 | seq_base                          |
|        24 |      8 | ts_base_ns                        |
|        32 |      8 | valid_until_seq_exclusive         |
|        40 |      4 | refresh_serial                    |
|        44 |      2 | total_instruments                 |
|        46 |      2 | instruments_in_this_chunk         |
|        48 |      2 | timing_pair_count, `0..127`       |
|        50 |      2 | header_bytes, `64`                |
|        52 |      4 | body_bytes                        |
|        56 |      4 | control_flags                     |
|        60 |      4 | CRC32C header с zeroed CRC + body |
| **Итого** | **64** |                                   |

### 7.2. Timing dictionary entry, 8 байт

| Offset | Size | Поле                     |
| -----: | ---: | ------------------------ |
|      0 |    4 | exchange_ts_delta_ns     |
|      4 |    4 | match_engine_ts_delta_ns |

Все пары точные, никакой квантизации.

### 7.3. Instrument epoch entry, 52 байта

|    Offset |   Size | Поле                     |
| --------: | -----: | ------------------------ |
|         0 |      8 | price_ref_ticks          |
|         8 |      8 | trade_id_base            |
|        16 |      8 | update_id_base           |
|        24 |      8 | cumulative_quantity_base |
|        32 |      8 | cumulative_notional_base |
|        40 |      8 | cumulative_count_base    |
|        48 |      2 | instrument               |
|        50 |      1 | instrument_slot          |
|        51 |      1 | entry_flags              |
| **Итого** | **52** |                          |

Для одного instrument и одной timing pair:

```text
UDP application payload = 64 + 8 + 52 = 124 Б
полный frame = 42 + 124 = 166 Б
```

При payload limit `1472 Б` и одной timing pair в один control chunk помещается до 26 instrument entries. Для большего числа используются chunks; timing dictionary повторяется в каждом chunk, чтобы каждый пакет был независимо валидируемым.

---

# 8. Размеры полных Ethernet-кадров

Категории:

* **N** — `≤96 Б`, полностью обычный LLQ;
* **W** — `97..224 Б`, полностью только Wide LLQ;
* **D** — `>224 Б`, часть кадра требует DMA fetch.

| Формат         |        BBO |      Trade | OrderBook | Trade+BBO | BBO+OrderBook | OrderBook+Trade | Trade+BBO+OrderBook |
| -------------- | ---------: | ---------: | --------: | --------: | ------------: | --------------: | ------------------: |
| Текущий        |    `138 W` |    `154 W` |   `234 D` |   `218 W` |       `298 D` |         `314 D` |             `378 D` |
| `SC24`         |    `126 W` |    `142 W` |   `216 W` |   `202 W` |       `276 D` |         `292 D` |             `352 D` |
| `PKT48` common |    `122 W` |    `138 W` |   `208 W` |   `170 W` |       `240 D` |         `256 D` |             `288 D` |
| `EPOCH24`      | **`92 N`** | **`96 N`** |   `152 W` |   `124 W` |       `180 W` |         `184 W` |         **`212 W`** |

Для `EPOCH24` строки с OrderBook включают текущий 4-байтовый checksum. Без него из соответствующих значений вычитается `4 Б`: `148 / 176 / 180 / 208`.

Ключевые переходы:

* `SC24` переводит одиночный OrderBook с `234 D` в `216 W`;
* `EPOCH24` переводит BBO и Trade в normal LLQ;
* `EPOCH24` позволяет смешанную тройку уложить в `212 Б`, то есть полностью в Wide LLQ;
* `PKT48` существенно помогает PPS и copy footprint, даже когда LLQ-категория не меняется.

Trade `96 Б` находится ровно на границе. Для заданных `42 Б` это допустимо, но отдельно нужно проверить `95/96/97`, потому что любой VLAN tag или иное изменение network header нарушит запас.

---

# 9. Диапазоны и rollover

Предоставленная арифметика корректна:

* `u32 ns = 4.294967296 с`;
* `u32 µs = 71.5828 мин`;
* `u32 ms = 49.7103 дня`;
* `u48 ns = 3.257812 дня`;
* `u56 ns = 833.9999 дня`;
* standalone `u32 seq` живёт `5.965 ч / 35.791 мин / 8.948 мин`;
* standalone `u48 seq` живёт около `4.46 года` при `2M/с` и `1.115 года` при `8M/с`.

Именно поэтому `u48 seq` не подходит как постоянный формат: всё равно потребуется session rollover. При наличии epoch выгоднее передавать `u24` offset и полную u64 base в control.

## 9.1. `EPOCH24` raw capacities

| Поле                       |          Raw capacity |                           200k/с |    2M/с |    8M/с | Политика                     |
| -------------------------- | --------------------: | -------------------------------: | ------: | ------: | ---------------------------- |
| first_seq_delta u24        |    16,777,216 событий |                         83.886 с | 8.389 с | 2.097 с | эпоха максимум 1 с           |
| cumulative_count_delta u24 |      16,777,215 Trade | 83.886 с, если все события Trade | 8.389 с | 2.097 с | эпоха максимум 1 с           |
| first_ts_delta u32 ns      |               4.295 с |                                — |       — |       — | эпоха максимум 1 с           |
| tx delta u32 ns            |               4.295 с |                                — |       — |       — | при stall больше → `PKT48`   |
| packet event dt u16 ns     |             65.535 µs |                                — |       — |       — | закрыть пакет перед событием |
| epoch_key u64 при 1 Гц     | около `5.85×10¹¹` лет |                                — |       — |       — | practically no wrap          |

### Рекомендуемая эпоха

Новая эпоха открывается при первом из условий:

1. прошла `1 с`;
2. `seq_delta` приблизился к u24 limit;
3. cumulative delta приблизилась к своему limit;
4. cumulative total уменьшился/reset;
5. price/ID deltas систематически перестали помещаться;
6. нужно изменить timing dictionary или instrument-slot mapping.

Эпоха immutable: ни reference price, ни ID bases, ни timing dictionary нельзя менять под тем же `epoch_key`.

## 9.2. Cumulative bounds за 1 секунду

`u48 cumulative quantity` позволяет за одну эпоху:

```text
281,474,976,710,655 lots
```

При `8M Trade/с` это соответствует среднему:

```text
35,184,372 lots на Trade
```

`u56 cumulative notional` позволяет:

```text
72,057,594,037,927,935 tick-lots
```

При `8M Trade/с`:

```text
9,007,199,254 tick-lots на Trade
```

При цене `6,500,000 ticks` это около:

```text
1,385.7 lots на Trade в среднем
```

Для указанного synthetic max `991 lots` даже поток, состоящий только из `8M Trade/с`, даёт около:

```text
8,000,000 × 991 × 6,500,000
= 51,532,000,000,000,000
```

Это меньше `u56` limit. Но production bound всё равно должен подтверждаться реальными данными; overflow всегда уходит в `PKT48`.

---

# 10. Потери, reorder, late start и restart

| Сценарий                  | `SC24`                                          | `PKT48`                             | `EPOCH24`                                               |
| ------------------------- | ----------------------------------------------- | ----------------------------------- | ------------------------------------------------------- |
| Потерян data packet       | Потеря только его событий                       | Потеря только его событий           | Следующие data packets декодируются при наличии epoch   |
| Reorder data packets      | Независимое декодирование; seq выявляет reorder | То же                               | Epoch выбирается по key; seq выявляет reorder           |
| Потерян control packet    | Control отсутствует                             | Control отсутствует                 | Следующая полная копия control восстанавливает state    |
| Late receiver             | Декодирует первый packet                        | Декодирует первый packet            | Ждёт bootstrap/refresh, неизвестные epochs не угадывает |
| Receiver restart          | Немедленно                                      | Немедленно                          | TCP bootstrap либо следующий UDP refresh                |
| Sender restart            | Новый полный поток                              | Новый полный поток                  | Новый, никогда не переиспользуемый epoch namespace      |
| Trade aggregate после gap | Полный cumulative в следующей Trade             | Полный cumulative в следующей Trade | Epoch base + absolute delta в следующей Trade           |

## 10.1. State machine `EPOCH24`

### `UNSYNCED`

Receiver:

* декодирует `SC24/PKT48`;
* `EPOCH24` с неизвестным key не пытается интерпретировать;
* packet считается gap/unknown-epoch drop;
* принимает TCP bootstrap и UDP control chunks.

### `INSTALLING(epoch_key)`

Receiver собирает control chunks:

* каждый chunk проверяется CRC32C;
* повторный chunk с тем же key обязан иметь идентичное содержимое bases/dictionaries;
* instrument slots устанавливаются только из полного проверенного entry;
* частично известный epoch может декодировать только slots, для которых entry уже получен.

### `ACTIVE(epoch_key)`

* control immutable;
* data packet lookup выполняется по полному u64 key;
* timing code проверяется против `timing_pair_count`;
* packet seq/time проверяются против epoch ranges;
* никакие data-пакеты не изменяют state.

### `ROLLOVER`

Конкретная политика:

1. Sender создаёт новый epoch key.
2. Отправляет две полные копии control.
3. В течение первого `min(1 мс, 1024 data datagrams)` использует `PKT48`.
4. После guard window начинает `EPOCH24`.
5. Полный control refresh повторяется не реже чем через `min(1 мс, 1024 data datagrams)`.
6. Receiver хранит минимум четыре последних epoch states.

При потере одного UDP-пакета из двух initial controls остаётся вторая копия. Reorder control относительно data не создаёт бесконечного хвоста: guard data самодостаточны, а control продолжает повторяться.

### `UNKNOWN_EPOCH`

Неизвестный P2-пакет:

* не буферизуется неограниченно;
* не декодируется по «последней известной» базе;
* дропается и учитывается как gap;
* receiver может немедленно запросить control;
* следующий periodic refresh восстанавливает возможность декодировать будущие data.

После установки control следующая Trade восстанавливает cumulative aggregate, включая сделки, прошедшие до recovery, поскольку cumulative delta абсолютна относительно epoch base.

### Sender restart

`epoch_key` не должен переиспользоваться под тем же source tuple.

Надёжные варианты:

* persistent monotonic u64 epoch counter;
* либо новый UDP source port/feed identity при каждом sender generation.

Случайный 32-битный nonce недостаточен как строгая гарантия от stale-state collision.

---

# 11. Fast path encode/decode

| Формат    | Encoder                                                   | Decoder                                                 | Основные branches                                | Slow path                 |
| --------- | --------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------ | ------------------------- |
| `SC24`    | прямые stores фиксированных полей                         | type switch + fixed loads                               | один type branch/event                           | отсутствует               |
| `PKT48`   | выбрать bases, проверить dt/price, записать common header | сложение base+delta, type/mode switch                   | type, wide/local bits                            | wide price, local timing  |
| `EPOCH24` | один preflight всей пачки, затем фиксированные stores     | lookup epoch один раз, direct timing array, type switch | один `fits_all` branch на encode; type на decode | вся дейтаграмма → `PKT48` |

## 11.1. `EPOCH24` preflight

Для собранной пачки `1..3` вычисляется единый predicate:

```text
same_epoch
&& same_instrument_slot
&& consecutive_seq
&& timestamp_span <= 65535 ns
&& timing_pair_found_for_every_event
&& all price/id/quantity/cumulative/book fields fit
```

Если predicate false, **не используется частично переменная запись**: вся пачка кодируется `PKT48`.

Это лучше для p99.9, чем:

* per-field varints;
* несколько inline escape TLV;
* bitstream с циклическим decoder;
* fallback после частичного заполнения mbuf.

## 11.2. Unaligned loads

Для 16/32/64-битных полей:

* `memcpy` в scalar + LE conversion;
* либо проверенные compiler intrinsics для unaligned LE load.

Для `u24/u48/u56` — явные helpers без чтения за конец packet. Особенно `u24` в конце Trade нельзя реализовывать безусловным 4-байтовым overread.

## 11.3. Copies при `N=1..3`

Логическая группировка событий и epoch одинаковы для всех receivers.

Практический путь:

* при `N=1` — сериализовать непосредственно в mbuf;
* при `N=2..3` — сериализовать event records один раз в небольшой aligned scratch, скопировать в N mbufs;
* recipient-specific network header, transport timestamp и `SC24.datagram_seq` патчатся отдельно.

Не следует в первой реализации использовать mbuf clone/scatter-gather: дополнительные descriptors, refcount cacheline и изменение LLQ-path создадут ещё одну переменную в эксперименте.

Для `EPOCH24` data payload отличается между receivers максимум transport timestamp, если он ставится отдельно непосредственно перед соответствующим `tx_burst`; логические события остаются идентичными.

---

# 12. Что нельзя сужать без изменения гарантии

1. **Полный decoded `seq_id`.**
   Низкие 32/48 бит без полной recoverable base недостаточны. `u32` слишком быстро rollover; `u48` требует session rollover в течение срока эксплуатации.

2. **Полный decoded event timestamp.**
   `u56 absolute ns` живёт лишь около 834 дней. Корректен только full u64 либо delta относительно full recoverable base.

3. **Trade cumulative от предыдущей Trade.**
   Это уменьшило бы record, но одна потеря отравляла бы все последующие Trade до keyframe. В предложенном `EPOCH24` cumulative идёт от immutable epoch base.

4. **BBO/OrderBook от предыдущего snapshot.**
   Session reference price допустим. Предыдущий изменяемый book — нет.

5. **Связь `trade_id/update_id` с `seq_id`.**
   Она допустима только в benchmark-only профиле.

6. **Order counts ниже u16.**
   Нет предоставленного production bound. Экономия слишком мала относительно риска escape storms.

7. **Timing deltas как константы `4200/130`.**
   Для production они кодируются exact dictionary index; при отсутствии пары — fallback.

8. **OrderBook sizes/offsets без escape.**
   `i16/u24` допустимы только как fast common case с `PKT48` escape.

9. **Текущий checksum как book checksum.**
   Он не зависит от содержимого book.

---

## 13. Отдельный benchmark-only нижний предел

В синтетическом генераторе можно вывести:

```text
trade_id  = 100000 + seq_id
update_id = 900000 + seq_id
checksum  = f(seq_id)
```

Тогда в `EPOCH24` можно удалить:

* `trade_id_delta`: `−4 Б`;
* `update_id_delta`: `−4 Б`;
* OrderBook checksum: `−4 Б`.

Получаются ориентировочно:

* Trade: `26 Б` event, полный кадр `92 Б`;
* BBO: `22 Б` event, полный кадр `88 Б`.

Это полезно только как экспериментальная нижняя граница стоимости bytes/LLQ. Такой профиль нельзя выдавать за market-data wire-format.

Отдельный observability-вариант без transport-stage timestamp уменьшил бы session header на `4 Б`, но сделал бы сравнение с текущей latency-инструментацией неполным.

---

# 14. План A/B, различающий LLQ, copy/parse и PPS

## A. Чистый LLQ threshold

Использовать один и тот же logical record и test-only заранее заполненный trailer, который encoder не копирует на каждом событии.

Точки полного кадра:

```text
95, 96, 97 Б
223, 224, 225 Б
```

Запуски:

* обычный LLQ;
* Wide LLQ;
* `N=1,2,3`;
* без batching.

Для нижней границы удобно взять BBO `EPOCH24 92 Б` и добавить test padding. Для верхней — `SC24 OrderBook 216 Б`.

Если скачок возникает только между `96/97` или `224/225`, это прямое свидетельство LLQ threshold. Плавная зависимость от размера укажет на copy/DMA/cache component.

## B. Цена codec при одинаковом размере

Сравнить:

* `SC24`;
* `PKT48`;
* `EPOCH24`;

но дополнить меньшие пакеты test padding до одного и того же полного размера, например `216 Б`.

Тогда LLQ/DMA category и network bytes одинаковы. Разница показывает:

* encode instructions;
* base additions;
* session lookup;
* narrow integer loads;
* decoder branches.

Дополнительно сравнить direct-to-mbuf и serialize-once+copy для `N=2/3`.

## C. Польза меньшего PPS

При одном и том же codec:

1. batch `1`, без ожидания;
2. target `2`, deadline `500 нс`;
3. target `3`, deadline `1200 нс`.

Нагрузочные точки относительно измеренной capacity batch-1:

```text
70%, 90%, 98%, 102%
```

Измерять одновременно:

* p50, p99, p99.9 producer-ts → receiver;
* sender enqueue/doorbell component;
* receiver poll/decode component;
* datagrams/s;
* descriptors/s;
* failed/partial `tx_burst`;
* TX ring occupancy;
* cycles, instructions, branch misses на событие;
* bytes copied на событие.

Если batching выигрывает только у насыщения, механизм — PPS/descriptor pressure. Если выигрывает и далеко ниже насыщения без учёта ожидания, вероятны copy/cache/header effects.

## D. Конфаундер Wide LLQ queue depth

Сравнить `216 Б`:

* normal LLQ, packet пересекает inline limit;
* Wide LLQ, packet полностью inline.

Затем повторить при одинаковом числе outstanding descriptors, а не только при одинаковой nominal ring size. Иначе уменьшенная effective Wide-queue depth может скрыть выигрыш либо ухудшить p99.9 у насыщения.

Для стабильного p99.9 каждая точка должна содержать достаточно событий, чтобы tail включал не сотни, а десятки тысяч наблюдений; практически разумна выборка порядка `10⁸` событий на условие.

---

# 15. Рекомендация для дедлайна

| Работа                                          | Решение                                                                 | Сложность | Риск                                           |
| ----------------------------------------------- | ----------------------------------------------------------------------- | --------- | ---------------------------------------------- |
| Явная LE-сериализация, удаление reserved        | **Сделать сейчас**                                                      | Низкая    | Низкий                                         |
| `SC24` Datagram header                          | **Сделать сейчас**                                                      | Низкая    | Низкий                                         |
| Проверка `32 Б header + 150 Б OB = 224 Б`       | **Сделать сейчас как контрольную точку**                                | Низкая    | Низкий                                         |
| LLQ sweep `95/96/97`, `223/224/225`             | **Сделать сейчас**                                                      | Низкая    | Низкий                                         |
| `PKT48` с packet bases                          | **Сделать после `SC24`, вероятно до сдачи**                             | Средняя   | Низкий–средний                                 |
| Static-epoch benchmark codec для Trade/BBO      | **Допустимо сделать до сдачи как эксперимент**                          | Средняя   | Не production                                  |
| Полный control/recovery `EPOCH24`               | **Оставить после сдачи, если threshold-тест подтвердит ценность `≤96`** | Высокая   | Высокий                                        |
| `EPOCH24` OrderBook `i16/u24`                   | **После сбора реальных bounds**                                         | Средняя   | Средний–высокий                                |
| Добиваться полного OrderBook `≤96 Б`            | **Не делать**                                                           | Высокая   | Нарушение реалистичности или loss independence |
| Delta cumulative от предыдущей Trade            | **Не делать**                                                           | Средняя   | Ломает recovery после gap                      |
| Использовать synthetic ID relation в production | **Не делать**                                                           | Низкая    | Семантически неверно                           |
| Заменить checksum на CRC32C book body           | **После сдачи, отдельная версия**                                       | Средняя   | Меняет semantics и CPU cost                    |

Наиболее рациональная последовательность:

```text
SC24
→ контролируемый LLQ/copy эксперимент
→ PKT48
→ решение о production EPOCH24 только по измеренному выигрышу
```

---

# 16. Данные, необходимые для дальнейшего сужения

Для оценки реального `EPOCH24` hit-rate нужны не средние, а верхние квантили и maxima:

1. `quantity_lots`, включая наличие отрицательных sentinel/correction values;
2. приращение cumulative quantity за `1 с`;
3. приращение cumulative notional за `1 с`;
4. приращение cumulative count за `1 с`;
5. signed delta `trade_id` и `update_id` от 1-секундной базы;
6. cardinality точных пар `(exchange_delta, match_delta)` за эпоху;
7. максимальные OrderBook price offsets по каждой стороне;
8. максимальные size_lots на каждом уровне;
9. order-count distributions;
10. частота чередования instruments в глобальном seq;
11. `tx_send_ts - first_event_ts` на p99.9 и max;
12. resets/decreases cumulative и update IDs;
13. нужен ли текущий checksum внешним consumers;
14. максимальное число одновременно активных instruments.

До получения этих данных `SC24` и `PKT48` являются полноценными рабочими форматами. `EPOCH24` остаётся корректным благодаря fallback, но его доля fast-path пакетов неизвестна.

## Возможные искажения

* Наблюдаемые `0.45–0.55 мкс` могут включать одновременно LLQ threshold, copy bytes и DMA fetch; один size comparison это не разделяет.
* Wide LLQ меняет не только inline bytes, но и effective queue depth, поэтому сравнение без нормализации occupancy может дать обратный вывод.
* Synthetic постоянные timing deltas и линейные IDs существенно завышают ожидаемый hit-rate session-компрессии.

## Проверка логики

* Во всех трёх основных профилях `seq_id` и event `send_ts_ns` восстанавливаются побитово точно, без изменения единиц или precision.
* Ни один data packet не зависит от предыдущего data packet; `EPOCH24` зависит только от повторяемого immutable control snapshot.
* Основная Trade-схема сохраняет восстановление cumulative aggregate после gap; ослабленный previous-Trade delta в рабочий формат не включён.
