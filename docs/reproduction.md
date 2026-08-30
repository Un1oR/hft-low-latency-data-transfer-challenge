# Воспроизведение решения и измерений

Это основная инструкция для проверки решения. Она разделяет обязательные
свойства стенда и нашу автоматизацию. Команды `make` и Terraform экономят время,
но не предполагается, что их получится без изменений применить в чужом AWS
аккаунте: имена IAM-ролей, permissions boundary, способ входа, лимиты и доступная
Availability Zone почти наверняка будут другими.

Проверяющему важнее воспроизвести свойства из разделов 1-6. Наш готовый путь
описан в разделе 7, а его ручной эквивалент - в разделе 8.

## 1. Что именно нужно воспроизвести

Целевая конфигурация:

| Свойство | Проверенная конфигурация |
|---|---|
| Топология | один source и три отдельных receiver-узла |
| EC2 | четыре одинаковых `m8a.xlarge` |
| ОС | Canonical Ubuntu Server 24.04 LTS amd64 |
| Системный диск | 24 GiB gp3 на benchmark-узел |
| Размещение | одна AZ и подсеть; дочерняя `cluster` внутри `precision-time` |
| Сеть узла | control ENI под Linux и отдельный data ENI под DPDK |
| Ядро | штатное Ubuntu AWS `6.17.0-1020-aws` |
| Kernel ENA | официальный `2.17.2`, commit `acddbf23…`, собранный с `ENA_PHC_INCLUDE=1` |
| Userspace DPDK | `25.11.3`, собран только с `net/ena`; библиотека входит в `.deb` |
| PCI binding data ENI | `igb_uio`, `wc_activate=1` |
| Hugepages | не менее 512 страниц по 2 MiB, `hugetlbfs` в `/dev/hugepages` |
| MTU | Ethernet 1500; UDP payload не более 1472 байт |
| Горячие CPU | `2` и `3`; CPU `0-1` оставлены ОС, SSM и IRQ |
| Часы | ENA PHC как предпочитаемый источник `chrony`; поправка latency равна 0 |
| Основной backend | `--networking-backend dpdk` |
| Wire | lossless compact batch v1 |
| LLQ | политика ENA `3`, Wide LLQ |

## 2. Топология и назначение интерфейсов

На source работают `producer` и `sender`; на каждом receiver - собственные
`receiver` и `consumer`:

```text
source (m8a.xlarge)
  CPU 2: producer -> TX SPSC
  CPU 3: sender -> DPDK data ENI
                    |-> receiver 1 data ENI -> RX SPSC -> consumer
                    |-> receiver 2 data ENI -> RX SPSC -> consumer
                    `-> receiver 3 data ENI -> RX SPSC -> consumer
```

Каждый benchmark-узел имеет два ENI в одной подсети:

- основной control ENI остаётся привязан к kernel `ena.ko`; через него работают
  SSM, bootstrap, S3 и синхронизация системных часов;
- дополнительный data ENI отвязывается от kernel ENA и передаётся DPDK через
  `igb_uio`; только через него идёт измеряемый трафик.

Это обязательная граница. Нельзя передавать DPDK основной ENI: тогда исчезнут
SSM и безопасное управление узлом. Нельзя также измерять DPDK-трафик через
control ENI и считать результат эквивалентным.

Все benchmark-узлы находятся без public IPv4. В нашей инфраструктуре исходящий
bootstrap-трафик идёт через временный `t4g.nano` NAT. В чужом аккаунте его можно
заменить NAT Gateway, VPC endpoints или заранее подготовленным AMI, если свойства
benchmark-узлов останутся теми же.

Родительская `precision-time` placement group нужна для доступа к точным
источникам времени. Все четыре benchmark EC2 размещаются не прямо в ней, а в её
дочерней [`cluster`](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/placement-strategies.html)
group, предназначенной для низкой сетевой задержки. Имена, фактические ID,
стратегия и родительская связь сохраняются в manifest каждого запуска. Даже при
этом после пересоздания EC2 Claude нужно заново измерять рядом с нашим решением:
абсолютная односторонняя задержка включает остаточный межхостовый сдвиг часов.

Точная реализация сети и EC2 находится в
[`infra/runner/main.tf`](../infra/runner/main.tf), параметры - в
[`infra/runner/variables.tf`](../infra/runner/variables.tf).
Используемый Terraform provider `hashicorp/aws 6.60.0` ещё не предоставляет
`ParentGroupId` для `aws_placement_group`, поэтому дочерняя группа управляется
из `terraform_data` через EC2 API: создание, проверка стратегии/родителя и
удаление всё равно входят в Terraform lifecycle. В другом IaC этот обход не
нужен, если ресурс умеет задавать родителя напрямую.

## 3. Предварительные требования к рабочей станции и AWS

На машине, с которой выполняется развёртывание, нужны:

- Linux x86-64;
- Git и GNU Make;
- Docker с `buildx`;
- AWS CLI v2 с действующей сессией;
- Terraform `>= 1.15, < 2.0`;
- `jq`, `bash`, `sha256sum`, `base64`, `tar`, `gzip`;
- `uv` для открытия и контрольного исполнения аналитического notebook;
- исходящий HTTPS к Ubuntu repositories, `apt.llvm.org`, `cmake.org`, GitHub и
  `fast.dpdk.org` для чистой сборки и подготовки хостов.

Для AWS нужны:

- Paid Plan или иной режим, разрешающий `m8a.xlarge`;
- не менее 18 Standard On-Demand vCPU в выбранном регионе: 16 для четырёх
  benchmark-узлов и 2 для нашего NAT;
- свободная On-Demand capacity `m8a.xlarge` и `t4g.nano` в одной AZ;
- права на EC2, VPC, S3, SSM, IAM instance roles, EventBridge Scheduler и
  Terraform state выбранного аккаунта;
- instance role с `AmazonSSMManagedInstanceCore`, чтением конкретного `.deb` из
  S3 и записью результатов в выделенный префикс.

Наш одноразовый IAM bootstrap находится в
[`infra/bootstrap`](../infra/bootstrap/README.md) и создаёт роли с префиксом
`spectral-` под уже применённой permissions boundary. Это защита нашего аккаунта,
а не переносимая часть алгоритма. В другом аккаунте следует выдать эквивалентные
минимальные права принятым там способом. Статические AWS access keys в файлы
репозитория или на EC2 не записываются; используются локальная AWS-сессия и
instance profiles.

Создание EC2 иногда несколько минут остаётся в `pending` из-за нехватки capacity.
Это допустимо. `InsufficientInstanceCapacity` означает нехватку машин в AZ, а не
нехватку vCPU quota; безопасные варианты - повторить позже или явно выбрать
другую совместимую AZ и начать новую измерительную эпоху.

## 4. Каноническая сборка

Релизный артефакт собирается одной командой из корня репозитория:

```bash
make deb
```

Результат появляется в `dist/` как content-addressed
`spectral-task_<version>+sha<12>_amd64.deb`. Если там больше одного пакета,
дальше нужно явно передавать его абсолютный путь через `AWS_RUNNER_PACKAGE`.

Цепочка сборки:

1. [`Makefile`](../Makefile) вызывает
   [`scripts/build-deb-ubuntu24.sh`](../scripts/build-deb-ubuntu24.sh).
2. Скрипт использует
   [`packaging/Dockerfile.ubuntu24`](../packaging/Dockerfile.ubuntu24) и Docker
   `buildx --platform linux/amd64`.
3. В закреплённом Ubuntu 24.04 image устанавливаются Clang 22, libc++, lld,
   CMake 4.2.5, nFPM 2.47.0 и DPDK 25.11.3.
4. DPDK собирается как shared library только с `net/ena` и `test-pmd`.
5. CMake собирает `sender`, `receiver` и `clock_probe` как C++23 с модулями;
   отдельный harness собирает `producer` и `consumer` GCC как C++17.
6. В build image запускаются transport unit tests и harness tests.
7. Готовый `.deb` устанавливается в чистый Ubuntu 24.04 verifier image; `ldd`
   проверяет, что библиотек не не хватает.

DPDK включается на этапе CMake только если `pkg-config` находит `libdpdk`:
это видно в [`CMakeLists.txt`](../CMakeLists.txt). Обычная локальная сборка без
DPDK создаст рабочий socket backend, но запуск с `--networking-backend dpdk`
будет недоступен. Канонический `.deb` всегда собирается с DPDK, потому что Docker
до CMake выставляет `PKG_CONFIG_PATH` на собранный DPDK 25.11.3.

Пакет устанавливает исполняемые файлы в
`/usr/libexec/spectral-task/bin/`, а DPDK и его ENA PMD - в
`/usr/libexec/spectral-task/dpdk-25.11.3/`. RUNPATH `sender` и `receiver`
указывает именно туда; системный Ubuntu DPDK не подменяет измеренный PMD.

Измеренный финальный пакет имел SHA-256
`b56f3372f5d00b4c4b072e429a0015636842d17a8132ad8a03e5ba0a9d3ddc96`,
а отпечаток исполняемых исходников равен `f356e7c68422`. Версия пакета не
содержит маркер `.dirty`. Поле `dirty=true` в run-manifest относится ко всему
checkout оркестратора; установленный `.deb` идентифицируется собственным SHA.
В производных данных эти признаки называются `source_dirty` и `runner_dirty` и
хранятся раздельно. Отпечаток вычисляется только по входам сборки исполняемого
кода, поэтому правки документации и переписывание содержащего их Git-коммита его
не меняют.

## 5. Подготовка benchmark-узлов

Чистый узел готовится в следующем порядке от root, затем перезагружается:

1. [`phc-prepare.sh`](../infra/runner/scripts/phc-prepare.sh) устанавливает
   штатное ядро `6.17.0-1020-aws`, собирает официальный ENA `2.17.2` через
   DKMS с `ENA_PHC_INCLUDE=1`, включает `phc_enable=1` и настраивает `chrony`:

   ```text
   refclock PHC /dev/ptp_ena poll 0 delay 0.000010 prefer
   ```

2. [`dpdk-prepare.sh`](../infra/runner/scripts/dpdk-prepare.sh) выделяет 512
   hugepages по 2 MiB, монтирует `/dev/hugepages`, включает
   `igb_uio wc_activate=1`, находит дополнительный ENA PCI device, сохраняет его
   PCI/MAC/IP в `/etc/spectral-task/dpdk.env` и привязывает только этот device к
   `igb_uio`.
3. [`runner-bootstrap.sh`](../infra/runner/templates/runner-bootstrap.sh)
   проверяет SHA пакета, выполняет `dpkg --install`, добавляет kernel arguments
   и планирует reboot.

Kernel arguments:

```text
nohz_full=2-3
rcu_nocbs=2-3
irqaffinity=0-1
isolcpus=domain,managed_irq,2-3
```

Дополнительно systemd получает `CPUAffinity=0 1`, а IRQ balance запрещается
назначать на CPU `2-3`. На source `producer` запускается на CPU 2, `sender` на
CPU 3; на receiver CPU 2 принадлежит `receiver`, CPU 3 - `consumer`.

После reboot обязательна проверка
[`phc-verify.sh`](../infra/runner/scripts/phc-verify.sh): выбран нужный kernel и
DKMS ENA, существует `/dev/ptp_ena`, `chrony` выбрал источник `PHC`, PHC error
bound не превышает заданный предел, control ENI остаётся на `ena`, data ENI -
на `igb_uio`. DPDK connectivity отдельно проверяется парой `testpmd → testpmd`
через [`dpdk-testpmd.sh`](../infra/runner/scripts/dpdk-testpmd.sh).

## 6. Параметры сдаваемого запуска

Критичные параметры нельзя оставлять неявными:

```text
networking backend     = dpdk
compact wire           = 1
DPDK LLQ policy        = 3 (Wide LLQ)
receiver count         = 1..3
warmup                  = 2000 ms
message type           = mixed
RX burst size          = 32
RX free threshold      = 0 (значение ENA PMD)
hardware RX timestamps = 0 для итоговых цифр
stage timestamps       = 0 для итоговых цифр
clock probe            = 0 для итоговых цифр
max clock error        = 150000 ns
```

Цель пачки по умолчанию выбирается до запуска по известным `rate` и `N`:

```text
target_frames = ceil(rate * N / 2_000_000 packets/s)
```

Максимальное ожидание равно `1200 нс`, но при цели 1 принудительно становится
нулевым. Это не скрытый runtime-регулятор. Запрошенные и эффективные значения
сохраняются в `manifest.json`. При `N=3` получаются цели 1, 3, 6, 7 и 8 для
`0,2M`, `2M`, `4M`, `4,5M` и `5M` событий/с соответственно.

## 7. Наш автоматизированный путь

### 7.1. Создание стенда

После настройки локальной AWS-сессии:

```bash
make deb
make aws-cluster-up AWS_RUNNER_AUTO_APPROVE=1
```

`aws-cluster-up` выполняет Terraform в три фазы: сначала сеть/EC2 с аварийным
TTL, затем SSM bootstrap и reboot, затем общий абсолютный TTL. Повтор команды
продолжает незавершённую фазу. Успех означает, что package SHA, CPU isolation,
kernel, ENA PHC/chrony, data ENI, hugepages и TTL проверены на всех четырёх
узлах.

Для явной проверки:

```bash
make aws-cluster-status
make aws-cluster-phc-verify
make aws-cluster-dpdk-verify
```

Цели `aws-cluster-phc-ready` и `aws-cluster-dpdk-ready` нужны для восстановления
или отдельной диагностики. После успешного cold `up` повторять установку не
требуется.

### 7.2. Два основных прогона

Низкая нагрузка:

```bash
make aws-cluster-run \
  AWS_RUNNER_NETWORKING_BACKEND=dpdk \
  AWS_RUNNER_COMPACT_WIRE=1 \
  AWS_RUNNER_DPDK_LLQ_POLICY=3 \
  AWS_RUNNER_RECEIVER_COUNT=3 \
  AWS_RUNNER_MESSAGE_RATE=200000 \
  AWS_RUNNER_MESSAGE_COUNT=1000000 \
  AWS_RUNNER_WARMUP_MS=2000
```

Высокая нагрузка:

```bash
make aws-cluster-run \
  AWS_RUNNER_NETWORKING_BACKEND=dpdk \
  AWS_RUNNER_COMPACT_WIRE=1 \
  AWS_RUNNER_DPDK_LLQ_POLICY=3 \
  AWS_RUNNER_RECEIVER_COUNT=3 \
  AWS_RUNNER_MESSAGE_RATE=2000000 \
  AWS_RUNNER_MESSAGE_COUNT=1000000 \
  AWS_RUNNER_WARMUP_MS=2000
```

Для среза `N=1,2,3` меняется только `AWS_RUNNER_RECEIVER_COUNT`. Для поиска
границы нагрузки меняется только `AWS_RUNNER_MESSAGE_RATE`; автоматическая цель
пачки должна остаться включённой (`AWS_RUNNER_BATCH_TARGET_FRAMES=auto`). Явное
переопределение цели и ожидания допустимо только как A/B и должно быть сохранено
в manifest.

### 7.3. Обновление, остановка и удаление

Новый пакет на живом стенде:

```bash
make aws-cluster-update
```

Между короткими рабочими сессиями:

```bash
make aws-cluster-stop
make aws-cluster-start
```

Stop сохраняет EBS и Terraform state, но EC2 после следующего start может
оказаться на другом физическом host. После start Claude и наше решение следует
снять заново рядом. В конце работы:

```bash
make aws-cluster-down
make aws-cluster-audit
```

`down` удаляет EC2, EBS, временный S3 bucket, роли и Scheduler, которыми владеет
runner Terraform. Не следует запускать одновременно несколько копий оркестратора
с одним локальным state.

Подробности реализации автоматизации находятся в
[`cluster.sh`](../infra/runner/scripts/cluster.sh) и в архитектурном документе
[`aws-runner-topology-and-build.md`](aws-runner-topology-and-build.md).

## 8. Ручной эквивалент без нашего Terraform

Если чужой AWS-контур нельзя подогнать под наши роли и state, достаточно
воспроизвести следующие действия своей IaC/оркестрацией:

1. Создать `precision-time` placement group, внутри неё дочернюю группу со
   стратегией `cluster`, затем четыре `m8a.xlarge` Ubuntu 24.04 в одной
   AZ/подсети и в этой дочерней группе. Проверить фактический `ParentGroupId`
   через EC2 API.
2. Дать каждому два ENI и сохранить control ENI у Linux.
3. Доставить на узлы один и тот же content-addressed `.deb`, проверить SHA и
   установить `dpkg --install`.
4. Выполнить три host-setup script из раздела 5 и перезагрузить узлы.
5. Проверить kernel, ENA PHC/chrony, hugepages и binding data ENI.
6. Сначала запустить `receiver` и `consumer` на всех receiver-узлах и дождаться
   явной готовности, затем запустить source. Не заменять READY фиксированным
   `sleep`.
7. Запускать процессы через `taskset` на CPU 2/3, как описано выше.
8. Перед измеряемым диапазоном пропустить прогрев. При 2 секундах и 2 млн/с
   измерение начинается после `seq_id=4 000 000`.
9. Снять clock snapshot всех узлов до и после нагрузки и сохранить raw CSV,
   логи sender/receiver/consumer, package SHA, instance IDs и параметры запуска.

Точные аргументы бинарников собраны в
[`unicast-source.sh`](../infra/runner/scripts/unicast-source.sh) и
[`unicast-receiver.sh`](../infra/runner/scripts/unicast-receiver.sh). Эти файлы
удобнее использовать как исполняемую спецификацию, чем копировать длинные
командные строки из документа.

## 9. Как измеряется и валидируется результат

Перед source оркестратор получает READY со всех receiver. Producer прогоняет
`warmup_events = ceil(rate * warmup_ms / 1000)` через полный путь, но consumer
не записывает эти события. Затем каждый consumer сохраняет `seq,latency_ns` в
память и пишет CSV после горячего цикла.

После запуска [`summarize-fanout.py`](../scripts/summarize-fanout.py) создаёт
`fanout-summary.json`. Результат пригоден для сравнения только если:

- package SHA и настройки совпадают с заявленным вариантом;
- instance IDs, AZ, типы машин и число receiver сохранены;
- manifest содержит имя и ID дочерней `cluster` group и её `precision-time`
  parent; фактическая связь подтверждена EC2 API;
- до и после прогона `chrony` синхронизирован от ENA PHC;
- clock correction равна 0, а граница ошибки сохранена и не превышает лимит;
- каждый receiver получил требуемое число событий непрерывным диапазоном без
  внутренних пропусков;
- `gaps=0`, `duplicates=0`, `reordered=0`, `delivery_valid=true`;
- нет `dpdk_imissed`, `ierrors`, `oerrors`, `rx_nombuf`;
- аппаратные `pps_exceeded` и `bw_out_exceeded` проверены даже при полной
  доставке: они обнаруживают очередь раньше потерь;
- p50, p99, p99.9 и p99.99 считаются отдельно по каждому receiver;
- для основной fan-out метрики разрешено отбросить только несовпадающие края
  записи, после чего `seq_id` выбранных receiver должны совпасть точно; для каждого
  события берётся максимальная задержка, а перцентили считаются уже по этому
  ряду «доставлено всем»;
- для `N=3` дополнительно публикуются три отдельные кривые, равновзвешенное
  объединение receiver-наблюдений как задержка доставки одному равновероятно
  выбранному адресату, среднее трёх задержек для события и максимальная задержка
  как время доставки всем;
- форму хвоста также показываем после вычитания собственного p50 каждого
  receiver, чтобы постоянный сдвиг часов одного узла не выглядел сетевой
  аномалией. Центрированная метрика не заменяет абсолютную задержку и не служит
  способом выкинуть медленного получателя из результата.

Для p99.99 нужно не менее миллиона измеряемых событий и несколько повторов.
Даже тогда дальняя точка нестабильна, поэтому вывод должен сопровождаться
полным распределением и разбросом повторов.

Артефакты нашего runner скачиваются в
`artifacts/aws-runner/<run-id>/`; каталог намеренно не коммитится целиком.
Компактные производные данные сдаваемого notebook лежат в
[`data/submission`](../data/submission/README.md).

## 10. Повтор baseline Claude

Claude собирается из внешнего чистого checkout, чтобы локальный путь не попадал
в Git. Нужен точный commit
`c86cc26ab2e84996137f922cf175d33e9a622c29`:

```bash
CLAUDE_BASELINE_DIR=/absolute/path/to/claude-checkout \
  scripts/claude-baseline.sh build
scripts/claude-baseline.sh install
```

Финальную матрицу безопаснее повторять одним оркестратором. Методика повторяет
контрсбалансированные блоки из
[отчёта Claude](https://gitlab.spectral.tech/challenge/agent-solution/-/blob/c86cc26ab2e84996137f922cf175d33e9a622c29/SOLUTION.md#measurement-methodology):
в каждом блоке обе реализации запускаются по одному разу, а порядок меняется
через блок — `Claude → DPDK`, затем `DPDK → Claude`. Это устраняет постоянное
преимущество второго запуска и частично сокращает линейный дрейф среды и
межхостовых часов.

У Claude эта схема появилась после двух ложных выводов: разница около нескольких
микросекунд между реализациями поменяла знак в другой сессии, а p99.99 одной и
той же конфигурации гулял более чем на порядок. Плотные повторы внутри одного
окна этого не показывают. Поэтому единицей сравнения служит парная разность
внутри блока, а не разность объединённых абсолютных перцентилей.

Для важных выводов используются шесть блоков на каждую частоту:

```text
Claude → DPDK | DPDK → Claude | Claude → DPDK |
DPDK → Claude | Claude → DPDK | DPDK → Claude
```

Неудачное плечо нельзя тихо заменить, сохранив вторую половину старой пары.
Оркестратор записывает такую попытку в `invalid_attempts`, исключает из расчёта
уже снятое плечо незавершённого блока и повторяет весь блок в его исходном
порядке. Поэтому восстановление после сбоя не превращает схему в «один всегда
первый, другой всегда второй».

Шесть блоков — первая точка, где точный двусторонний знаковый критерий при
одинаковом знаке всех разностей может дать `p < 0,05`:
`2 / 2^6 = 0,03125`. Помимо знака и диапазона шести эффектов публикуется
собственный межблочный разброс Claude. Если наблюдаемый эффект меньше этого
разброса, он не объявляется разрешённым даже при красивой разнице объединённых
кривых. Времена начала и окончания каждого плеча сохраняются, чтобы слишком
растянутый блок нельзя было выдать за соседнее A/B.

Один оркестратор проверяет commit/SHA, instance IDs, часы и доставку, даёт обеим
реализациям прогрев ровно `2 с` и сохраняет по `1 млн` измеренных событий на
receiver:

```bash
COMPARISON_RATES="200000 2000000" \
COMPARISON_RECEIVER_COUNTS="1 3" \
COMPARISON_BLOCKS=6 \
COMPARISON_SAMPLES=1000000 \
COMPARISON_WARMUP_MS=2000 \
  scripts/run-claude-dpdk-comparison.sh
```

Для финального отчёта используется более широкий одноэпоховый запуск. Он сначала
выполняет те же шесть блоков, затем на тех же instance IDs снимает нагрузочный
срез, отдельный `N=1,2,3` и диагностическую раскладку тракта:

```bash
SUBMISSION_PACKAGE=/absolute/path/to/spectral-task.deb \
CLAUDE_BASELINE_PACKAGE=/absolute/path/to/claude-baseline.deb \
SUBMISSION_COMPARISON_RECEIVER_COUNTS="1 3" \
  scripts/run-submission-suite.sh
```

Нельзя дополнять эту серию абсолютными значениями старой эпохи. Если стенд был
пересоздан или EC2 прошли stop/start, вся suite снимается заново; старые данные
остаются только историческим подтверждением гипотез.

Текущая методика контрсбалансирует Claude и DPDK отдельно для `N=1` и `N=3`.
Дополнительный `N=1,2,3`-срез содержит только наше решение и показывает
масштабирование fan-out; старые абсолютные значения другого создания EC2 в него
не подмешиваются.

Низкоуровневый `claude-baseline.sh run` остаётся доступен для одиночной
диагностики, но легко случайно задать другой прогрев. Скрипт не патчит Claude и
проверяет чистоту checkout/commit. Диагностическую UDP-пробу можно включить, но
она использует control ENI и не корректирует основную latency. Claude и наш
DPDK нужно контрсбалансировать на тех же работающих EC2; старые абсолютные цифры
после пересоздания или stop/start не являются новой планкой.

## 11. Notebook и компактные данные

Python-зависимости закреплены в `pyproject.toml` и `uv.lock`. Из корня:

```bash
uv sync --frozen
uv run --frozen jupyter lab analysis.ipynb
```

Команда запускает Jupyter Lab и обычно сама открывает вкладку браузера. Если
браузер не открылся, нужно перейти по локальной ссылке с токеном, которую
Jupyter напечатает в терминале. Notebook уже исполнен: таблицы и интерактивные
графики видны сразу. Над графиками с большим динамическим диапазоном есть
переключатель линейной и логарифмической шкалы; он работает в браузере без
повторного запуска ячеек. Для независимой проверки расчётов в интерфейсе следует
выбрать `Kernel -> Restart Kernel and Run All Cells`; это также не требует AWS.

Проверка тем же способом без браузера:

```bash
uv run --frozen jupyter nbconvert \
  --to notebook --execute analysis.ipynb \
  --output /tmp/spectral-analysis-checked.ipynb \
  --ExecutePreprocessor.timeout=300
```

Notebook исполняется из чистого checkout без AWS и без каталога `artifacts/`:
все нужные таблицы и эмпирические квантильные кривые уже находятся в
`data/submission`. Корень каталога содержит основную эпоху во вложенном
размещении `precision-time → cluster`. Подкаталог `precision-time-only`
содержит отдельную согласованную эпоху без дочерней `cluster` group. Notebook
показывает обе, но не объединяет их абсолютные задержки и не трактует разность
между эпохами как эффект размещения.

Чтобы заново построить основную эпоху из полных локальных AWS-артефактов:

```bash
uv run --frozen python scripts/build-submission-data.py
```

Дополнительная эпоха восстанавливается только с явным профилем и её точной
suite:

```bash
uv run --frozen python scripts/build-submission-data.py \
  --suite artifacts/aws-runner/submission-suite-20260829T161712Z/suite.json \
  --epoch-profile precision-time-only \
  --output data/submission/precision-time-only
```

[`provenance.json`](../data/submission/provenance.json) содержит исходные
manifest и summary основной серии и точное правило агрегации; дополнительная
эпоха имеет собственный
[`provenance.json`](../data/submission/precision-time-only/provenance.json).
Генератор читает per-event CSV, но не модифицирует их.

Аппаратная RX-метка сохраняется в сыром диагностическом запуске, но не входит в
количественную раскладку: data ENI принадлежит DPDK и имеет собственную шкалу,
а доступный `/dev/ptp_ena` относится к control ENI. В ENA PMD используемой
версии нет операции `read_clock`, которой можно было бы привязать RX timestamp
data ENI к `CLOCK_REALTIME`. Попытка подставить PHC control ENI дала почти
миллион отрицательных локальных интервалов на одном receiver и тем самым сама
опровергла такую калибровку. В notebook показаны программные интервалы на одном
хосте и совокупный межхостовый участок.

## 12. Контрольный список приёмки

- [ ] `.deb` собран через Ubuntu 24.04 container и содержит DPDK 25.11.3 ENA PMD.
- [ ] Все четыре benchmark-узла имеют один тип, одну AZ и два ENI.
- [ ] Все четыре узла фактически находятся в одной дочерней `cluster` group;
      её родитель — сохранённая `precision-time` group.
- [ ] Control ENI работает на kernel ENA; data ENI - на `igb_uio`.
- [ ] Загружено ядро `6.17.0-1020-aws`, `/dev/ptp_ena` существует, `chrony`
      выбрал PHC.
- [ ] CPU 2-3 изолированы, процессы закреплены согласно роли.
- [ ] В manifest указаны `dpdk`, compact wire, LLQ policy 3, rate, N, warmup,
      цель пачки и package SHA.
- [ ] Clock snapshots до/после валидны; correction равна 0.
- [ ] Каждый receiver получил требуемый непрерывный диапазон; после отбрасывания
      только несовпадающих краёв общий sequence range совпадает точно.
      Обе точки за рабочей границей помечены `expected_saturation=true` и
      подтверждены ненулевым аппаратным счётчиком ENA.
- [ ] Проверены ENA allowance/error counters.
- [ ] Claude сравнивается только на тех же живых instance IDs.
- [ ] Notebook исполняется с нуля и показывает наши/Claude распределения вместе.
- [ ] После проверки стенд остановлен или уничтожен.
