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

В частности, `consumer --csv` сейчас вызывает `fprintf` для каждого сообщения.
Такой режим нельзя использовать для чистого tail-latency benchmark. Измерения
нужно сначала накапливать в RAM, а сохранять после hot loop либо отдельным
writer-процессом на housekeeping CPU.

Перед измерением также следует закрыть тяжёлые фоновые приложения и следить за
температурой: длительный busy-spin на мобильном CPU может привести к thermal
throttling.

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

Планируемое закрепление процессов:

| CPU | Процесс |
|---:|---|
| `4` | `producer` |
| `5` | `sender` |
| `6` | `receiver` |
| `7` | `consumer` |

Каждый hot-path процесс запускается через `taskset`. Служебные shell-процессы
и запись результатов не должны выполняться на CPU `4-7` во время измерения.

`sender` и `receiver` запускаются в разных network namespace. Это меняет их
представление сетевых интерфейсов и routing table, но не создаёт отдельный IPC
namespace: обе POSIX SHM-очереди остаются доступны через общий `/dev/shm`.

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
| `make net-up` | Идемпотентно создать два namespace и чистый veth-линк без `netem`, затем проверить связность. |
| `make net-status` | Без изменений системы показать namespace, адреса, link state и qdisc со счётчиками. |
| `make netem-set ...` | Добавить или заменить единый профиль delay/loss виртуального линка. |
| `make netem-clear` | Идемпотентно удалить `netem`, сохранив поднятый veth-линк. |
| `make net-down` | Удалить только namespace и интерфейсы этого стенда. |

Это проектируемый интерфейс: пока в репозитории есть только
`harness/Makefile`, соответствующий корневой Makefile ещё предстоит добавить.
Makefile будет конечным оркестратором вызовов `ip` и `tc`.

`net-up` приводит стенд к известному чистому профилю без qdisc. При совпадении
имён с ресурсами другой конфигурации цель завершает работу с понятной ошибкой.

Для первого транспорта создаётся прямой L2-линк `10.200.0.1/30` ↔
`10.200.0.2/30`. Linux bridge понадобится только для сценария с несколькими
узлами в одном L2-сегменте. Отдельный router namespace с двумя veth-парами
понадобится позднее для явного L3 hop.

### 4.2. Запуск процессов

Процессы также запускаются через корневой Makefile:

| Команда | CPU | Network namespace |
|---|---:|---|
| `make run-producer` | `4` | host |
| `make run-sender` | `5` | `spectral-tx` |
| `make run-receiver` | `6` | `spectral-rx` |
| `make run-consumer` | `7` | host |

Каждая цель запускает процесс в foreground, поэтому для ручного прогона они
вызываются в отдельных терминалах:

```bash
make run-producer
make run-sender
make run-receiver
make run-consumer
```

`sender` должен отправлять на `10.200.0.2`, а `receiver` слушать этот адрес либо
`0.0.0.0`. Рецепты `run-*` закрепляют процессы за указанными CPU и помещают
`sender`/`receiver` в соответствующие namespace. Проверка PID, всех TID и их
affinity также оформляется отдельной целью:

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

Makefile должен проверять единицы, диапазон loss `0..100%`, целочисленный limit
и зависимость jitter от delay до вызова `tc`. Если delay, jitter и loss равны
нулю, следует использовать `make netem-clear`, чтобы clean baseline вообще не
содержал qdisc `netem`.

`netem-set` задаёт один симметричный профиль виртуального линка: Makefile
устанавливает одинаковые qdisc на egress обоих концов veth-пары. В основном
UDP data path пакеты идут только от `sender` к `receiver` и проходят профиль
один раз. Если у протокола появится обратный control traffic, он автоматически
окажется в тех же сетевых условиях.

Значения выше — только пример профиля, а не утверждение о характерной задержке
целевой L2- или L3-сети. Профили следует подобрать из условий задачи либо по
замерам реального окружения и явно сохранять вместе с результатами.

Отдельные namespace и veth ограничивают действие профиля интерфейсами стенда;
host loopback `lo` остаётся вне эксперимента.

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

1. Прямой SHM baseline: `producer -> consumer`.
2. Четыре процесса и UDP через host loopback — опциональный
   диагностический baseline сетевого кода.
3. `make net-up`: два network namespace и прямой veth без `netem`.
4. `make netem-set NETEM_DELAY=...`: тот же veth с фиксированной задержкой,
   но без loss.
5. Veth с delay и loss: проверка sequencing, recovery, backpressure и потерь в
   SHM-кольцах.
6. Несколько namespace через Linux bridge: L2 fan-out.
7. Два сегмента и router namespace: L3 hop.

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

Короткий smoke-test может использовать 100 тысяч сообщений. Для p99.99 нужен
как минимум миллион наблюдений и несколько повторов; при 50 тысячах сообщений
p99.99 определяется всего несколькими худшими samples.
