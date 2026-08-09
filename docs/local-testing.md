# Локальное тестирование

Этот документ описывает локальный стенд для разработки и предварительного
измерения транспорта. Он не заменяет финальные прогоны на двух физических
машинах: локально нас прежде всего интересуют корректность, сравнительное
поведение реализаций, насыщение, потери и воспроизводимость хвостов latency.
Весь описанный ниже runtime-стенд работает непосредственно на Linux-хосте.

Текущая машина имеет 8 физических ядер и 16 logical CPU с SMT-парами
`0/8`, `1/9`, ..., `7/15`. Все CPU находятся в одном NUMA node.

## 1. Подготовка GRUB и изоляция CPU

Для benchmark используется отдельный пункт GRUB. Обычный `Ubuntu` остаётся
первым пунктом и загружается по умолчанию; isolated-конфигурация выбирается
только явно. Это позволяет использовать ноутбук как обычно и включать
изоляцию лишь на время измерений.

В benchmark-конфигурации применяется следующее разделение:

| Назначение | CPU |
|---|---|
| ОС, IRQ и housekeeping | `0-3` |
| Benchmark-процессы | `4-7` |
| SMT siblings | отключены, бывшие CPU `8-15` offline |

На текущей машине создан файл `/etc/grub.d/40_spectral`:

```grub
#!/bin/sh
exec tail -n +3 "$0"

menuentry 'Ubuntu (Spectral isolated CPUs 4-7)' \
    --class ubuntu --class gnu-linux --class gnu --class os \
    --id spectral-isolated {
    recordfail
    load_video
    set gfxpayload=$linux_gfx_mode
    insmod gzio
    insmod part_msdos
    insmod ext2

    search --no-floppy --fs-uuid --set=root f9467232-92fa-4d27-91bc-982a85b34def

    linux /vmlinuz \
        root=UUID=a75409ea-1348-4efe-88a8-078b77ab155b \
        ro quiet splash \
        modprobe.blacklist=noveau \
        i915.enable_psr=0 \
        i915.edp_vswing=2 \
        intel_idle.max_cstate=2 \
        btusb.enable_autosuspend=n \
        nosmt \
        nohz_full=4-7 \
        rcu_nocbs=4-7 \
        irqaffinity=0-3 \
        isolcpus=domain,managed_irq,4-7

    initrd /initrd.img
}
```

UUID в этом entry относятся именно к текущей машине. Перед переносом
конфигурации на другой хост их нужно получить заново:

```bash
findmnt -no UUID /boot
findmnt -no UUID /
```

Значение параметров:

| Параметр | Назначение |
|---|---|
| `nosmt` | Отключает SMT, чтобы benchmark-процесс не делил physical core с sibling thread. |
| `nohz_full=4-7` | Убирает периодический scheduler tick с CPU, на котором работает единственная userspace-задача. |
| `rcu_nocbs=4-7` | Переносит RCU callbacks с benchmark CPU на housekeeping CPU. |
| `irqaffinity=0-3` | Задаёт CPU `0-3` как affinity по умолчанию для обычных IRQ. |
| `isolcpus=domain,managed_irq,4-7` | Исключает CPU `4-7` из scheduler load balancing и просит ядро не направлять туда managed IRQ, когда это возможно. |

После создания или изменения entry необходимо пересобрать и проверить
конфигурацию GRUB:

```bash
sudo chmod 0755 /etc/grub.d/40_spectral
sudo update-grub
sudo grub-script-check /boot/grub/grub.cfg
grep -n -A25 'Spectral isolated' /boot/grub/grub.cfg
```

`grub-script-check` при успехе ничего не выводит. Для однократной загрузки
isolated entry без ручного выбора в меню:

```bash
sudo grub-reboot spectral-isolated
sudo grub-editenv /boot/grub/grubenv list
```

Перед reboot в выводе должна присутствовать строка:

```text
next_entry=spectral-isolated
```

После этого можно перезагрузиться:

```bash
sudo systemctl reboot
```

`grub-reboot` действует только на следующую загрузку. Последующий reboot снова
выберет обычный Ubuntu, поскольку isolated entry не является default.

После загрузки состояние проверяется так:

```bash
cat /proc/cmdline

printf 'online:   '
cat /sys/devices/system/cpu/online

printf 'offline:  '
cat /sys/devices/system/cpu/offline

printf 'isolated: '
cat /sys/devices/system/cpu/isolated

printf 'nohz_full: '
cat /sys/devices/system/cpu/nohz_full

printf 'SMT:      '
cat /sys/devices/system/cpu/smt/active

printf 'IRQ mask: '
cat /proc/irq/default_smp_affinity

powerprofilesctl get
```

Для текущей конфигурации ожидается:

```text
online:    0-7
offline:   8-15
isolated:  4-7
nohz_full: 4-7
SMT:       0
IRQ mask:  000f
performance
```

На 9 августа 2026 года эта конфигурация загружена и проверена: значения
соответствуют ожидаемым.

Чтобы удалить дополнительный пункт GRUB:

```bash
sudo rm -- /etc/grub.d/40_spectral
sudo update-grub
```

## 2. Подготовка системы перед прогоном

Профиль питания должен быть `performance`:

```bash
powerprofilesctl get
```

На этой машине `intel_pstate` при таком профиле по-прежнему может показывать
governor `powersave`, но `energy_performance_preference` имеет значение
`performance`. Для проверки фактического предпочтения:

```bash
cat /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference \
  | sort -u
```

Установленный `irqbalance 1.9.4` автоматически исключает CPU из
`isolcpus`/`nohz_full`, поэтому его оставляем запущенным. Он продолжает
распределять обычные аппаратные IRQ только между CPU `0-3`.

Некоторые managed IRQ NVMe-контроллеров формально имеют effective affinity на
CPU `4-7`; ядро не позволяет `irqbalance` переместить их. Пока их счётчики на
isolated CPU равны нулю. Перед и после серьёзного прогона следует сравнивать
`/proc/interrupts` и избегать дискового I/O с benchmark CPU.

`consumer` накапливает пары `(seq_id, latency_ns)` в заранее зарезервированном
массиве. При `--csv` файл открывается и записывается только после hot loop,
поэтому файловые syscalls не попадают в измеряемый интервал.

Перед измерением также следует закрыть тяжёлые фоновые приложения и следить за
температурой: длительный busy-spin на мобильном CPU может привести к thermal
throttling.

### 2.1. Сборка и тесты

Корневой Makefile собирает две независимые части проекта:

- `producer` и `consumer` — штатным `harness/Makefile`, GCC и C++17;
- `sender` и `receiver` — CMake 4.2, Clang 22, C++23 modules и libc++.

Полная сборка и проверка:

```bash
make build
make test
```

`make test` собирает проект, запускает unit-тесты harness, поднимает veth-стенд
с чистым сетевым профилем и выполняет короткий `run-test` на 5000 сообщений.
End-to-end тест проводит данные через все четыре pinned-бинарника, проверяет
отсутствие потерь и совместимость SHM layout между GCC/libstdc++ и
Clang/libc++.

После изменения кода выполняется отдельный `make build`. Последующие цели
запуска используют готовые бинарники, поэтому серия экспериментов начинается
сразу с запуска процессов.

### 2.2. Разрешения для сетевого стенда

Сетевые Make-цели используют `sudo -n`. Доступ выдаётся группе
`spectral-bench`; установленный root-owned helper входит в один из двух
namespace и запускает команду с UID и GID вызвавшего пользователя. Одноразовая
настройка выполняется из корня проекта:

```bash
make setup-sudo
```

Цель проверяет helper и sudoers через `bash -n` и `visudo`, создаёт группу
`spectral-bench`, добавляет в неё текущего пользователя, устанавливает helper
в `/usr/local/libexec` и правило в `/etc/sudoers.d`, затем проверяет
установленное правило. Команда один раз запросит пароль администратора.

После первого `make setup-sudo` нужно выйти из login-сессии и войти снова.
После этого можно запускать остальные сетевые Make-цели.

Правило разрешает создание и удаление только namespace `spectral-tx` и
`spectral-rx`, настройку только `veth-tx` и `veth-rx`, а также `netem` qdisc на
этих интерфейсах. Helper принимает только имена `spectral-tx` и `spectral-rx`,
сбрасывает capabilities, устанавливает `no_new_privs` и продолжает работу с
обычными правами вызвавшего пользователя.

Проверка после установки:

```bash
make net-up
sudo -n /usr/local/libexec/spectral-netns-exec spectral-tx /usr/bin/id
make net-status
```

### 2.3. Python-окружение и notebook

Зависимости `analysis.ipynb` описаны в корневом `pyproject.toml` и точно
зафиксированы в `uv.lock`. Проект использует Python 3.14 из `.python-version`.
Из корня репозитория окружение создаётся и синхронизируется командой:

```bash
uv sync --frozen
uv run --frozen nbstripout --install
```

Первая команда создаёт локальный каталог `.venv`, вторая один раз настраивает
локальный Git-фильтр: outputs остаются доступны в рабочем notebook, но не
попадают в diff и коммиты. Notebook запускается из этого же окружения:

```bash
uv run --frozen jupyter lab analysis.ipynb
```

В markdown-ячейках notebook описаны команды запуска экспериментов и сбора
данных. Следующие за ними code-ячейки загружают результаты, рассчитывают метрики
и строят графики.

## 3. Топология процессов и CPU

Прямое подключение проверяет только harness:

```text
producer -> shared-memory ring -> consumer
```

Полный локальный транспортный стенд должен иметь две независимые очереди и
сетевое взаимодействие между ними:

```text
producer -> SHM -> sender -> network -> receiver -> SHM -> consumer
```

Закрепление процессов:

| CPU | Процесс |
|---:|---|
| `4` | `producer` |
| `5` | `sender` |
| `6` | `receiver` |
| `7` | `consumer` |

Make-цели `run-*` запускают каждый hot-path процесс через `taskset`. Служебные
shell-процессы и запись результатов выполняются на housekeeping CPU.

`sender` и `receiver` запускаются в разных network namespace. Это меняет их
представление сетевых интерфейсов и routing table, но не создаёт отдельный IPC
namespace: обе POSIX SHM-очереди остаются доступны через общий `/dev/shm`.

Текущий transport реализован модулем `spectral.transport`. `sender` читает один
frame из TX SHM и передаёт его одним обычным UDP `sendto`.
`receiver` получает datagram блокирующим `recvfrom`, проверяет размер и
`body_len`, затем публикует frame в RX SHM. Размеры сообщений 192–576 байт
помещаются в один Ethernet MTU. Потерянный datagram остаётся пропуском
`seq_id`, который учитывает `consumer`.

## 4. Виртуальная сеть на хосте

Для первого стенда достаточно штатных средств Linux:

- `spectral-tx` — network namespace процесса `sender`;
- `spectral-rx` — network namespace процесса `receiver`;
- `veth-tx` и `veth-rx` — концы виртуального Ethernet-линка;
- `netem` — общий профиль задержки, потерь и других нарушений виртуального
  канала.

Топология выглядит так:

```text
CPU 4              CPU 5                                     CPU 6              CPU 7
producer -> TX SHM -> sender [spectral-tx] -> veth/netem -> receiver [spectral-rx] -> RX SHM -> consumer
```

### 4.1. Управление стендом через Makefile

Пользователь и агент управляют виртуальной сетью через цели корневого Makefile:

| Команда | Семантика |
|---|---|
| `make net-up` | Идемпотентно создать два namespace и чистый veth-линк без `netem`, затем проверить адреса и маршруты. |
| `make net-status` | Без изменений системы показать namespace, адреса, link state и qdisc со счётчиками. |
| `make netem-set ...` | Добавить или заменить единый профиль delay/loss виртуального линка. |
| `make netem-clear` | Идемпотентно удалить `netem`, сохранив поднятый veth-линк. |
| `make net-down` | Удалить только namespace и интерфейсы этого стенда. |

Корневой Makefile является конечным оркестратором вызовов `ip` и `tc`.

`net-up` приводит стенд к известному чистому профилю без qdisc. При совпадении
имён с ресурсами другой конфигурации цель завершает работу с понятной ошибкой.

Для первого транспорта создаётся прямой L2-линк `10.200.0.1/30` ↔
`10.200.0.2/30`. Linux bridge понадобится только для сценария с несколькими
узлами в одном L2-сегменте. Отдельный router namespace с двумя veth-парами
понадобится позднее для явного L3 hop.

### 4.2. Запуск процессов

Полный end-to-end сценарий запускается командой:

```bash
make run-test
```

Он использует `spectral-tx` ↔ `spectral-rx` через veth и активный профиль
`netem`. Цель запускает четыре pinned-процесса в правильном порядке, проверяет
их готовность, дожидается завершения, печатает метрики consumer, сохраняет логи
в `build/run-test/` и очищает SHM-сегменты. `sender` и `receiver` запускаются в
соответствующих network namespace через установленный helper.

Hot loop работает с SHM и socket API. В логи записываются сообщения о
готовности, итоговая статистика и ошибки — несколько операций до или после
цикла обработки. Детальные latency samples сначала накапливаются в RAM.

Для ручной отладки доступны отдельные цели:

| Команда | CPU | Network namespace |
|---|---:|---|
| `make run-producer` | `4` | host |
| `make run-sender` | `5` | `spectral-tx` |
| `make run-receiver` | `6` | `spectral-rx` |
| `make run-consumer` | `7` | host |

Каждая цель запускает процесс в foreground. После `make net-up` ручной прогон
запускается в четырёх терминалах в следующем порядке:

```bash
make run-receiver
make run-consumer
make run-producer
make run-sender
```

Такой порядок сначала подготавливает UDP socket и RX SHM, затем создаёт TX SHM.
`sender` начинает чтение с live edge producer, поэтому startup backlog не
попадает в latency-метрики.

Рецепты закрепляют процессы за указанными CPU и помещают `sender`/`receiver` в
соответствующие namespace. Основные параметры прогона задаются в командной
строке Make:

```bash
make run-test MESSAGE_COUNT=5000000 MESSAGE_RATE=200000 SHM_SLOTS=65536
```

`MESSAGE_COUNT` задаёт число сообщений producer. `sender` подключается к live
edge TX-очереди, поэтому сообщения, созданные во время запуска процессов, не
попадают в измеряемый поток; фактическое число показывает итоговая статистика.
Опциональный `LATENCY_CSV=/path/to/file.csv` включает сохранение per-message
latency силами consumer после завершения hot loop; этот режим используется для
подготовки данных notebook.

Адрес receiver по умолчанию — `10.200.0.2`, UDP port — `9000`. Проверка PID,
всех TID и affinity во время ручного прогона:

```bash
make process-status
```

### 4.3. Добавление `netem`

Сначала нужен контрольный прогон после чистого `make net-up`. Затем можно
добавить, например, фиксированную задержку 50 us:

```bash
make netem-set NETEM_DELAY=50us
```

Добавить потери:

```bash
make netem-set NETEM_DELAY=50us NETEM_LOSS=0.1%
```

Посмотреть активную дисциплину и её счётчики:

```bash
make net-status
```

Удалить эмуляцию, не удаляя линк:

```bash
make netem-clear
```

В первой версии нужны следующие параметры:

| Параметр Make | Значение | Смысл |
|---|---|---|
| `NETEM_DELAY` | duration, например `50us` или `1ms` | Фиксированная задержка пакета. |
| `NETEM_JITTER` | duration, например `5us` | Вариация задержки; допустима только вместе с `NETEM_DELAY`. |
| `NETEM_LOSS` | percentage, например `0.1%` | Независимая вероятность потери пакета. |
| `NETEM_LIMIT` | целое число пакетов | Размер внутренней очереди; default `100000`. |

Параметры задаются в командной строке GNU Make. Makefile проверяет их и
формирует соответствующие вызовы `tc`.

Makefile проверяет единицы, диапазон loss `0..100%`, целочисленный limit и
зависимость jitter от delay до вызова `tc`. Чистый профиль применяется командой
`make netem-clear` и не содержит qdisc `netem`.

`netem-set` задаёт один симметричный профиль виртуального линка: Makefile
устанавливает одинаковые qdisc на egress обоих концов veth-пары. В основном
UDP data path пакеты идут только от `sender` к `receiver` и проходят профиль
один раз. Если у протокола появится обратный control traffic, он автоматически
окажется в тех же сетевых условиях.

Значения в примерах образуют демонстрационный профиль. Параметры целевых L2- и
L3-сценариев подбираются по условиям задачи или замерам реального окружения и
сохраняются вместе с результатами.

Отдельные namespace и veth ограничивают действие профиля интерфейсами стенда.

### 4.4. Очистка

Сначала нужно остановить `sender` и `receiver`, затем выполнить:

```bash
make net-down
```

Цель проверяет процессы внутри namespace. При активных процессах она выводит
их список и сохраняет стенд; после их остановки удаляет namespace, veth-пару и
привязанные qdisc. Область действия ограничена точными именами ресурсов стенда.

Make запускается от обычного пользователя. Сетевые цели повышают права только
для конкретных вызовов `ip` и `tc`, а файлы сборки и результаты benchmark
остаются собственностью пользователя.

## 5. Последовательность локальных экспериментов

Слои добавляются по одному, чтобы источник дополнительного latency и jitter
можно было локализовать:

1. Прямая проверка harness: `producer -> consumer`.
2. `make net-up`, затем `make run-test`: два network namespace и прямой veth с
   чистым профилем.
3. `make netem-set NETEM_DELAY=...`, затем `make run-test`: тот же veth с
   фиксированной задержкой.
4. Veth с delay и loss: проверка sequencing, recovery, backpressure и потерь в
   SHM-кольцах.
5. Несколько namespace через Linux bridge: L2 fan-out.
6. Два сегмента и router namespace: L3 hop.

Все network namespace локального стенда работают на одном kernel и используют
общие системные часы, поэтому текущая метрика `recv_ts - send_ts_ns` применима.
Это перестаёт быть автоматически верным после переноса `sender` и `receiver`
на разные физические машины.

`delay=0`, `loss=0` — основной профиль для сравнения субмикросекундных
оптимизаций transport hot path. При заметной искусственной задержке полезно
сравнивать реализации только A/B-прогонами с неизменным профилем и большим
числом samples: вариативность планировщика `netem` может быть существенно
больше искомой разницы в сотни наносекунд. Delay/loss-профили прежде всего
проверяют корректность протокола и его поведение под нагрузкой; они не делают
локальный veth точной моделью физической сети.

Локальный стенд включает реальный Linux network stack, qdisc и работу с
socket API, но не включает физический NIC, DMA, аппаратные очереди, IRQ от NIC,
ENA и межмашинную синхронизацию часов. Поэтому он хорошо подходит для
разработки и относительных сравнений, но финальные абсолютные latency и
возможности аппаратного zero-copy проверяются на двух физических машинах.

Короткая функциональная проверка может использовать 100 тысяч сообщений. Для
p99.99 нужен как минимум миллион наблюдений и несколько повторов; при 50
тысячах сообщений p99.99 определяется всего несколькими худшими samples.
