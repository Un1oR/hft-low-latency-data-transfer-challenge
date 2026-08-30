#!/usr/bin/env python3
"""Generate the Russian submission notebook from reviewable source cells."""

from __future__ import annotations

import json
from pathlib import Path
from textwrap import dedent


def lines(source: str) -> list[str]:
    text = dedent(source).strip() + "\n"
    return text.splitlines(keepends=True)


def markdown(source: str) -> dict:
    return {"cell_type": "markdown", "metadata": {}, "source": lines(source)}


def code(source: str) -> dict:
    return {
        "cell_type": "code",
        "execution_count": None,
        "metadata": {},
        "outputs": [],
        "source": lines(source),
    }


cells = [
    markdown(
        """
        # Передача рыночных событий с минимальной задержкой

        ## Архитектура сдаваемого решения

        Стартовая реализация переносила одну выровненную C++-структуру одним
        `sendto` на один адрес. Сдаваемый вариант сохраняет роли
        `producer/consumer`, логическую семантику событий и два обязательных поля
        `seq_id`/`send_ts_ns`, но перестраивает всю середину тракта:
        владение общей памятью, модель события, представление в сети,
        пакетирование, физическую рассылку и приём.

        ```text
        source EC2
          producer, CPU 2
            └─ строит событие прямо в зарезервированном слоте TX SPSC
               sender, CPU 3
                 └─ компактный сетевой формат → пачка → пакетная DPDK-отправка
                      ├─ Ethernet/IP/UDP → receiver 1 data ENI
                      ├─ Ethernet/IP/UDP → receiver 2 data ENI
                      └─ Ethernet/IP/UDP → receiver 3 data ENI

        каждый receiver EC2
          receiver, CPU 2
            └─ пакетный DPDK-приём → проверка → декодирование прямо в RX SPSC
               consumer, CPU 3
                 └─ запись seq_id и задержки = now - send_ts_ns
                      проверка после прогона: пропуски / дубли / перестановки
        ```

        ### Стенд измерений

        Все основные результаты ниже сняты на одной зафиксированной конфигурации:

        | Свойство | Конфигурация |
        |---|---|
        | EC2 и топология | четыре одинаковых `m8a.xlarge`: один source и три отдельных receiver |
        | Размещение | одна AZ и подсеть; дочерняя placement group `cluster` внутри `precision-time` |
        | ОС и ядро | Ubuntu Server 24.04 LTS amd64, штатное AWS-ядро `6.17.0-1020-aws` |
        | Сеть узла | управляющий ENI под Linux; отдельный измерительный ENI под DPDK через `igb_uio`; MTU 1500 |
        | Сетевой тракт | DPDK `25.11.3`, ENA PMD, hugepages, Wide LLQ |
        | Ядра CPU | CPU `2-3` закреплены за горячими процессами; CPU `0-1` оставлены ОС и IRQ |
        | Часы | `chrony` от ENA PHC; поправка к измеренной задержке равна нулю |

        Claude и наше решение запускались на тех же работающих узлах. После
        пересоздания EC2 абсолютные значения не переносятся: референсный прогон
        нужно повторять рядом с нашим решением.

        ### 1. Передача владения внутри хоста

        На обеих границах тракта используется ограниченная SPSC-очередь с
        поколением каждого слота. Producer резервирует свободный слот, строит в
        нём `Trade`, `BBO` или `OrderBook` и атомарно публикует метаданные с
        release-порядком; sender получает неизменяемый указатель и возвращает
        слот только после построения пакетов и попытки их сетевой отправки. На
        принимающей стороне receiver резервирует выходной слот и декодирует
        событие сразу туда. Поэтому между producer и sender нет промежуточной
        копии целой структуры, а между декодером и consumer — дополнительного
        временного объекта. При заполнении новая запись учитывается как пропуск,
        а память, которой ещё владеет читатель, не перезаписывается.

        Producer, sender, receiver и consumer работают горячим опросом на
        закреплённых физических ядрах. Один писатель и один читатель на каждой
        очереди позволяют обойтись без блокировок и CAS в обычном пути.

        ### 2. Модель события и формат в сети

        Исходные структуры повторяли строки инструмента и площадки, хранили
        одновременно `double` и целочисленные цены/объёмы, абсолютные и
        производные значения и большие области выравнивания. Каноническая
        модель хранит идентификатор инструмента, цены в тиках, объёмы в лотах,
        битовые признаки, короткие временные дельты и ценовые смещения уровней
        стакана. Статические справочные строки остаются вне горячего потока.
        Размеры объектов в общей памяти уменьшены с `192/192/576 Б` до
        `80/64/160 Б` для `Trade/BBO/OrderBook`:

        | Событие | Компактное представление | Самодостаточность после потери |
        |---|---|---|
        | `Trade` | цена в тиках, объём в лотах, временные дельты, признаки и накопительные объём/оборот/число сделок | следующая дошедшая сделка восстанавливает агрегаты, но не детали потерянной сделки |
        | `BBO` | цена bid, spread, объёмы bid/ask, времена и признаки; цена ask восстанавливается как `bid + spread` | каждый BBO является полным снимком лучших котировок |
        | `OrderBook` | верхняя цена и четыре смещения уровней на каждой стороне, объёмы, времена и признаки | каждый стакан является полным снимком пяти уровней на сторону |

        Отдельный сетевой кодек явно перечисляет передаваемые диапазоны и убирает
        только зарезервированные байты внутренних объектов. В сети три типа занимают
        соответственно `76/60/150 Б`; каждый сохраняет всю семантику
        канонической модели и исходные `seq_id`/`send_ts_ns`. Перед ними стоит
        32-байтный заголовок дейтаграммы с magic, версией, флагами формата,
        числом и общей длиной событий, номером дейтаграммы и диагностической
        меткой sender. Тип события однозначно задаёт его длину, поэтому
        дополнительных полей длины между событиями нет. Контракт v1 рассчитан
        на однородные amd64-узлы целевого стенда: размеры закреплены
        `static_assert`, а перенос между разным порядком байтов потребовал бы
        нормализации многобайтовых полей.

        Каждая дейтаграмма самодостаточна: декодирование следующей не требует
        предыдущей. Потеря видна по `seq_id` и номеру дейтаграммы, но не сбивает
        состояние кодека. Полный Ethernet-кадр с одиночным `OrderBook` занимает
        `224 Б` и целиком помещается в Wide LLQ ENA. На DPDK-пути sender передаёт
        кодеку сегменты прямо из SPSC-слотов и пропускает исключённые области без
        промежуточной компактной копии; одна финальная копия в отдельный mbuf
        каждого адресата всё ещё остаётся.

        ### 3. Ограниченное по времени пакетирование

        UDP payload ограничен `1472 Б`, поэтому IP-фрагментация не нужна.
        Sender начинает дейтаграмму с первого доступного события и без ожидания
        забирает все уже готовые события, пока они помещаются в MTU. Цель пачки
        используется только когда очередь временно опустела: sender либо ждёт
        недостающие события до цели, либо закрывает дейтаграмму по дедлайну.
        Цель выбирается до запуска по известным частоте и числу получателей:

        ```text
        target_frames = ceil(rate × N / 2 000 000 пакетов/с)
        ```

        Здесь учитывается, что одна дейтаграмма превращается в `N` физических
        пакетов. Если очередь временно пуста до достижения цели, sender ждёт не
        более `1200 нс`; при цели 1 ожидание равно нулю. Такое правило снижает
        давление на лимит PPS, сохраняя жёстную верхнюю границу дополнительной
        задержки одиночного события. До 32 готовых дейтаграмм собираются в один
        пакетный вызов DPDK.

        ### 4. Физическая рассылка через DPDK/ENA

        На каждом узле отдельный data ENI передан DPDK через `igb_uio`, а control
        ENI остаётся у Linux для SSM и синхронизации часов. Пользовательский
        `DPDK 25.11.3` с ENA PMD работает на hugepages, с одной горячей очередью,
        Wide LLQ и заранее подготовленным запасом mbuf. Sender формирует
        Ethernet/IPv4/UDP-заголовок для каждого адресата, использует аппаратный
        расчёт IPv4 checksum и одним логическим вызовом объединяет декартово
        произведение «готовые дейтаграммы × получатели». Если ENA приняла не всю
        пачку сразу, внутри вызова выполняются ограниченные повторные попытки
        `rte_eth_tx_burst`. Начальный адресат циклически меняется, чтобы один
        receiver не получал постоянного преимущества из-за позиции в пачке.

        Каждый receiver опрашивает ENA пачками до 32 кадров, проверяет адреса и
        UDP-порт, заголовок wire-протокола, длину и число событий, отдельно ведёт
        счётчики пропусков и перестановок дейтаграмм, затем публикует восстановленные
        внутренние события в локальную SPSC. Consumer получает восстановленную
        семантику события с исходными `seq_id`/`send_ts_ns` и считает сквозную
        задержку по неизменённой метке producer. Ретрансляции в горячем пути нет:
        приоритетом остаётся свежесть потока, а качество доставки контролируется
        номерами событий, номерами дейтаграмм и аппаратными ENA-счётчиками.

        Структура всей дейтаграммы проверяется до публикации первого события.
        Сама публикация выполняется по одному событию: если локальная RX SPSC
        заполнится, уже опубликованные события остаются доступны consumer, а
        каждый последующий пропуск будет отдельно виден по `seq_id` и счётчикам.

        Таким образом, решение масштабирует исходную одноадресную отправку до физической
        рассылки `1 → 1..3`, уменьшает число передаваемых байтов и пакетов и
        проводит данные в обход сетевого стека ядра, не меняя измерительный контракт.
        Экспериментальная проверка этой конструкции ниже разделена на полные
        распределения, рост частоты до насыщения, рост числа получателей и
        соседнее сравнение с неизменённой референсной реализацией Claude. Отдельный раздел
        [«Гипотезы и сила проверки»](#Гипотезы-и-сила-проверки) фиксирует силу
        подтверждения последующих микрооптимизаций.

        Практическая инструкция для независимого развёртывания находится в
        [`docs/reproduction.md`](docs/reproduction.md).
        """
    ),
    markdown(
        """
        ## Методика и границы интерпретации

        Основная метрика — `receive_ts_ns - send_ts_ns` на системных часах source и
        receiver. Все узлы синхронизированы `chrony` от ENA PHC; поправка всегда
        равна нулю. До и после каждого запуска сохранялась консервативная граница
        ошибки часов. UDP-проба по управляющему ENI использовалась только как
        диагностика и никогда не вычиталась из DPDK latency.

        Базовая реализация для сравнения — неизменённый Claude
        `c86cc26ab2e84996137f922cf175d33e9a622c29`,
        который мы сами собрали и запустили на тех же четырёх EC2. Для `N=1` и
        `N=3` Claude и DPDK используют один и тот же поднабор узлов; публичные
        цифры Claude с другого стенда здесь не используются.

        Сравнивать малые абсолютные сдвиги между разными созданиями EC2 нельзя.
        Поэтому:

        1. на каждой частоте сняты шесть блоков, и в каждом обе реализации идут
           рядом; порядок меняется через блок: `Claude → DPDK`, затем
           `DPDK → Claude`. Это контрсбалансирует линейный временной дрейф;
        2. основной результат — время доставки конкретного события всем
           получателям выбранного `N`: ряды совмещаются по `seq_id`, для события
           берётся максимум, и только затем считаются перцентили;
        3. для `N=3` рядом показываются три receiver-кривые, равновзвешенное
           распределение доставки одному получателю, средняя задержка трёх
           получателей для каждого события и центрированная форма хвоста.
           Основной fan-out-результат остаётся временем доставки всем;
        4. по шести внутриблочным разностям применяется точный двусторонний
           знаковый тест. Шесть одинаковых знаков дают минимальное
           `p = 2/2⁶ = 0,03125`; кроме того, эффект не называем разрешённым, если
           его медиана меньше собственного межблочного размаха Claude;
        5. p99.99 показываем, но сопровождаем полной кривой и всеми блоками;
        6. частотный срез, `N=1,2,3` и диагностическая раскладка тракта относятся
           к тем же instance IDs. Абсолютные данные разных созданий EC2 разделены.

        Эта схема и её мотивация заимствованы из
        [отчёта неизменённого baseline Claude](https://gitlab.spectral.tech/challenge/agent-solution/-/blob/c86cc26ab2e84996137f922cf175d33e9a622c29/SOLUTION.md#measurement-methodology):
        у автора знак разницы в несколько микросекунд менялся между
        сессиями, а p99.99 одной конфигурации гулял более чем на порядок. Поэтому
        плотные повторы внутри одного окна не считаются оценкой межоконной
        неопределённости.

        Плотные кривые рассчитаны из сырых CSV с каждой отдельной задержкой.
        Все benchmark-узлы фактически находились в дочерней `cluster` placement
        group одной `precision-time` group; имена и ID обеих групп записаны в
        suite, comparison matrix и manifest каждого запуска.

        У Claude сначала отбрасывается ровно тот же двухсекундный прогревочный
        префикс. Неравные края записи разрешено подрезать, но внутри общего
        диапазона `seq_id` обязаны быть непрерывны и совпадать у всех трёх узлов.
        Медиана перцентилей отдельных повторений не используется: она ошибочно
        сглаживала бы редкие задержки. Компактные производные данные и полные
        сведения об их происхождении лежат в `data/submission/`. Сырые
        многомиллионные CSV остаются в локальном каталоге артефактов, исключённом
        из Git; репозиторий содержит производные таблицы, достаточные для полного
        исполнения notebook.
        """
    ),
    code(
        """
        from pathlib import Path
        import hashlib
        import json

        import numpy as np
        import pandas as pd
        from IPython.display import display
        from bokeh.io import output_notebook, show
        from bokeh.layouts import column as bokeh_column, gridplot
        from bokeh.models import (
            BasicTicker, BasicTickFormatter, ColumnDataSource, CustomJS,
            FixedTicker, HoverTool, LinearScale, LogScale, LogTicker,
            LogTickFormatter, NumeralTickFormatter, RadioButtonGroup, Span,
            TabPanel, Tabs,
        )
        from bokeh.plotting import figure

        output_notebook(hide_banner=True)

        def show_table(frame: pd.DataFrame) -> None:
            display(frame.style.hide(axis="index"))

        ROOT = Path.cwd()
        DATA = ROOT / "data" / "submission"
        PRECISION_TIME_ONLY_DATA = DATA / "precision-time-only"
        runs = pd.read_csv(DATA / "run-summary.csv")
        distributions = pd.read_csv(DATA / "distribution-quantiles.csv")
        fanout = pd.read_csv(DATA / "fanout-distribution-quantiles.csv")
        density = pd.read_csv(DATA / "latency-density.csv")
        pooled_distributions = pd.read_csv(DATA / "comparison-pooled-quantiles.csv")
        pooled_fanout = pd.read_csv(DATA / "comparison-pooled-fanout-quantiles.csv")
        pooled_density = pd.read_csv(DATA / "comparison-pooled-density.csv")
        pooled_distributions["run_id"] = (
            pooled_distributions["group"] + "-" + pooled_distributions["implementation"]
        )
        pooled_fanout["run_id"] = (
            pooled_fanout["group"] + "-" + pooled_fanout["implementation"]
        )
        comparison_blocks = pd.read_csv(DATA / "comparison-blocks.csv")
        comparison_statistics = pd.read_csv(DATA / "comparison-statistics.csv")
        sequence = pd.read_csv(DATA / "latency-over-sequence.csv")
        tail_bursts = pd.read_csv(DATA / "tail-bursts.csv")
        stages = pd.read_csv(DATA / "stage-breakdown.csv")

        precision_runs = pd.read_csv(PRECISION_TIME_ONLY_DATA / "run-summary.csv")
        precision_distributions = pd.read_csv(
            PRECISION_TIME_ONLY_DATA / "distribution-quantiles.csv"
        )
        precision_fanout = pd.read_csv(
            PRECISION_TIME_ONLY_DATA / "fanout-distribution-quantiles.csv"
        )
        precision_density = pd.read_csv(
            PRECISION_TIME_ONLY_DATA / "latency-density.csv"
        )
        precision_pooled_distributions = pd.read_csv(
            PRECISION_TIME_ONLY_DATA / "comparison-pooled-quantiles.csv"
        )
        precision_pooled_fanout = pd.read_csv(
            PRECISION_TIME_ONLY_DATA / "comparison-pooled-fanout-quantiles.csv"
        )
        precision_pooled_density = pd.read_csv(
            PRECISION_TIME_ONLY_DATA / "comparison-pooled-density.csv"
        )
        precision_pooled_distributions["run_id"] = (
            precision_pooled_distributions["group"] + "-"
            + precision_pooled_distributions["implementation"]
        )
        precision_pooled_fanout["run_id"] = (
            precision_pooled_fanout["group"] + "-"
            + precision_pooled_fanout["implementation"]
        )
        precision_comparison_blocks = pd.read_csv(
            PRECISION_TIME_ONLY_DATA / "comparison-blocks.csv"
        )
        precision_comparison_statistics = pd.read_csv(
            PRECISION_TIME_ONLY_DATA / "comparison-statistics.csv"
        )
        precision_sequence = pd.read_csv(
            PRECISION_TIME_ONLY_DATA / "latency-over-sequence.csv"
        )
        precision_tail_bursts = pd.read_csv(
            PRECISION_TIME_ONLY_DATA / "tail-bursts.csv"
        )
        precision_provenance = json.loads(
            (PRECISION_TIME_ONLY_DATA / "provenance.json").read_text()
        )

        def source_fingerprint() -> str:
            roots = ["CMakeLists.txt", "CMakePresets.json", "packaging", "transport", "harness", "tools"]
            paths = []
            for root_name in roots:
                root = ROOT / root_name
                if root.is_file():
                    paths.append(root)
                else:
                    paths.extend(
                        path for path in root.rglob("*")
                        if path.is_file() and "harness/bin" not in path.relative_to(ROOT).as_posix()
                    )
            payload = "".join(
                f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(ROOT).as_posix()}\\n"
                for path in sorted(paths)
            ).encode()
            return hashlib.sha256(payload).hexdigest()[:12]

        current_fingerprint = source_fingerprint()
        assert current_fingerprint == "f356e7c68422", current_fingerprint
        expected_comparison_groups = {
            "comparison-n1-200k", "comparison-n1-2m",
            "comparison-n3-200k", "comparison-n3-2m",
        }
        assert len(runs) == 58
        assert runs.loc[~runs["expected_saturation"], "delivery_valid"].all()
        assert (~runs.loc[runs["expected_saturation"], "delivery_valid"]).all()
        assert set(distributions["group"]) == expected_comparison_groups
        assert {
            "delivered-to-all", "balanced-receiver", "mean-receiver"
        } <= set(fanout["metric"])
        assert density.groupby(["group", "block", "implementation"]).ngroups == 48
        assert len(comparison_blocks) == 168
        assert len(comparison_statistics) == 28
        assert set(comparison_blocks["block"]) == set(range(1, 7))
        assert runs["runner_instance_ids"].nunique() == 1
        assert not runs["source_dirty"].any()
        assert len(precision_runs) == 34
        assert set(precision_distributions["group"]) == {
            "comparison-n3-200k", "comparison-n3-2m"
        }
        assert {
            "delivered-to-all", "balanced-receiver", "mean-receiver"
        } <= set(precision_fanout["metric"])
        assert len(precision_comparison_blocks) == 84
        assert len(precision_comparison_statistics) == 14
        assert set(precision_comparison_blocks["block"]) == set(range(1, 7))
        assert precision_runs["runner_instance_ids"].nunique() == 1
        assert not precision_runs["source_dirty"].any()
        assert precision_provenance["epoch_profile"] == "precision-time-only"

        print(f"Загружено серий cluster-эпохи: {len(runs)}")
        print(f"Загружено серий precision-time-only эпохи: {len(precision_runs)}")
        print(f"Точек эмпирических распределений: {len(distributions):,}")
        print(f"Отпечаток измеренного исходного кода: {current_fingerprint}")
        """
    ),
    markdown(
        """
        ## Сравнение с Claude на целевой рассылке

        Для каждого `N` таблицы совмещают физические receiver по `seq_id`, берут
        для каждого события максимальную задержку и только затем считают
        перцентили времени доставки всем. Измеренный пакет имеет SHA-256
        `b56f3372…` и отпечаток исполняемых исходников `f356e7c68422`; последний
        независимо вычисляется в предыдущей ячейке и не зависит от правок
        документации.

        Разность всегда записана как `наш DPDK − Claude`, поэтому отрицательное
        значение означает преимущество нашего решения. Первая таблица показывает
        все 24 конфигурации-блока, вторая — итог по шести разностям каждой пары
        `(N, частота)`.
        Столбец разрешимости следует консервативному правилу Claude: согласованный
        знак с `p ≤ 0,05` и медианный эффект больше собственного межблочного
        размаха Claude.
        """
    ),
    code(
        """
        load_names = {200_000: "200 тыс./с", 2_000_000: "2 млн/с"}
        paired = comparison_blocks[
            comparison_blocks["metric"].isin(["p50", "p99", "p99.9", "p99.99"])
        ].copy()
        paired["N"] = paired["receivers"]
        paired["Нагрузка"] = paired["rate_events_s"].map(load_names)
        paired_table = (
            paired.pivot_table(
                index=["N", "Нагрузка", "block", "first_implementation", "midpoint_gap_s"],
                columns="metric",
                values="difference_spectral_minus_claude_us",
                aggfunc="first",
            )
            .reset_index()
            .rename(columns={
                "block": "Блок",
                "first_implementation": "Первым запущен",
                "midpoint_gap_s": "Расстояние середин, с",
                "p50": "Δp50, мкс",
                "p99": "Δp99, мкс",
                "p99.9": "Δp99.9, мкс",
                "p99.99": "Δp99.99, мкс",
            })
        )
        paired_table["Первым запущен"] = paired_table["Первым запущен"].map({
            "claude-c86cc26": "Claude", "spectral-task": "Наш DPDK"
        })
        show_table(paired_table.round(3))

        verdict = comparison_statistics.copy()
        verdict["N"] = verdict["receivers"]
        verdict["Нагрузка"] = verdict["rate_events_s"].map(load_names)
        verdict_table = verdict[[
            "N", "Нагрузка", "metric", "spectral_faster_blocks", "claude_faster_blocks",
            "min_aligned_samples_per_arm",
            "median_difference_spectral_minus_claude_us", "min_difference_us",
            "max_difference_us", "sign_test_two_sided_p",
            "claude_between_block_spread_us", "resolved_by_claude_rule",
        ]].rename(columns={
            "metric": "Перцентиль",
            "spectral_faster_blocks": "Наш быстрее, блоков",
            "claude_faster_blocks": "Claude быстрее, блоков",
            "min_aligned_samples_per_arm": "Мин. совмещённых событий",
            "median_difference_spectral_minus_claude_us": "Медианная Δ, мкс",
            "min_difference_us": "Мин. Δ, мкс",
            "max_difference_us": "Макс. Δ, мкс",
            "sign_test_two_sided_p": "Знаковый p",
            "claude_between_block_spread_us": "Размах Claude, мкс",
            "resolved_by_claude_rule": "Разрешено",
        }).round(3)
        show_table(verdict_table)

        configuration_names = {
            "comparison-n1-200k": "N=1, 200 тыс./с",
            "comparison-n1-2m": "N=1, 2 млн/с",
            "comparison-n3-200k": "N=3, 200 тыс./с",
            "comparison-n3-2m": "N=3, 2 млн/с",
        }
        quantile_names = {
            0.5: "p50", 0.99: "p99", 0.999: "p99.9", 0.9999: "p99.99",
        }
        pooled_table = pooled_distributions.copy()
        pooled_table["Перцентиль"] = pooled_table["quantile"].round(5).map(quantile_names)
        pooled_table = pooled_table.dropna(subset=["Перцентиль"])
        pooled_table["Конфигурация"] = pooled_table["group"].map(configuration_names)
        pooled_table["Реализация"] = pooled_table["implementation"].map({
            "claude-c86cc26": "Claude", "spectral-task": "Наш DPDK",
        })
        pooled_pivot = pooled_table.pivot_table(
            index=["Конфигурация", "Реализация"],
            columns="Перцентиль", values="latency_us", aggfunc="first",
        )
        pooled_pivot.columns.name = None
        show_table(pooled_pivot.reset_index().round(3))
        """
    ),
    markdown(
        """
        Консервативное правило даёт две разрешённые точки. При `N=3 / 200 тыс./с`
        наш p50 лучше во всех шести блоках, медианная разность
        `−2,927 мкс`; при `N=1 / 200 тыс./с` p99.99 лучше во всех шести блоках,
        медианная разность `−169,839 мкс`. Остальные отрицательные медианы нельзя
        объявлять доказанной победой: либо знак меняется, либо эффект меньше
        собственного межблочного размаха Claude.

        Самый важный отрицательный результат — `N=3 / 2 млн/с`: p50 и p99 делятся
        `3:3`, а p99.99 хуже у нашего DPDK в пяти блоках из шести с медианной
        разностью `+40,730 мкс`. Формально этот эффект тоже не разрешён шестью
        блоками, но считать текущую реализацию безусловно не хуже Claude на
        высокой fan-out-нагрузке нельзя.
        """
    ),
    markdown(
        """
        ### Устойчивость эффекта между блоками

        Ниже показана та же парная разность `наш DPDK − Claude` для каждого
        блока. Нулевая линия означает равенство; точки ниже неё — выигрыш нашего
        решения. Нечётные блоки начинаются с Claude, чётные — с DPDK; точный
        порядок также виден при наведении. Если знак систематически меняется
        вместе с порядком, результат нельзя приписывать реализации. Линии
        соединяют блоки только для удобства чтения, а не
        предполагают непрерывный временной процесс. Вкладки переключают обычную
        линейную шкалу и симметричное логарифмическое преобразование
        `sign(x)·log10(1+|x|)`: оно сохраняет знак и ноль, одновременно делая
        видимыми малые разности рядом с редкими значениями в сотни микросекунд.
        """
    ),
    code(
        """
        metric_colors = {
            "p50": "#2474b5", "p99": "#2a9d62",
            "p99.9": "#e28e2c", "p99.99": "#d1495b",
        }

        def signed_log_us(values):
            values = np.asarray(values, dtype=float)
            return np.sign(values) * np.log10(1.0 + np.abs(values))

        def paired_effect_plot(
            group: str, title: str, signed_log: bool = False, block_data=None
        ):
            block_data = comparison_blocks if block_data is None else block_data
            subset = block_data[
                (block_data["group"] == group)
                & block_data["metric"].isin(metric_colors)
            ]
            plot = figure(
                height=320, sizing_mode="stretch_width", title=title,
                x_axis_label="Номер контрсбалансированного блока",
                y_axis_label=(
                    "Наш DPDK − Claude, мкс (симметричный log)"
                    if signed_log else "Наш DPDK − Claude, мкс"
                ),
                tools="pan,box_zoom,reset,save",
            )
            plot.add_layout(Span(
                location=0, dimension="width", line_color="#6b7280",
                line_dash="dashed", line_width=2,
            ))
            for metric, frame in subset.groupby("metric", sort=False):
                frame = frame.sort_values("block")
                raw_difference = frame["difference_spectral_minus_claude_us"]
                source = ColumnDataSource({
                    "block": frame["block"],
                    "difference": (
                        signed_log_us(raw_difference)
                        if signed_log else raw_difference
                    ),
                    "difference_raw": raw_difference,
                    "first": frame["first_implementation"].map({
                        "claude-c86cc26": "Claude", "spectral-task": "Наш DPDK"
                    }),
                    "metric": [metric] * len(frame),
                })
                plot.line(
                    "block", "difference", source=source,
                    color=metric_colors[metric], line_width=2,
                    legend_label=metric,
                )
                plot.scatter(
                    "block", "difference", source=source,
                    color=metric_colors[metric], size=9,
                )
            if signed_log:
                raw_ticks = np.array([
                    -500, -300, -100, -30, -10, -3, -1, 0,
                    1, 3, 10, 30, 100, 300, 500,
                ], dtype=float)
                shown_ticks = signed_log_us(raw_ticks)
                plot.yaxis.ticker = FixedTicker(ticks=shown_ticks.tolist())
                plot.yaxis.major_label_overrides = {
                    float(shown): f"{raw:g}"
                    for shown, raw in zip(shown_ticks, raw_ticks, strict=True)
                }
            plot.xaxis.ticker = list(range(1, 7))
            plot.legend.click_policy = "hide"
            plot.add_tools(HoverTool(tooltips=[
                ("Блок", "@block"), ("Перцентиль", "@metric"),
                ("Разность", "@difference_raw{0.000} мкс"),
                ("Первым запущен", "@first"),
            ]))
            return plot

        def receiver_summary_plot(group: str, title: str, pooled_data=None):
            pooled_data = pooled_fanout if pooled_data is None else pooled_data
            plot = figure(
                height=430, sizing_mode="stretch_width", title=title,
                x_range=(-5.1, 5.1),
                x_axis_label=(
                    "Перцентиль: симметричная логарифмическая шкала вероятности"
                ),
                y_axis_label="Сквозная задержка, мкс",
                tools="pan,box_zoom,reset,save",
            )
            subset = pooled_data[
                (pooled_data["group"] == group)
                & (pooled_data["quantile"] >= 1e-5)
                & (pooled_data["quantile"] < 1.0)
            ]
            receiver_metrics = sorted(
                metric for metric in subset["metric"].unique()
                if metric.startswith("receiver:")
            )
            receiver_numbers = {
                metric: index + 1 for index, metric in enumerate(receiver_metrics)
            }

            for (implementation, metric), frame in subset[
                subset["metric"].str.startswith("receiver:")
            ].groupby(["implementation", "metric"], sort=True):
                is_claude = implementation == "claude-c86cc26"
                implementation_label = "Claude" if is_claude else "Наш DPDK"
                series_label = (
                    f"{implementation_label}: получатель {receiver_numbers[metric]}"
                )
                source = ColumnDataSource({
                    "x": probability_log_odds(frame["quantile"]),
                    "y": frame["latency_us"],
                    "series": [series_label] * len(frame),
                    "percentile": frame["quantile"] * 100,
                })
                plot.line(
                    "x", "y", source=source,
                    color=RED if is_claude else BLUE,
                    alpha=0.20, line_width=1.5,
                )

            summary_metrics = {
                "balanced-receiver": ("равновзвешенный получатель", "solid", 4),
                "mean-receiver": ("среднее трёх для события", "dashed", 3),
            }
            for (implementation, metric), frame in subset[
                subset["metric"].isin(summary_metrics)
            ].groupby(["implementation", "metric"], sort=True):
                is_claude = implementation == "claude-c86cc26"
                implementation_label = "Claude" if is_claude else "Наш DPDK"
                metric_label, line_dash, line_width = summary_metrics[metric]
                series_label = f"{implementation_label}: {metric_label}"
                source = ColumnDataSource({
                    "x": probability_log_odds(frame["quantile"]),
                    "y": frame["latency_us"],
                    "series": [series_label] * len(frame),
                    "percentile": frame["quantile"] * 100,
                })
                plot.line(
                    "x", "y", source=source,
                    color=RED if is_claude else BLUE,
                    line_dash=line_dash, line_width=line_width,
                    legend_label=series_label,
                )

            configure_probability_axis(plot)
            plot.legend.location = "top_left"
            plot.legend.click_policy = "hide"
            plot.add_tools(HoverTool(tooltips=[
                ("Ряд", "@series"),
                ("Перцентиль", "@percentile{0.000}%"),
                ("Задержка", "@y{0.000} мкс"),
            ]))
            return plot

        effect_specs = [
            ("comparison-n1-200k", "N=1, 200 тыс. событий/с"),
            ("comparison-n1-2m", "N=1, 2 млн событий/с"),
            ("comparison-n3-200k", "N=3, 200 тыс. событий/с"),
            ("comparison-n3-2m", "N=3, 2 млн событий/с"),
        ]

        def effect_grid(signed_log: bool):
            plots = [
                paired_effect_plot(group, title, signed_log)
                for group, title in effect_specs
            ]
            # One full-width plot per row remains readable in narrow notebook
            # panes and avoids clipped axis labels inside Tabs.
            return gridplot([[plot] for plot in plots], sizing_mode="stretch_width")

        show(Tabs(tabs=[
            TabPanel(child=effect_grid(False), title="Линейная шкала"),
            TabPanel(
                child=effect_grid(True),
                title="Симметричная логарифмическая шкала",
            ),
        ]))
        """
    ),
    markdown(
        """
        ### Полные распределения при 200 тыс. событий/с

        Ось X — симметричная логарифмическая шкала вероятности: p50 находится в
        центре, слева раздвинуты p25/p10/p1/p0.1…, справа —
        p75/p99/p99.9…. Показано распределение от p0.001 до p99.999, а не
        только правый хвост и не четыре соединённые точки. Голый минимум оставлен
        за графиком: одна экстремальная точка нестабильна и не имеет конечной
        координаты на logit-шкале. По умолчанию величина задержки по Y также
        показана логарифмически; кнопка переключает её на линейную без повторного
        запуска notebook. Тонкие полупрозрачные линии показывают каждый из шести
        блоков отдельно, толстая линия — их объединённое распределение. Сплошная
        тонкая линия означает нечётный блок (`Claude → DPDK`), пунктирная —
        чётный (`DPDK → Claude`): так видны и разброс, и возможная зависимость от
        порядка запуска.
        """
    ),
    code(
        """
        BLUE = "#2474b5"
        RED = "#d1495b"
        GREEN = "#2a9d62"
        ORANGE = "#e28e2c"
        GRAY = "#6b7280"

        PROBABILITY_TICK_QUANTILES = [
            1e-5, 1e-4, 1e-3, 0.01, 0.1, 0.25, 0.5,
            0.75, 0.99, 0.999, 0.9999, 0.99999,
        ]
        PROBABILITY_TICK_LABELS = [
            "p0.001", "p0.01", "p0.1", "p1", "p10", "p25", "p50",
            "p75", "p99", "p99.9", "p99.99", "p99.999",
        ]

        def probability_log_odds(values):
            values = np.asarray(values)
            return np.log10(values / (1.0 - values))

        def configure_probability_axis(plot):
            ticks = probability_log_odds(PROBABILITY_TICK_QUANTILES).tolist()
            plot.xaxis.ticker = ticks
            plot.xaxis.major_label_overrides = dict(
                zip(ticks, PROBABILITY_TICK_LABELS, strict=True)
            )
            plot.xaxis.major_label_orientation = 0.75

        TAIL_TICK_PROBABILITIES = [0.5, 0.01, 0.001, 0.0001, 0.00001]
        TAIL_TICK_LABELS = ["p50", "p99", "p99.9", "p99.99", "p99.999"]

        def configure_tail_probability_axis(plot):
            plot.xaxis.ticker = TAIL_TICK_PROBABILITIES
            plot.xaxis.major_label_overrides = dict(
                zip(TAIL_TICK_PROBABILITIES, TAIL_TICK_LABELS, strict=True)
            )

        def with_scale_switch(content, plots, axis="y", default_log=True):
            # Переключатель работает и в сохранённом standalone HTML.
            scales_linear, scales_log = [], []
            tickers_linear, tickers_log = [], []
            formatters_linear, formatters_log = [], []
            axes = []
            for plot in plots:
                linear_scale, log_scale = LinearScale(), LogScale()
                linear_ticker, log_ticker = BasicTicker(), LogTicker()
                linear_formatter, log_formatter = BasicTickFormatter(), LogTickFormatter()
                axis_model = (plot.yaxis if axis == "y" else plot.xaxis)[0]
                setattr(plot, f"{axis}_scale", log_scale if default_log else linear_scale)
                axis_model.ticker = log_ticker if default_log else linear_ticker
                axis_model.formatter = log_formatter if default_log else linear_formatter
                scales_linear.append(linear_scale)
                scales_log.append(log_scale)
                tickers_linear.append(linear_ticker)
                tickers_log.append(log_ticker)
                formatters_linear.append(linear_formatter)
                formatters_log.append(log_formatter)
                axes.append(axis_model)

            switch = RadioButtonGroup(
                labels=["Линейная шкала", "Логарифмическая шкала"],
                active=1 if default_log else 0,
                width=360,
            )
            switch.js_on_change("active", CustomJS(args={
                "plots": plots,
                "axes": axes,
                "linear_scales": scales_linear,
                "log_scales": scales_log,
                "linear_tickers": tickers_linear,
                "log_tickers": tickers_log,
                "linear_formatters": formatters_linear,
                "log_formatters": formatters_log,
                "axis_name": axis,
            }, code='''
                const use_log = cb_obj.active === 1
                for (let i = 0; i < plots.length; i++) {
                    plots[i][axis_name + "_scale"] = use_log ? log_scales[i] : linear_scales[i]
                    axes[i].ticker = use_log ? log_tickers[i] : linear_tickers[i]
                    axes[i].formatter = use_log ? log_formatters[i] : linear_formatters[i]
                }
            '''))
            return bokeh_column(switch, content, sizing_mode="stretch_width")

        def distribution_plot(
            group: str, value: str, title: str, y_label: str,
            dataset=None, metric: str | None = None, tail_only: bool = False,
            individual_dataset=None,
        ):
            dataset = distributions if dataset is None else dataset
            figure_options = dict(
                height=390, sizing_mode="stretch_width", title=title,
                y_axis_label=y_label, tools="pan,box_zoom,reset,save",
            )
            if tail_only:
                figure_options.update(
                    x_axis_type="log", x_range=(0.5, 1e-5),
                    x_axis_label="Правый хвост: от p50 до p99.999",
                )
            else:
                figure_options.update(
                    x_range=(-5.1, 5.1),
                    x_axis_label="Перцентиль: симметричная логарифмическая шкала вероятности",
                )
            plot = figure(**figure_options)

            def selected(source):
                subset = source[
                    (source["group"] == group)
                    & (source["quantile"] >= (0.5 if tail_only else 1e-5))
                    & (source["quantile"] < 1.0)
                ]
                if metric is not None:
                    subset = subset[subset["metric"] == metric]
                return subset

            if individual_dataset is not None:
                individual = selected(individual_dataset)
                for run_id, frame in individual.groupby("run_id", sort=False):
                    is_claude = frame["implementation"].iloc[0] == "claude-c86cc26"
                    block = int(frame["block"].iloc[0])
                    source = ColumnDataSource({
                        "x": (
                            frame["tail_probability"]
                            if tail_only else probability_log_odds(frame["quantile"])
                        ),
                        "y": frame[value],
                        "label": frame["label_ru"],
                        "block": [str(block)] * len(frame),
                        "arm": [str(int(frame["arm_position"].iloc[0]))] * len(frame),
                        "percentile": frame["quantile"] * 100,
                    })
                    plot.line(
                        "x", "y", source=source,
                        color=RED if is_claude else BLUE,
                        alpha=0.22, line_width=1.4,
                        line_dash="solid" if block % 2 else "dashed",
                    )

            subset = selected(dataset)
            for run_id, frame in subset.groupby("run_id", sort=False):
                is_claude = frame["implementation"].iloc[0] == "claude-c86cc26"
                color = RED if is_claude else BLUE
                source = ColumnDataSource({
                    "x": (
                        frame["tail_probability"]
                        if tail_only else probability_log_odds(frame["quantile"])
                    ),
                    "y": frame[value],
                    "label": frame["label_ru"],
                    "block": ["все"] * len(frame),
                    "arm": ["—"] * len(frame),
                    "percentile": frame["quantile"] * 100,
                })
                plot.line(
                    "x", "y", source=source, color=color, alpha=1.0, line_width=4,
                    legend_label=frame["label_ru"].iloc[0],
                )
            if tail_only:
                configure_tail_probability_axis(plot)
            else:
                configure_probability_axis(plot)
            plot.legend.location = "top_left"
            plot.legend.click_policy = "hide"
            plot.add_tools(HoverTool(tooltips=[
                ("Серия", "@label"),
                ("Блок", "@block"),
                ("Позиция в блоке", "@arm"),
                ("Перцентиль", "@percentile{0.000}%"),
                ("Задержка", "@y{0.000} мкс"),
            ]))
            return plot

        delivered_n1_200k = distribution_plot(
            "comparison-n1-200k", "latency_us",
            "200 тыс./с, N=1: событие доставлено",
            "Сквозная задержка, мкс",
            pooled_distributions,
            individual_dataset=distributions,
        )
        delivered_n3_200k = distribution_plot(
            "comparison-n3-200k", "latency_us",
            "200 тыс./с, N=3: событие доставлено всем",
            "Сквозная задержка, мкс",
            pooled_distributions,
            individual_dataset=distributions,
        )
        receiver_n3_200k = receiver_summary_plot(
            "comparison-n3-200k",
            "200 тыс./с, N=3: доставка отдельным получателям",
        )
        comparison_200k_grid = gridplot(
            [[delivered_n1_200k, delivered_n3_200k]], sizing_mode="stretch_width"
        )
        show(with_scale_switch(
            comparison_200k_grid,
            [delivered_n1_200k, delivered_n3_200k], default_log=True,
        ))
        show(with_scale_switch(
            receiver_n3_200k, [receiver_n3_200k], default_log=True,
        ))
        """
    ),
    markdown(
        """
        Графики разделяют `N=1` и `N=3`: сравнивать высоту кривых между ними как
        эффект реализации нельзя, зато внутри каждого графика Claude и DPDK
        сняты на одном поднаборе узлов. Тонкие линии не дают объединённой кривой
        спрятать зависимость от блока или порядка запуска; численный парный вывод
        находится в таблицах выше.
        """
    ),
    markdown(
        """
        ### Полные распределения при 2 млн событий/с

        Первые два графика показывают исходное время доставки всем. График
        отдельных получателей совмещает три полупрозрачные receiver-кривые каждой
        реализации, равновзвешенное распределение доставки одному адресату и
        распределение среднего трёх задержек для каждого события. На отдельном
        графике из задержек каждого receiver сначала вычтен его собственный p50,
        после чего для события взят максимум. Этот срез показывает правый хвост
        джиттера от p50 до p99.999.
        """
    ),
    code(
        """
        absolute_n1_2m = distribution_plot(
            "comparison-n1-2m", "latency_us",
            "2 млн/с, N=1: абсолютная задержка",
            "Сквозная задержка, мкс",
            pooled_distributions,
            individual_dataset=distributions,
        )
        absolute_n3_2m = distribution_plot(
            "comparison-n3-2m", "latency_us",
            "2 млн/с, N=3: абсолютная задержка",
            "Сквозная задержка, мкс",
            pooled_distributions,
            individual_dataset=distributions,
        )
        centered_2m = distribution_plot(
            "comparison-n3-2m", "latency_us",
            "Диагностика формы: отклонение от p50 каждого узла",
            "Отклонение от p50, мкс (не абсолютная задержка)",
            pooled_fanout, "delivered-to-all-centered", tail_only=True,
            individual_dataset=fanout,
        )
        centered_2m.add_layout(Span(
            location=0, dimension="width", line_color=GRAY,
            line_dash="dashed", line_width=2,
        ))
        receiver_n3_2m = receiver_summary_plot(
            "comparison-n3-2m",
            "2 млн/с, N=3: доставка отдельным получателям",
        )
        comparison_2m_grid = gridplot(
            [[absolute_n1_2m, absolute_n3_2m]], sizing_mode="stretch_width"
        )
        show(with_scale_switch(
            comparison_2m_grid, [absolute_n1_2m, absolute_n3_2m], default_log=True,
        ))
        show(with_scale_switch(
            receiver_n3_2m, [receiver_n3_2m], default_log=True
        ))
        show(centered_2m)
        """
    ),
    markdown(
        """
        Равновзвешенная кривая отвечает на вопрос о задержке доставки одному
        равновероятно выбранному адресату: исходные наблюдения трёх receiver
        объединены с одинаковым весом. Пунктирная средняя кривая сначала считает
        `(L1 + L2 + L3) / 3` для каждого события, а затем строит распределение.
        Основной результат рассылки задаёт отдельная абсолютная кривая
        `max(L1, L2, L3)` — время доставки всем.
        """
    ),
    markdown(
        """
        ### Плотность центральной части: наш и Claude на одном графике

        Квантильные кривые показывают уровень задержки на всём диапазоне
        вероятностей и подробно раскрывают оба хвоста. Сглаженная эмпирическая
        плотность ниже отвечает на другой вопрос: где сосредоточена основная
        масса наблюдений, насколько распределение асимметрично и есть ли у него
        несколько пиков. Синий цвет обозначает наш DPDK, красный — Claude.
        Сдвиг пика влево соответствует меньшей типичной задержке, а его ширина
        показывает разброс основной массы событий.

        Толстые линии и заливка объединяют все шесть блоков реализации на одной
        частоте. Тонкие полупрозрачные линии показывают отдельные
        блоков: сплошные для нечётного порядка `Claude → DPDK`, пунктирные для
        чётного `DPDK → Claude`. Толстые кривые показывают объединённый центр,
        тонкие — межблочный разброс. Статистический вывод строится по шести
        парным разностям выше. У кривых одинаковая шкала X; дальние хвосты
        представлены полными квантильными графиками.
        """
    ),
    code(
        """
        def density_plot(
            group: str, title: str, pooled_data=None, individual_data=None
        ):
            pooled_data = pooled_density if pooled_data is None else pooled_data
            individual_data = density if individual_data is None else individual_data
            subset = pooled_data[pooled_data["group"] == group]
            individual = individual_data[individual_data["group"] == group]
            plot = figure(
                height=350, sizing_mode="stretch_width", title=title,
                x_axis_label="Сквозная задержка, мкс",
                y_axis_label="Эмпирическая плотность, 1/мкс",
                tools="pan,box_zoom,reset,save",
            )
            for (implementation, block), frame in individual.groupby(
                ["implementation", "block"], sort=True
            ):
                is_claude = implementation == "claude-c86cc26"
                label = "Claude" if is_claude else "Наш DPDK"
                source = ColumnDataSource({
                    "latency_us": frame["latency_us"],
                    "density_per_us": frame["density_per_us"],
                    "label": [label] * len(frame),
                    "block": [str(int(block))] * len(frame),
                })
                plot.line(
                    "latency_us", "density_per_us", source=source,
                    color=RED if is_claude else BLUE,
                    line_dash="solid" if int(block) % 2 else "dashed",
                    line_width=1.3, alpha=0.20,
                )
            for implementation, frame in subset.groupby("implementation", sort=True):
                is_claude = implementation == "claude-c86cc26"
                color = RED if is_claude else BLUE
                label = "Claude" if is_claude else "Наш DPDK"
                source = ColumnDataSource({
                    "latency_us": frame["latency_us"],
                    "density_per_us": frame["density_per_us"],
                    "label": [label] * len(frame),
                    "block": ["все"] * len(frame),
                })
                plot.varea(
                    x="latency_us", y1=0, y2="density_per_us", source=source,
                    fill_color=color, fill_alpha=0.12,
                )
                plot.line(
                    "latency_us", "density_per_us", source=source,
                    color=color, line_width=3, legend_label=label,
                )
            plot.legend.location = "top_right"
            plot.legend.click_policy = "hide"
            plot.add_tools(HoverTool(tooltips=[
                ("Реализация", "@label"),
                ("Блок", "@block"),
                ("Задержка", "@latency_us{0.000} мкс"),
                ("Плотность", "@density_per_us{0.0000}"),
            ]))
            return plot

        density_plots = [
            density_plot("comparison-n1-200k", "N=1, 200 тыс./с"),
            density_plot("comparison-n1-2m", "N=1, 2 млн/с"),
            density_plot("comparison-n3-200k", "N=3, 200 тыс./с"),
            density_plot("comparison-n3-2m", "N=3, 2 млн/с"),
        ]
        show(gridplot([
            density_plots[:2], density_plots[2:],
        ], sizing_mode="stretch_width"))
        """
    ),
    markdown(
        """
        ### Как представлены различия получателей

        Отчёт показывает пять взаимодополняющих срезов:

        1. максимальную задержку трёх receiver для каждого `seq_id` — основной
           результат «доставлено всем»;
        2. равновзвешенное объединение всех receiver-наблюдений — распределение
           доставки одному равновероятно выбранному адресату;
        3. среднее трёх задержек каждого события — среднюю цену одной доставки
           внутри рассылки;
        4. отдельную кривую каждого receiver после вычитания только его
           собственного p50 — форму джиттера без постоянного сдвига часов;
        5. развитие превышения над p50 по `seq_id`, чтобы отличить единичный выброс
           от очереди, которая накапливается и затем разгребается.

        В абсолютных графиках логарифмическая шкала Y включена по умолчанию.
        p50-центрированные графики являются отдельной диагностикой правого хвоста:
        они начинаются с p50, а Y у них остаётся линейной.

        Критерии качества запуска задаются до анализа: корректные часы,
        непрерывная доставка без дублей и перестановок, тот же пакет и та же
        топология. Все показанные серии им соответствуют.
        """
    ),
    code(
        """
        centered_receivers = fanout[
            (fanout["group"] == "comparison-n3-2m")
            & (fanout["pair_round"] == 1)
            & fanout["metric"].str.startswith("receiver:")
            & (fanout["quantile"] >= 0.5)
            & (fanout["quantile"] < 1.0)
        ].copy()

        receiver_plot = figure(
            height=390, sizing_mode="stretch_width",
            x_axis_type="log", x_range=(0.5, 1e-5),
            title="Диагностика: отклонение каждого receiver от собственного p50",
            x_axis_label="Правый хвост: от p50 до p99.999",
            y_axis_label="Отклонение от p50, мкс (не абсолютная задержка)",
            tools="pan,box_zoom,reset,save",
        )
        dashes = ["solid", "dashed", "dotdash"]
        for (implementation, metric), frame in centered_receivers.groupby(
            ["implementation", "metric"], sort=True
        ):
            receiver_id = metric.split(":", 1)[1]
            receiver_number = sorted(centered_receivers["metric"].unique()).index(metric) + 1
            color = RED if implementation == "claude-c86cc26" else BLUE
            label = ("Claude" if implementation == "claude-c86cc26" else "DPDK") + f", receiver {receiver_number}"
            receiver_plot.line(
                frame["tail_probability"], frame["latency_minus_p50_us"],
                color=color, line_dash=dashes[receiver_number - 1], line_width=2,
                alpha=0.85, legend_label=label,
            )
        configure_tail_probability_axis(receiver_plot)
        receiver_plot.add_layout(Span(
            location=0, dimension="width", line_color=GRAY,
            line_dash="dashed", line_width=2,
        ))
        receiver_plot.legend.location = "top_left"
        receiver_plot.legend.click_policy = "hide"

        seq_subset = sequence[
            (sequence["group"] == "comparison-n3-2m")
            & (sequence["pair_round"] == 1)
        ].copy()
        seq_subset["million_events"] = seq_subset.groupby(
            ["run_id", "receiver_instance_id", "repetition"]
        )["seq_start"].transform(lambda values: (values - values.min()) / 1e6)
        sequence_plot = figure(
            height=390, sizing_mode="stretch_width",
            title="2 млн/с, пара 1: худшее превышение над p50 в окне 1000 событий",
            x_axis_label="Млн измеренных событий", y_axis_label="Максимум сверх p50, мкс",
            tools="pan,box_zoom,reset,save",
        )
        for (implementation, receiver_id), frame in seq_subset.groupby(
            ["implementation", "receiver_instance_id"], sort=True
        ):
            receiver_number = sorted(seq_subset["receiver_instance_id"].unique()).index(receiver_id) + 1
            color = RED if implementation == "claude-c86cc26" else BLUE
            sequence_plot.line(
                frame["million_events"], frame["max_excess_us"],
                color=color, line_dash=dashes[receiver_number - 1], alpha=0.75,
                line_width=2,
                legend_label=("Claude" if implementation == "claude-c86cc26" else "DPDK") + f", receiver {receiver_number}",
            )
        sequence_plot.legend.location = "top_left"
        sequence_plot.legend.click_policy = "hide"
        show(receiver_plot)
        show(with_scale_switch(
            sequence_plot, [sequence_plot], default_log=True
        ))

        tail_table = (
            tail_bursts.groupby(["group", "implementation", "pair_round"], as_index=False)
            .agg(
                событий_сверх_50_мкс=("events_above_threshold", "sum"),
                эпизодов=("episode_count", "sum"),
                самый_длинный_эпизод=("longest_episode_events", "max"),
                максимум_сверх_p50_мкс=("max_excess_us", "max"),
            )
        )
        tail_table["Конфигурация"] = tail_table["group"].map({
            "comparison-n1-200k": "N=1, 200 тыс./с",
            "comparison-n1-2m": "N=1, 2 млн/с",
            "comparison-n3-200k": "N=3, 200 тыс./с",
            "comparison-n3-2m": "N=3, 2 млн/с",
        })
        tail_table["Реализация"] = tail_table["implementation"].map({
            "claude-c86cc26": "Claude", "spectral-task": "Наш DPDK"
        })
        show_table(tail_table[[
            "Конфигурация", "pair_round", "Реализация", "событий_сверх_50_мкс",
            "эпизодов", "самый_длинный_эпизод", "максимум_сверх_p50_мкс",
        ]].rename(columns={
            "pair_round": "Пара", "событий_сверх_50_мкс": "Событий > p50+50 мкс",
            "эпизодов": "Эпизодов", "самый_длинный_эпизод": "Самый длинный, событий",
            "максимум_сверх_p50_мкс": "Максимум сверх p50, мкс",
        }).round(3))
        """
    ),
    markdown(
        """
        Таблица считает всплески отдельно для `N=1` и `N=3`, каждой реализации и
        каждого блока. Для `N=3` временная диаграмма первого блока показывает все
        три receiver: выкинуть «неудачный» узел задним числом нельзя. Наличие
        эпизодов само по себе не доказывает конкретный механизм внутри kernel UDP
        или DPDK; центрирование здесь объясняет форму и временную структуру, а не
        улучшает результат.
        """
    ),
    markdown(
        """
        ## Зависимость задержки от частоты и точки насыщения

        Все точки ниже относятся к одному созданию EC2, `N=3`, компактному формату
        без потери данных и широкой LLQ. В `4 млн/с` показаны два запуска: с
        недостаточной целью пачки 3 и с исправленной целью 6. Текущий
        автоматический режим выбирает минимум
        `ceil(rate × N / 2 млн пакетов/с)`; при цели 1 ожидание равно нулю.
        """
    ),
    code(
        """
        rate = runs[runs["group"] == "rate-sweep"].copy()
        healthy = rate[(rate["pps_exceeded"] == 0) & (rate["bw_out_exceeded"] == 0)].sort_values("rate_events_s")
        saturated = rate[(rate["pps_exceeded"] > 0) | (rate["bw_out_exceeded"] > 0)]

        latency_plot = figure(
            height=400, sizing_mode="stretch_width",
            title="Перцентили доставки всем в зависимости от частоты",
            x_axis_label="Частота генерации, млн событий/с",
            y_axis_label="Задержка, мкс",
            tools="pan,box_zoom,reset,save",
        )
        metrics = [
            ("p50_us", "p50", BLUE, "solid"),
            ("p99_us", "p99", GREEN, "solid"),
            ("p999_us", "p99.9", ORANGE, "solid"),
            ("p9999_us", "p99.99", GRAY, "dashed"),
        ]
        for column, label, color, dash in metrics:
            latency_plot.line(
                healthy["rate_events_s"] / 1e6, healthy[column],
                color=color, line_width=2.5, line_dash=dash, legend_label=label,
            )
            latency_plot.scatter(
                healthy["rate_events_s"] / 1e6, healthy[column],
                color=color, size=8,
            )
            latency_plot.scatter(
                saturated["rate_events_s"] / 1e6, saturated[column],
                color=color, marker="x", size=13, line_width=3,
            )
        latency_plot.legend.location = "top_left"

        pps_plot = figure(
            height=400, sizing_mode="stretch_width",
            title="Суммарная частота отправки после упаковки",
            x_axis_label="Частота генерации, млн событий/с",
            y_axis_label="Оценка исходящих пакетов, млн/с",
            tools="pan,box_zoom,reset,save",
        )
        colors = np.where(rate["pps_exceeded"] > 0, RED,
                          np.where(rate["bw_out_exceeded"] > 0, ORANGE, BLUE))
        pps_plot.scatter(
            rate["rate_events_s"] / 1e6, rate["estimated_packets_s"] / 1e6,
            color=colors, size=11,
        )
        pps_plot.add_layout(Span(
            location=2.0, dimension="width", line_color=RED,
            line_dash="dashed", line_width=2,
        ))
        pps_plot.add_tools(HoverTool(tooltips=[
            ("Частота", "@x{0.0} млн событий/с"),
            ("Пакеты", "@y{0.000} млн/с"),
        ]))

        rate_grid = gridplot(
            [[latency_plot, pps_plot]], sizing_mode="stretch_width"
        )
        show(with_scale_switch(
            rate_grid, [latency_plot, pps_plot], default_log=True
        ))

        rate_table = rate[[
            "label_ru", "batch_target_frames", "frames_per_datagram",
            "estimated_packets_s", "p50_us", "p999_us",
            "pps_exceeded", "bw_out_exceeded", "delivery_valid",
        ]].copy()
        rate_table["estimated_packets_s"] /= 1e6
        show_table(rate_table.rename(columns={
            "label_ru": "Режим",
            "batch_target_frames": "Цель пачки",
            "frames_per_datagram": "Событий/дейтаграмму",
            "estimated_packets_s": "Млн пакетов/с",
            "p50_us": "p50, мкс",
            "p999_us": "p99.9, мкс",
            "pps_exceeded": "Счётчик PPS",
            "bw_out_exceeded": "Счётчик полосы",
            "delivery_valid": "Доставка корректна",
        }).round(3).reset_index(drop=True))
        """
    ),
    markdown(
        """
        При `4 млн/с` недостаточная цель 3 дала в среднем `4,620` события в
        дейтаграмме и около `2,60 млн` исходящих пакетов/с. Счётчик
        `pps_exceeded` вырос до `4 465 625`, а суммарно по трём получателям
        обнаружено `458 552` пропуска. p50 сохранившихся общих событий достиг
        `725,653 мкс`, но задержки невалидной доставки служат только симптомом
        очереди. При автоматической цели 6 поток снизился до `1,93 млн`
        пакетов/с, счётчик и пропуски исчезли, p50 стал `18,161 мкс`. Это
        причинно подтверждённая PPS-граница.

        При `4,5 млн/с` все аппаратные счётчики нулевые, доставка полная, p99.9
        равен `27,488 мкс`. При `5 млн/с` PPS уже не мешает, но
        `bw_out_exceeded=566 080`; три получателя потеряли соответственно около
        `0,169%`, `0,187%` и `0,597%` событий. Поэтому последняя чистая рабочая
        точка этой серии — `4,5 млн/с`, а `5 млн/с` является наблюдаемой границей
        исходящей полосы.
        Следующие способы сдвинуть границу — сократить число передаваемых байтов
        на событие, выбрать инстанс с большей сетевой полосой или распределить
        трафик между дополнительными ENI.
        """
    ),
    markdown(
        """
        ## Масштабирование по числу получателей

        Срез `N=1,2,3` выполнен при `2 млн событий/с` после основной матрицы на
        тех же EC2. Между получателями присутствует постоянное смещение часов,
        поэтому график показывает ширину хвоста `pX - p50`, инвариантную к
        постоянному сдвигу шкалы. Абсолютный p50 оставлен в таблице, но его рост
        нельзя целиком приписывать fan-out: при `N=2` и `N=3` в максимум входят
        новые физические receiver со своими clock offset. Все диапазоны доставлены
        полностью. При росте N целевая пачка должна расти так, чтобы суммарная
        частота TX оставалась ниже PPS-предела.

        Сам график ниже сравнивает три режима **нашего DPDK**. Отдельная
        контрсбалансированная матрица выше уже отвечает на вопрос Claude ↔ DPDK
        для `N=1` и `N=3`; `N=2` остаётся функциональным промежуточным срезом.
        """
    ),
    code(
        """
        receiver_sweep = runs[runs["group"] == "receiver-sweep"].sort_values("receivers").copy()
        receiver_sweep["p99_minus_p50"] = receiver_sweep["p99_us"] - receiver_sweep["p50_us"]
        receiver_sweep["p999_minus_p50"] = receiver_sweep["p999_us"] - receiver_sweep["p50_us"]
        receiver_sweep["p9999_minus_p50"] = receiver_sweep["p9999_us"] - receiver_sweep["p50_us"]

        n_plot = figure(
            height=370, sizing_mode="stretch_width",
            title="Ширина хвоста при 2 млн событий/с",
            x_axis_label="Число физических получателей N",
            y_axis_label="Перцентиль минус p50, мкс",
            tools="pan,box_zoom,reset,save",
        )
        for column, label, color in [
            ("p99_minus_p50", "p99 − p50", GREEN),
            ("p999_minus_p50", "p99.9 − p50", ORANGE),
            ("p9999_minus_p50", "p99.99 − p50", GRAY),
        ]:
            n_plot.line(receiver_sweep["receivers"], receiver_sweep[column],
                        color=color, line_width=2.5, legend_label=label)
            n_plot.scatter(receiver_sweep["receivers"], receiver_sweep[column],
                           color=color, size=9)
        n_plot.xaxis.ticker = [1, 2, 3]
        n_plot.legend.location = "top_left"
        show(with_scale_switch(n_plot, [n_plot], default_log=True))

        n_table = receiver_sweep[[
            "receivers", "batch_target_frames", "batch_wait_ns", "frames_per_datagram",
            "estimated_packets_s", "p50_us", "p99_minus_p50",
            "p999_minus_p50", "p9999_minus_p50",
            "gaps", "duplicates", "reordered", "delivery_valid",
        ]].copy()
        n_table["estimated_packets_s"] /= 1e6
        show_table(n_table.rename(columns={
            "receivers": "N",
            "batch_target_frames": "Цель пачки",
            "batch_wait_ns": "Макс. ожидание, нс",
            "frames_per_datagram": "Событий/дейтаграмму",
            "estimated_packets_s": "Млн пакетов/с",
            "p50_us": "Абсолютный p50, мкс",
            "p99_minus_p50": "p99 − p50, мкс",
            "p999_minus_p50": "p99.9 − p50, мкс",
            "p9999_minus_p50": "p99.99 − p50, мкс",
            "gaps": "Пропуски",
            "duplicates": "Дубли",
            "reordered": "Перестановки",
            "delivery_valid": "Доставка корректна",
        }).round(3).reset_index(drop=True))
        """
    ),
    markdown(
        """
        Автоматическая цель пачки растёт вместе с `N`, поэтому суммарная частота
        TX должна оставаться близкой к одному уровню вместо линейного роста до
        трёхкратного PPS. Абсолютный p50 и ширина хвоста приведены рядом: первое
        включает постоянные различия физических путей/часов добавленных
        receiver, второе устойчивее к такому сдвигу. Вывод о цене fan-out делаем
        по обеим колонкам вместе с фактической наполненностью и PPS, а не по одному
        максимуму.
        """
    ),
    markdown(
        """
        ## Где находится задержка

        Диагностический запуск `2M/N=3` проставляет программные метки на границах
        приложения. По нему оценивается порядок величин отдельных участков;
        основные сквозные результаты сняты с отключённой диагностикой.

        Раскладка отдельно показывает локальный участок source
        `producer → transport`, два локальных участка receiver
        `возврат DPDK-пачки → публикация` и `receiver → consumer`, а также
        совокупный межхостовый участок. Последний включает сборку и отправку
        пакета, ENA, Nitro/VPC, физическую сеть, приём ENA и возврат DPDK-пачки.
        """
    ),
    code(
        """
        local_stages = stages[
            stages["stage_key"] != "transport_to_receiver_ns"
        ].copy()
        local_stages = pd.concat([
            local_stages[
                local_stages["stage_key"] == "source_to_transport_ns"
            ].head(1),
            local_stages[
                local_stages["stage_key"] != "source_to_transport_ns"
            ],
        ], ignore_index=True)
        local_stages["row"] = np.where(
            local_stages["stage_key"] == "source_to_transport_ns",
            "source: producer → transport",
            local_stages["receiver"] + ": " + local_stages["stage_ru"],
        )
        local_plot = figure(
            height=390, sizing_mode="stretch_width",
            y_range=list(reversed(local_stages["row"].tolist())),
            title="Доверенные локальные участки",
            x_axis_label="Задержка участка, мкс",
            tools="pan,box_zoom,reset,save",
        )
        local_source = ColumnDataSource({
            "row": local_stages["row"],
            "median": local_stages["p50_us"],
            "p99": local_stages["p99_us"],
            "meaning": local_stages["meaning_ru"],
            "color": local_stages["stage_key"].map({
                "source_to_transport_ns": BLUE,
                "dpdk_burst_to_software_receiver_ns": GREEN,
                "receiver_to_consumer_ns": ORANGE,
            }),
        })
        local_plot.segment(
            x0="median", y0="row", x1="p99", y1="row",
            color="color", line_width=5, alpha=0.55, source=local_source,
        )
        local_plot.scatter(
            x="median", y="row", color="color", size=11,
            marker="circle", source=local_source, legend_label="p50",
        )
        local_plot.scatter(
            x="p99", y="row", color="color", size=10,
            marker="diamond", source=local_source, legend_label="p99",
        )
        local_plot.legend.location = "bottom_right"
        local_plot.add_tools(HoverTool(tooltips=[
            ("Участок", "@row"), ("Медиана", "@median{0.000} мкс"),
            ("p99", "@p99{0.000} мкс"),
            ("Содержит", "@meaning"),
        ]))

        opaque_stages = stages[
            stages["stage_key"] == "transport_to_receiver_ns"
        ].copy()
        opaque_plot = figure(
            height=300, sizing_mode="stretch_width",
            y_range=list(reversed(opaque_stages["receiver"].tolist())),
            title="Совокупный межхостовый участок",
            x_axis_label="Задержка участка, мкс",
            tools="pan,box_zoom,reset,save",
        )
        opaque_source = ColumnDataSource({
            "receiver": opaque_stages["receiver"],
            "minimum": opaque_stages["min_us"],
            "median": opaque_stages["p50_us"],
            "p99": opaque_stages["p99_us"],
            "meaning": opaque_stages["meaning_ru"],
        })
        opaque_plot.segment(
            x0="minimum", y0="receiver", x1="p99", y1="receiver",
            color=RED, line_width=5, alpha=0.40, source=opaque_source,
        )
        opaque_plot.scatter(
            x="median", y="receiver", color=RED, size=11,
            marker="circle", source=opaque_source, legend_label="p50",
        )
        opaque_plot.scatter(
            x="p99", y="receiver", color=RED, size=10,
            marker="diamond", source=opaque_source, legend_label="p99",
        )
        opaque_plot.legend.location = "bottom_right"
        opaque_plot.add_tools(HoverTool(tooltips=[
            ("Получатель", "@receiver"),
            ("Минимум", "@minimum{0.000} мкс"),
            ("Медиана", "@median{0.000} мкс"),
            ("p99", "@p99{0.000} мкс"),
            ("Содержит", "@meaning"),
        ]))
        show(with_scale_switch(
            local_plot, [local_plot], axis="x", default_log=True
        ))
        show(opaque_plot)
        show_table(stages[[
            "receiver", "stage_ru", "scope_ru", "min_us", "p50_us", "p99_us",
            "p999_us",
        ]].rename(columns={
            "receiver": "Получатель",
            "stage_ru": "Участок",
            "scope_ru": "Область измерения",
            "min_us": "Минимум, мкс",
            "p50_us": "p50, мкс",
            "p99_us": "p99, мкс",
            "p999_us": "p99.9, мкс",
        }).round(3).reset_index(drop=True))
        """
    ),
    markdown(
        """
        Локальные цены устойчивы между узлами: `producer → transport` имеет p50
        `0,580 мкс`, возврат DPDK burst → программная публикация —
        `0,140 мкс`, очередь до consumer — `0,260…0,280 мкс`. Основной
        совокупный участок `transport → receiver` имеет p50
        `15,605…16,262 мкс` и одновременно содержит сборку пакета, DPDK TX,
        ENA TX, Nitro/VPC, физическую сеть, ENA RX и ожидание горячего опроса.

        Этот интервал характеризует весь межхостовый тракт приложения и сети.
        В абсолютное значение также входит остаточный сдвиг системных часов
        между source и каждым receiver. Его дальнейшее разложение потребует
        калибровки PHC data ENI, аппаратной TX-метки или внешнего tap; доступная
        инструментализация измеряет перечисленные составляющие совместно.

        Узлы находятся в дочерней `cluster` placement group внутри общей
        `precision-time` group. Все сравнения реализаций используют соседние
        плечи на этих же узлах.
        """
    ),
    markdown(
        """
        ## Дополнительные условия: `precision-time` без `cluster`

        Вторая измерительная эпоха использует четыре `m8a.xlarge` в одной
        `precision-time` placement group без дочерней `cluster`-группы. Её
        сравнительная матрица содержит `N=3`, частоты `200 тыс.` и
        `2 млн событий/с`, по шесть контрсбалансированных блоков на частоту.
        Обе реализации прогреваются `2 с`, после чего каждый receiver сохраняет
        по миллиону событий. Все 24 зачтённых плеча имеют одни instance IDs и
        package SHA, ENA PHC, поправку часов `0` и полную доставку.

        Эта эпоха анализируется отдельно от основной `precision-time → cluster`.
        Наблюдаемая абсолютная задержка включает физическое размещение и
        остаточный межхостовый сдвиг часов; разность абсолютных значений двух
        эпох не используется как причинная оценка эффекта `cluster`.
        """
    ),
    code(
        """
        precision_load_names = {200_000: "200 тыс./с", 2_000_000: "2 млн/с"}
        precision_paired = precision_comparison_blocks[
            precision_comparison_blocks["metric"].isin(
                ["p50", "p99", "p99.9", "p99.99"]
            )
        ].copy()
        precision_paired["Нагрузка"] = precision_paired["rate_events_s"].map(
            precision_load_names
        )
        precision_paired_table = (
            precision_paired.pivot_table(
                index=["Нагрузка", "block", "first_implementation", "midpoint_gap_s"],
                columns="metric",
                values="difference_spectral_minus_claude_us",
                aggfunc="first",
            )
            .reset_index()
            .rename(columns={
                "block": "Блок",
                "first_implementation": "Первым запущен",
                "midpoint_gap_s": "Расстояние середин, с",
                "p50": "Δp50, мкс",
                "p99": "Δp99, мкс",
                "p99.9": "Δp99.9, мкс",
                "p99.99": "Δp99.99, мкс",
            })
        )
        precision_paired_table["Первым запущен"] = precision_paired_table[
            "Первым запущен"
        ].map({"claude-c86cc26": "Claude", "spectral-task": "Наш DPDK"})
        show_table(precision_paired_table.round(3))

        precision_verdict = precision_comparison_statistics.copy()
        precision_verdict["Нагрузка"] = precision_verdict["rate_events_s"].map(
            precision_load_names
        )
        show_table(precision_verdict[[
            "Нагрузка", "metric", "spectral_faster_blocks", "claude_faster_blocks",
            "min_aligned_samples_per_arm",
            "median_difference_spectral_minus_claude_us", "min_difference_us",
            "max_difference_us", "sign_test_two_sided_p",
            "claude_between_block_spread_us", "resolved_by_claude_rule",
        ]].rename(columns={
            "metric": "Перцентиль",
            "spectral_faster_blocks": "Наш быстрее, блоков",
            "claude_faster_blocks": "Claude быстрее, блоков",
            "min_aligned_samples_per_arm": "Мин. совмещённых событий",
            "median_difference_spectral_minus_claude_us": "Медианная Δ, мкс",
            "min_difference_us": "Мин. Δ, мкс",
            "max_difference_us": "Макс. Δ, мкс",
            "sign_test_two_sided_p": "Знаковый p",
            "claude_between_block_spread_us": "Размах Claude, мкс",
            "resolved_by_claude_rule": "Разрешено",
        }).round(3))

        precision_quantile_names = {
            0.5: "p50", 0.99: "p99", 0.999: "p99.9", 0.9999: "p99.99",
        }
        precision_pooled_table = precision_pooled_distributions.copy()
        precision_pooled_table["Перцентиль"] = (
            precision_pooled_table["quantile"].round(5).map(precision_quantile_names)
        )
        precision_pooled_table = precision_pooled_table.dropna(
            subset=["Перцентиль"]
        )
        precision_pooled_table["Нагрузка"] = precision_pooled_table["group"].map({
            "comparison-n3-200k": "200 тыс./с",
            "comparison-n3-2m": "2 млн/с",
        })
        precision_pooled_table["Реализация"] = precision_pooled_table[
            "implementation"
        ].map({"claude-c86cc26": "Claude", "spectral-task": "Наш DPDK"})
        precision_pooled_pivot = precision_pooled_table.pivot_table(
            index=["Нагрузка", "Реализация"], columns="Перцентиль",
            values="latency_us", aggfunc="first",
        )
        precision_pooled_pivot.columns.name = None
        show_table(precision_pooled_pivot.reset_index().round(3))
        """
    ),
    markdown(
        """
        При `200 тыс./с` p99.99 лучше у нашего DPDK во всех шести блоках;
        медианная парная разность равна `−146,336 мкс` и превышает собственный
        межблочный размах Claude `86,113 мкс`. Это единственный разрешённый
        основной перцентиль этой эпохи. При `2 млн/с` медианные разности
        p50/p99/p99.9/p99.99 равны соответственно
        `−5,078/−5,106/−6,945/−136,888 мкс`, но знак и межблочный разброс не
        позволяют объявить ни одну из них разрешённой.
        """
    ),
    code(
        """
        precision_effect_specs = [
            ("comparison-n3-200k", "N=3, 200 тыс. событий/с"),
            ("comparison-n3-2m", "N=3, 2 млн событий/с"),
        ]

        def precision_effect_grid(signed_log: bool):
            plots = [
                paired_effect_plot(
                    group, title, signed_log, precision_comparison_blocks
                )
                for group, title in precision_effect_specs
            ]
            return gridplot([[plot] for plot in plots], sizing_mode="stretch_width")

        show(Tabs(tabs=[
            TabPanel(child=precision_effect_grid(False), title="Линейная шкала"),
            TabPanel(
                child=precision_effect_grid(True),
                title="Симметричная логарифмическая шкала",
            ),
        ]))
        """
    ),
    markdown(
        """
        ### Распределения и получатели в `precision-time only`

        Тонкие линии показывают каждый из шести блоков, толстые — объединённую
        описательную кривую реализации. Отдельный receiver-график совмещает три
        полупрозрачные кривые каждой реализации, равновзвешенное распределение
        доставки одному адресату и среднее трёх задержек конкретного события.
        Основной результат остаётся временем доставки всем
        `max(L1, L2, L3)`.
        """
    ),
    code(
        """
        precision_delivered_200k = distribution_plot(
            "comparison-n3-200k", "latency_us",
            "precision-time only, 200 тыс./с: событие доставлено всем",
            "Сквозная задержка, мкс", precision_pooled_distributions,
            individual_dataset=precision_distributions,
        )
        precision_receivers_200k = receiver_summary_plot(
            "comparison-n3-200k",
            "precision-time only, 200 тыс./с: отдельные получатели",
            precision_pooled_fanout,
        )
        precision_delivered_2m = distribution_plot(
            "comparison-n3-2m", "latency_us",
            "precision-time only, 2 млн/с: событие доставлено всем",
            "Сквозная задержка, мкс", precision_pooled_distributions,
            individual_dataset=precision_distributions,
        )
        precision_receivers_2m = receiver_summary_plot(
            "comparison-n3-2m",
            "precision-time only, 2 млн/с: отдельные получатели",
            precision_pooled_fanout,
        )
        for plot in [
            precision_delivered_200k, precision_receivers_200k,
            precision_delivered_2m, precision_receivers_2m,
        ]:
            show(with_scale_switch(plot, [plot], default_log=True))
        """
    ),
    code(
        """
        precision_density_plots = [
            density_plot(
                "comparison-n3-200k", "precision-time only, N=3, 200 тыс./с",
                precision_pooled_density, precision_density,
            ),
            density_plot(
                "comparison-n3-2m", "precision-time only, N=3, 2 млн/с",
                precision_pooled_density, precision_density,
            ),
        ]
        show(gridplot(
            [[plot] for plot in precision_density_plots],
            sizing_mode="stretch_width",
        ))
        """
    ),
    markdown(
        """
        ### Форма хвоста во времени

        Центрированный срез первого блока при `2 млн/с` показывает отклонение
        каждого receiver от собственного p50. Временная диаграмма считает
        максимум превышения в последовательных окнах по тысяче событий.
        Центрирование характеризует джиттер внутри эпохи и сохраняется отдельно
        от абсолютной сквозной задержки.
        """
    ),
    code(
        """
        precision_centered_receivers = precision_fanout[
            (precision_fanout["group"] == "comparison-n3-2m")
            & (precision_fanout["pair_round"] == 1)
            & precision_fanout["metric"].str.startswith("receiver:")
            & (precision_fanout["quantile"] >= 0.5)
            & (precision_fanout["quantile"] < 1.0)
        ].copy()
        precision_receiver_plot = figure(
            height=390, sizing_mode="stretch_width",
            x_axis_type="log", x_range=(0.5, 1e-5),
            title="precision-time only: отклонение receiver от собственного p50",
            x_axis_label="Правый хвост: от p50 до p99.999",
            y_axis_label="Отклонение от p50, мкс",
            tools="pan,box_zoom,reset,save",
        )
        for (implementation, metric), frame in precision_centered_receivers.groupby(
            ["implementation", "metric"], sort=True
        ):
            receiver_number = sorted(
                precision_centered_receivers["metric"].unique()
            ).index(metric) + 1
            color = RED if implementation == "claude-c86cc26" else BLUE
            label = (
                "Claude" if implementation == "claude-c86cc26" else "DPDK"
            ) + f", receiver {receiver_number}"
            precision_receiver_plot.line(
                frame["tail_probability"], frame["latency_minus_p50_us"],
                color=color, line_dash=dashes[receiver_number - 1], line_width=2,
                alpha=0.85, legend_label=label,
            )
        configure_tail_probability_axis(precision_receiver_plot)
        precision_receiver_plot.add_layout(Span(
            location=0, dimension="width", line_color=GRAY,
            line_dash="dashed", line_width=2,
        ))
        precision_receiver_plot.legend.location = "top_left"
        precision_receiver_plot.legend.click_policy = "hide"

        precision_seq_subset = precision_sequence[
            (precision_sequence["group"] == "comparison-n3-2m")
            & (precision_sequence["pair_round"] == 1)
        ].copy()
        precision_seq_subset["million_events"] = precision_seq_subset.groupby(
            ["run_id", "receiver_instance_id", "repetition"]
        )["seq_start"].transform(lambda values: (values - values.min()) / 1e6)
        precision_sequence_plot = figure(
            height=390, sizing_mode="stretch_width",
            title=(
                "precision-time only, 2 млн/с: максимум сверх p50 "
                "в окне 1000 событий"
            ),
            x_axis_label="Млн измеренных событий",
            y_axis_label="Максимум сверх p50, мкс",
            tools="pan,box_zoom,reset,save",
        )
        for (implementation, receiver_id), frame in precision_seq_subset.groupby(
            ["implementation", "receiver_instance_id"], sort=True
        ):
            receiver_number = sorted(
                precision_seq_subset["receiver_instance_id"].unique()
            ).index(receiver_id) + 1
            color = RED if implementation == "claude-c86cc26" else BLUE
            precision_sequence_plot.line(
                frame["million_events"], frame["max_excess_us"],
                color=color, line_dash=dashes[receiver_number - 1], alpha=0.75,
                line_width=2,
                legend_label=(
                    "Claude" if implementation == "claude-c86cc26" else "DPDK"
                ) + f", receiver {receiver_number}",
            )
        precision_sequence_plot.legend.location = "top_left"
        precision_sequence_plot.legend.click_policy = "hide"
        show(precision_receiver_plot)
        show(with_scale_switch(
            precision_sequence_plot, [precision_sequence_plot], default_log=True
        ))

        precision_tail_table = (
            precision_tail_bursts.groupby(
                ["group", "implementation", "pair_round"], as_index=False
            )
            .agg(
                событий_сверх_50_мкс=("events_above_threshold", "sum"),
                эпизодов=("episode_count", "sum"),
                самый_длинный_эпизод=("longest_episode_events", "max"),
                максимум_сверх_p50_мкс=("max_excess_us", "max"),
            )
        )
        precision_tail_table["Нагрузка"] = precision_tail_table["group"].map({
            "comparison-n3-200k": "200 тыс./с",
            "comparison-n3-2m": "2 млн/с",
        })
        precision_tail_table["Реализация"] = precision_tail_table[
            "implementation"
        ].map({"claude-c86cc26": "Claude", "spectral-task": "Наш DPDK"})
        show_table(precision_tail_table[[
            "Нагрузка", "pair_round", "Реализация", "событий_сверх_50_мкс",
            "эпизодов", "самый_длинный_эпизод", "максимум_сверх_p50_мкс",
        ]].rename(columns={
            "pair_round": "Блок",
            "событий_сверх_50_мкс": "Событий > p50+50 мкс",
            "эпизодов": "Эпизодов",
            "самый_длинный_эпизод": "Самый длинный, событий",
            "максимум_сверх_p50_мкс": "Максимум сверх p50, мкс",
        }).round(3))
        """
    ),
    markdown(
        """
        ### Нагрузка в `precision-time only`

        Нагрузочный срез использует наш DPDK при `N=3`. Рабочие точки показаны
        линиями, а точки с аппаратным ограничением — крестами. Принудительная
        цель пачки 3 при `4 млн/с` служит объявленным отрицательным контролем.
        """
    ),
    code(
        """
        precision_rate = precision_runs[
            precision_runs["group"] == "rate-sweep"
        ].copy()
        precision_healthy = precision_rate[
            (precision_rate["pps_exceeded"] == 0)
            & (precision_rate["bw_out_exceeded"] == 0)
        ].sort_values("rate_events_s")
        precision_limited = precision_rate[
            (precision_rate["pps_exceeded"] > 0)
            | (precision_rate["bw_out_exceeded"] > 0)
        ]
        precision_latency_plot = figure(
            height=400, sizing_mode="stretch_width",
            title="precision-time only: задержка в зависимости от частоты",
            x_axis_label="Частота генерации, млн событий/с",
            y_axis_label="Задержка доставки всем, мкс",
            tools="pan,box_zoom,reset,save",
        )
        for column, label, color, dash in [
            ("p50_us", "p50", BLUE, "solid"),
            ("p99_us", "p99", GREEN, "solid"),
            ("p999_us", "p99.9", ORANGE, "solid"),
            ("p9999_us", "p99.99", GRAY, "dashed"),
        ]:
            precision_latency_plot.line(
                precision_healthy["rate_events_s"] / 1e6,
                precision_healthy[column], color=color, line_width=2.5,
                line_dash=dash, legend_label=label,
            )
            precision_latency_plot.scatter(
                precision_healthy["rate_events_s"] / 1e6,
                precision_healthy[column], color=color, size=8,
            )
            precision_latency_plot.scatter(
                precision_limited["rate_events_s"] / 1e6,
                precision_limited[column], color=color, marker="x", size=13,
                line_width=3,
            )
        precision_latency_plot.legend.location = "top_left"

        precision_pps_plot = figure(
            height=400, sizing_mode="stretch_width",
            title="precision-time only: частота отправки после упаковки",
            x_axis_label="Частота генерации, млн событий/с",
            y_axis_label="Оценка исходящих пакетов, млн/с",
            tools="pan,box_zoom,reset,save",
        )
        precision_colors = np.where(
            precision_rate["pps_exceeded"] > 0, RED,
            np.where(precision_rate["bw_out_exceeded"] > 0, ORANGE, BLUE),
        )
        precision_pps_plot.scatter(
            precision_rate["rate_events_s"] / 1e6,
            precision_rate["estimated_packets_s"] / 1e6,
            color=precision_colors, size=11,
        )
        precision_pps_plot.add_layout(Span(
            location=2.0, dimension="width", line_color=RED,
            line_dash="dashed", line_width=2,
        ))
        precision_rate_grid = gridplot(
            [[precision_latency_plot], [precision_pps_plot]],
            sizing_mode="stretch_width",
        )
        show(with_scale_switch(
            precision_rate_grid,
            [precision_latency_plot, precision_pps_plot],
            default_log=True,
        ))

        precision_rate_table = precision_rate[[
            "label_ru", "batch_target_frames", "frames_per_datagram",
            "estimated_packets_s", "p50_us", "p999_us", "pps_exceeded",
            "bw_out_exceeded", "gaps", "delivery_valid",
        ]].copy()
        precision_rate_table["estimated_packets_s"] /= 1e6
        show_table(precision_rate_table.rename(columns={
            "label_ru": "Режим",
            "batch_target_frames": "Цель пачки",
            "frames_per_datagram": "Событий/дейтаграмму",
            "estimated_packets_s": "Млн пакетов/с",
            "p50_us": "p50, мкс",
            "p999_us": "p99.9, мкс",
            "pps_exceeded": "Счётчик PPS",
            "bw_out_exceeded": "Счётчик полосы",
            "gaps": "Пропуски",
            "delivery_valid": "Доставка корректна",
        }).round(3).reset_index(drop=True))
        """
    ),
    markdown(
        """
        При `4 млн/с` цель 3 дала `pps_exceeded=2 005 449`, `231` пропуск и
        p50 сохранившихся общих событий `786,239 мкс`. Автоматическая цель 6
        снизила поток до `1,928 млн пакетов/с`, обнулила счётчик и пропуски;
        p50 составил `126,773 мкс`. Точка `4,5 млн/с` прошла с нулевыми
        аппаратными счётчиками. При `5 млн/с` доставка осталась полной, но
        `bw_out_exceeded=1 507` уже обозначил границу исходящей полосы.

        Итого эта эпоха даёт самостоятельный набор результатов для
        `precision-time only`: тот же протокол анализа `N=3` и нагрузки, но без
        парного `N=1` и без раскладки тракта. Её абсолютная область порядка
        `100–130 мкс` публикуется как свойство совокупных условий эпохи.
        """
    ),
    markdown(
        """
        ## Гипотезы и сила проверки

        Для каждой строки отдельно указан тип проверки. Строгая шестиблочная
        серия разрешает сквозной эффект; внутрисерийный ABBA устраняет общий
        межхостовый сдвиг; локальный `perf` устанавливает механизм и верхнюю
        границу вычислительного выигрыша. Соседние одиночные прогоны используются
        для выбора сдаваемой настройки с явно указанной областью вывода.

        | Гипотеза | Статус | Основание | Измеренный вывод |
        |---|---|---|---|
        | Одинаковый прогрев обязателен для сравнения | подтверждена методически | контроль методики и финальная матрица | Обе реализации получают ровно `2 с` прогрева; серии с другим правилом исключены из сравнения. |
        | Хвост Claude создаёт только один аномальный receiver | отвергнута | шесть блоков и отдельные receiver-ряды | После одинакового прогрева эпизоды `> p50+50 мкс` встречаются на всех трёх узлах и у обеих реализаций. У Claude они чаще и длиннее; внутренний механизм хвоста этой проверкой не определяется. |
        | Максимум готовых per-receiver перцентилей измеряет доставку всем | отвергнута математически | совмещение событий по `seq_id` | Для каждого события сначала берётся самый поздний receiver, затем по полученному ряду считаются перцентили. |
        | Компактный формат пересекает порог Wide LLQ | подтверждена локально для p50/p99 | внутрисерийный ABBA и контроль с обычным LLQ | Уменьшение Book `234 → 224 Б` дало около `0,47–0,55 мкс` по среднему/p50/p99. p99.9 и самостоятельный эффект в рабочей трёхсобытийной пачке требуют строгой полной серии. |
        | Пачки нужны около PPS-предела | подтверждена | функциональное сравнение и аппаратный `pps_exceeded`, эффект повторялся в разных эпохах | При `4M/N=3` цель 3 дала `4 465 625` превышений PPS, `458 552` суммарных пропуска и p50 `725,653 мкс`; цель 6 обнулила счётчик и пропуски, p50 стал `18,161 мкс`. |
        | Калибровки PHC управляющего ENI достаточно для количественного использования RX-метки измерительного ENI | отвергнута для требуемой точности | проверка валидности шкал | Наблюдались физически невозможные отрицательные интервалы. Количественная раскладка использует программные метки, а аппаратная RX-метка остаётся диагностической. |
        | Один общий TX-вызов на всю рассылку уменьшит задержку | число вызовов сокращено; выигрыш задержки не подтверждён | счётчики и два соседних повтора | Число пакетов на вызов устойчиво выросло примерно `1 → 3`; направленный сдвиг задержки не повторился. Изменение оставлено ради вычислительного запаса. |
        | `sendmsg`/`iovec` по разрозненным SPSC-слотам ускорит UDP через ядро | отвергнута для проверенной раскладки | соседние проверки при `2M/4M` и десять временных окон | Пропускная способность не выросла; при `4M` медианы окон составляли `61,5–62,3 мкс` для последовательной копии и `131,4–132,3 мкс` для `iovec`. Новая непрерывная раскладка или многосегментный DPDK являются отдельной гипотезой. |
        | Порог возврата RX-буферов 256/512 лучше 128 | крупный выигрыш отвергнут; малый эффект 256 не подтверждён | локальный `perf` и одна упорядоченная профилированная серия | Число пополнений уменьшается вдвое, но p50 одного пополнения растёт `1,12 → 2,00 → 3,47 мкс`, p99.9 — `1,57 → 3,26 → 7,39 мкс`; верхняя оценка экономии равна `0,094%/0,182%` ядра. Единственный сквозной срез дал p99.9 `83,168 → 88,730 → 92,484 мкс`. Для сдаваемого режима оставлено 128. |
        | Явная уборка завершённых TX-пакетов уберёт хвост | отвергнута для проверенных схем на DPDK 23.11 / ENA PMD 2.8 | несколько частот уборки и локальные метки | Уборка переносила работу из `tx_burst` в пополнение резерва; устойчивого сквозного выигрыша не появилось. Повтор на финальном PMD 2.14 имеет смысл при новом профиле TX-очистки. |
        | `MBUF_FAST_FREE` уменьшит сквозную задержку | не подтверждена на ENA PMD 2.8 | одна соседняя пара `N=1/2M` | Ширина `p50…p99.9` составила `10,749` против `10,520 мкс`, что находится внутри обычного разброса. На финальном PMD 2.14 вариант не повторялся. |
        | Пакетная публикация RX и предзагрузка следующего mbuf помогут | крупный резерв отвергнут; малый эффект не подтверждён | одно локальное сравнение до/после | Участок `receiver → consumer`: p50 `200 → 240 нс`, p99.9 `2,47 → 2,52 мкс`; предзагрузка меняла отдельные точки на десятки наносекунд. |
        | TSC вместо повторного vDSO-чтения удешевит ожидание пачки | вычислительно подтверждена | `perf` до/после и функциональный `N=3` | Доля vDSO в профиле sender снизилась `69,19% → 7,52%`, а средняя пачка осталась `3,086/3,087`. Это измеренный запас CPU при прежнем дедлайне ожидания. |
        | Данные во владении DPDK без копирования являются главным следующим резервом | отложена по оценке бюджета; парная проверка не проводилась | локальный профиль и программные метки этапов | Подготовка TX занимает десятки наносекунд, локальные очереди — доли микросекунды. Возврат к этой архитектуре оправдан после более точного разложения межхостового участка или на более быстром физическом тракте. |

        Приоритет для строгой перепроверки имеют полный Wide/ordinary LLQ и
        возможный эффект общего TX-вызова на задержку. Порог `128 ↔ 256` имеет
        низкий приоритет из-за верхней оценки экономии `0,094%` ядра. Новый
        профиль TX-очистки на финальном PMD 2.14 будет основанием повторить
        явную уборку и `MBUF_FAST_FREE`; измеренный резерв пакетного RX остаётся в
        диапазоне десятков наносекунд.

        Таблица разделяет корректность механизма, размер локального резерва и
        повторяемость сквозного эффекта.
        """
    ),
    markdown(
        """
        ## Корректность, потери и ограничения отсечки

        Во всех рабочих сериях, вошедших в таблицы, измеряемые диапазоны `seq_id`
        доставлены полностью каждому получателю: без дыр, дублей и перестановок.
        Два исключения явно помечены `expected_saturation`: режим
        `4 млн/с, цель 3` служит отрицательным контролем PPS, а `5 млн/с, авто`
        фиксирует реально найденную границу исходящей полосы. Их latency не
        используется как характеристика рабочего режима.
        Компактный формат самодостаточен в каждой дейтаграмме; потеря одного
        UDP-пакета не ломает декодирование следующего. Ретрансляции нет: при
        реальной потере важнее свежесть, а пропуск обнаруживается по `seq_id` и
        номеру дейтаграммы.

        Что сознательно не выдаётся за завершённый результат:

        - искусственные `0,01…1%` потерь на AWS не использовались: kernel `netem`
          асимметричен DPDK и плохо моделирует реальную сеть. Для сдаваемой отсечки
          фиксируем семантику и счётчики, а тест через отдельный узел внесения
          помех или разные AZ оставляем будущей работой;
        - все финальные измерения сделаны в одной AZ и одной подсети; L3/меж-AZ
          поведение не экстраполируется из этих чисел;
        - абсолютная односторонняя latency ограничена точностью межхостовой
          синхронизации. Сравнения меньше сохранённой PHC-границы формулируются как
          воспроизводимый соседний A/B, а не как точная физическая разность;
        - исследованы `N=1..3`. Ретрансляционное дерево для большего N — отдельная
          архитектура и не входит в базовую задачу;
        - формальное контрсбалансированное сравнение с Claude снято для `N=1` и
          `N=3`; `N=2` остаётся только промежуточным функциональным срезом нашего
          DPDK.
        """
    ),
    markdown(
        """
        ## Дополнение: SPSC-очередь

        Это не основная часть сетевого результата, но работа закрыла реальный баг.
        Писатель до исправления мог начать перезаписывать содержимое слота до публикации
        нового номера; читатель иногда принимал смесь поколений. Исправление
        инвалидирует слот перед записью, хранит содержимое в атомарных 64-битных
        словах без блокировок и повторно проверяет номер после копирования.
        Детерминированный тест
        воспроизводит это окно; исправленная версия проходит его и ThreadSanitizer.

        Серии ниже нельзя сравнивать поперёк групп: каждая группа отвечает на один
        локальный вопрос. Их масштаб — сотни наносекунд; сетевой путь — десятки
        микросекунд.
        """
    ),
    code(
        """
        ring = pd.read_csv(ROOT / "data" / "ring-fix-ablation.csv")
        ring_summary = (
            ring.groupby(["series", "variant"], sort=False)
            .agg(
                запусков=("run", "count"),
                p50_медиана_нс=("p50_ns", "median"),
                p50_минимум_нс=("p50_ns", "min"),
                p50_максимум_нс=("p50_ns", "max"),
                p99_медиана_нс=("p99_ns", "median"),
            )
            .reset_index()
            .rename(columns={"series": "Серия", "variant": "Вариант"})
        )
        show_table(ring_summary.round(0))
        """
    ),
    markdown(
        """
        Основные выводы по очереди:

        - закрытие окна публикации стоило около `1 нс` по медиане p50;
        - полное строгое атомарное исправление в чередующейся серии изменило p50
          `194 → 159 нс` и p99 `779 → 761 нс`;
        - выравнивание payload на 8 байт и единый 64-битный цикл уменьшили p50
          исследуемого layout `228 → 198 нс`;
        - локальный курсор писателя дал `166 → 161 нс` по p50, а изменение p99
          осталось в шуме;
        - итоговая очередь обеспечивает корректную передачу владения, а её
          локальные операции остаются в диапазоне сотен наносекунд.

        """
    ),
    markdown(
        """

        ## Вывод

        Главный результат — воспроизводимый полный транспорт
        `producer → SPSC → DPDK/ENA → SPSC → consumer` с физической рассылкой
        на `1..3` отдельных получателя. Он сохраняет измерительный контракт,
        передаёт самодостаточные рыночные события, регулирует число пакетов
        ограниченным ожиданием пачки и проверяет доставку одновременно по
        `seq_id`, номерам дейтаграмм и счётчикам ENA.

        Собственная рабочая область решения на целевом `N=3` выглядит так:

        | Частота | p50 | p99 | p99.9 | p99.99 | Доставка |
        |---:|---:|---:|---:|---:|---|
        | `0,2 млн/с` | `14,171 мкс` | `17,208 мкс` | `24,271 мкс` | `55,992 мкс` | полная |
        | `2 млн/с` | `17,219 мкс` | `20,399 мкс` | `28,808 мкс` | `65,348 мкс` | полная |
        | `4 млн/с` | `18,161 мкс` | `29,165 мкс` | `42,412 мкс` | `52,452 мкс` | полная |
        | `4,5 млн/с` | `17,662 мкс` | `21,155 мкс` | `27,488 мкс` | `44,811 мкс` | полная |

        Это отдельные точки нагрузочного среза, поэтому немонотонность p99.99
        между ними описывает редкость дальнего хвоста, а не ускорение от роста
        частоты. Устойчивый практический вывод состоит в другом: до
        `4,5 млн событий/с` все три получателя получают полный диапазон, а p99.9
        остаётся в пределах `24,3…42,4 мкс`.

        При фиксированных `2 млн событий/с` рост числа получателей с `N=1` до `N=3`
        изменил время доставки всем: p50 `16,749 → 17,728 мкс`, p99
        `20,015 → 22,239 мкс`, p99.9 `28,875 → 35,327 мкс`. Все три среза
        прошли без потерь. Одиночные p99.99 равны `93,442/56,118/52,163 мкс`
        для `N=1/2/3`; их немонотонность показывает, почему дальний хвост нужно
        сопровождать полным распределением и повторами, а не трактовать как
        детерминированную цену ещё одного получателя.

        Найдены две разные границы ресурса. При `4 млн/с, N=3` искусственно
        малая цель пачки 3 превысила аппаратный лимит числа пакетов, дала
        `458 552` суммарных пропуска и p50 `725,653 мкс`; цель 6 снизила поток
        примерно до `1,93 млн пакетов/с`, обнулила пропуски и вернула p50 к
        `18,161 мкс`. При `5 млн/с` цель 8 удержала число пакетов ниже лимита,
        но ENA уже зафиксировала ограничение
        исходящей полосы и потери `0,17…0,60%` по получателям. Значит,
        укрупнение пачек снимает пакетную границу, а следующий рост требует
        уменьшать число байтов либо увеличивать сетевой ресурс.

        Сопоставление с Claude даёт этим абсолютным числам практическую шкалу:
        неизменённая референсная реализация запускалась на тех же узлах, с тем же
        прогревом и внутри тех же контрсбалансированных блоков. В `13` из `16`
        сочетаний `N × частота × перцентиль` медианная парная разность направлена в
        пользу нашего DPDK. Самый строгий критерий разрешил две победы нашего
        варианта и ни одной победы Claude. Наблюдаемая картина в основном
        соответствует результату «лучше или на уровне Claude».

        Два разрешённых выигрыша получены на низкой частоте: p50 при
        `N=3 / 200 тыс./с` и p99.99 при
        `N=1 / 200 тыс./с`. При `N=1 / 2 млн/с` все медианные оценки также в
        нашу пользу, но их величина меньше межблочного разброса Claude. Явное
        исключение из общей картины — `N=3 / 2 млн/с`: p50, p99 и p99.9
        статистически находятся на уровне Claude, а p99.99 хуже у нашего DPDK в
        пяти блоках из шести.
        Следовательно, данные поддерживают преимущественно лучший или
        сопоставимый результат, но не универсальное превосходство во всём
        диапазоне дальнего хвоста.

        Рабочие серии сняты на реальной сети второго уровня (L2) в одной AZ и
        прошли без дыр, дублей и перестановок. Самодостаточный формат задаёт
        корректное поведение после единичной потери, однако зависимость задержки
        от управляемых `0,01…1%` потерь и L3/меж-AZ каналов остаётся отдельной
        проверкой. Вместе с более строгой парной проверкой малых эффектов из
        таблицы гипотез это
        определяет границу сделанных выводов и естественное продолжение работы.
        """
    ),
]

for index, cell in enumerate(cells):
    cell["id"] = f"cell-{index:02d}"

notebook = {
    "cells": cells,
    "metadata": {
        "kernelspec": {
            "display_name": "Python 3 (spectral-task)",
            "language": "python",
            "name": "python3",
        },
        "language_info": {"name": "python", "version": "3.14"},
    },
    "nbformat": 4,
    "nbformat_minor": 5,
}

Path("analysis.ipynb").write_text(
    json.dumps(notebook, ensure_ascii=False, indent=1) + "\n",
    encoding="utf-8",
)
