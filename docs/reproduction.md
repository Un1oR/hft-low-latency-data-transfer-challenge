# Воспроизведение решения и измерений

Документ поддерживает три уровня проверки: локальное исполнение отчёта без AWS,
воспроизводимую сборку `.deb` и полный повтор измерений на AWS. Разделы 1-6
фиксируют свойства измерительного стенда и конфигурацию запуска. Раздел 7
описывает готовую автоматизацию этого репозитория, раздел 8 - те же действия для
другого IAM- и IaC-контура, а раздел 11 - локальную проверку отчёта.

Канонический путь проверяющего проходит через этот документ. Архитектурный
разбор стенда находится в
[`aws-runner-topology-and-build.md`](aws-runner-topology-and-build.md), а
Terraform-модули и их назначение - в [`infra/README.md`](../infra/README.md).

Уровни проверки:

| Уровень | Что проверяется | Ожидаемый объём работы |
|---|---|---|
| Отчёт | повторное исполнение всех ячеек над данными из Git | без AWS; каталог данных около 128 MiB |
| Сборка и одиночный запуск | `.deb`, подготовка стенда, доставка и валидация одного миллиона событий | создание EC2 занимает минуты; один запуск создаёт десятки-сотни MiB сырых данных |
| Полная серия | 48 контрсбалансированных запусков Claude/DPDK и 10 дополнительных срезов | несколько часов после готовности стенда и несколько GiB локальных артефактов |

## 1. Требования к стенду

Для полного повтора нужны следующие свойства стенда:

### Критичные версии

- **Ядро `6.17.0-1020-aws`.** В этой штатной сборке Ubuntu драйвер ENA снова
  выполнен модулем (`CONFIG_ENA_ETHERNET=m`), а поддержка PTP включена. Поэтому
  штатный модуль можно заменить официальным ENA, собранным через DKMS.
  [`phc-prepare.sh`](../infra/runner/scripts/phc-prepare.sh) устанавливает точный
  пакет и явно выбирает эту запись GRUB, даже если исходный AMI поставляется с
  более новым ядром. Последующая проверка готовности отклоняет другое
  загруженное ядро.
- **ENA `2.17.2` из ревизии `acddbf23…`.** Это драйвер управляющего ENI и
  источник часов. Он собирается с `ENA_PHC_INCLUDE=1`, загружается с
  `phc_enable=1` и должен создать `/dev/ptp_ena`. Точная фиксация исходников
  делает этот путь воспроизводимым; другая версия требует повторной проверки
  PHC, `chrony` и границы ошибки часов.
- **DPDK `25.11.3` с ENA PMD 2.14.0.** Эта версия выбрана специально: в ней ENA
  PMD получил аппаратные RX-метки, которых не было в системном DPDK 23.11.
  [`Dockerfile.ubuntu24`](../packaging/Dockerfile.ubuntu24) закрепляет исходный
  архив и его SHA-256. Библиотеки и PMD входят в наш `.deb`, а `RUNPATH`
  измеряемых бинарников указывает на их каталог внутри пакета. Итоговые
  скоростные прогоны используют этот PMD с выключенными аппаратными метками.
  Соседний A/B показал сопоставимую задержку DPDK 23.11 и 25.11; выбор 25.11
  даёт диагностические возможности и фиксирует точную реализацию измеряемого
  сетевого пути.

Первые две фиксации образуют тракт точного времени через управляющий ENI;
третья задаёт обработку измерительного ENI. Замена любой из них создаёт новую
конфигурацию стенда: сначала заново проходят проверки готовности, затем рядом
снимаются Claude и наше решение. Версии Clang, CMake и nFPM ниже фиксируют
повторяемость сборки пакета. Регион, AZ и AMI описывают происхождение данных.
Тип EC2, MTU, назначение CPU, `wc_activate=1` и Wide LLQ задают измеренный
профиль сетевого пути и повторяются для численного сравнения. Ubuntu 24.04 —
целевая среда готового `.deb`; конкретный образ выбирается при создании стенда.

| Свойство | Требование |
|---|---|
| Топология | один узел-источник и три отдельных узла-получателя |
| EC2 | четыре одинаковых `m8a.xlarge` |
| ОС | Canonical Ubuntu Server 24.04 LTS amd64 |
| Системный диск | не менее 24 GiB gp3 на измерительный узел |
| Взаимное размещение | одна AZ и подсеть; дочерняя `cluster` внутри `precision-time` |
| Сеть узла | control ENI под Linux и отдельный data ENI под DPDK |
| Ядро | штатное Ubuntu AWS `6.17.0-1020-aws` |
| Драйвер ENA ядра | официальный `2.17.2`, ревизия `acddbf23…`, собранный с `ENA_PHC_INCLUDE=1` |
| DPDK пользовательского пространства | `25.11.3` с ENA PMD 2.14.0; библиотека входит в `.deb` |
| Привязка data ENI | `igb_uio`, `wc_activate=1`; пакеты обрабатывает ENA PMD из DPDK 25.11.3 |
| Hugepages | сдаваемый профиль: 512 страниц по 2 MiB, `hugetlbfs` в `/dev/hugepages` |
| MTU | Ethernet 1500; UDP payload не более 1472 байт |
| Горячие CPU | `2` и `3`; CPU `0-1` оставлены ОС, SSM и IRQ |
| Часы | ENA PHC как предпочитаемый источник `chrony`; поправка latency равна 0 |
| Сетевой backend | `--networking-backend dpdk` |
| Сетевой формат | lossless compact batch v1 |
| LLQ | политика ENA `3`, Wide LLQ |

Регион, конкретная AZ и ID образа выбираются по доступности `m8a.xlarge`,
поддержке требуемого размещения и наличию Canonical Ubuntu 24.04. Четыре
измерительных узла внутри одного запуска используют одну AZ, один тип EC2, один
образ и одинаковый программный профиль. Новый стенд образует новую измерительную
эпоху, поэтому Claude и наше решение измеряются на нём заново соседними блоками.

### Конфигурация опубликованной серии

Серия, вошедшая в отчёт, была снята в регионе `us-east-1`, AZ `us-east-1a`
(физический ID `use1-az1`) на образе `ami-0d7f022123f8ff19d`
(`ubuntu-noble-24.04-amd64-server-20260828`). Эти значения описывают
происхождение опубликованных данных. Имя AZ наподобие `us-east-1a` является
псевдонимом внутри конкретного AWS-аккаунта; физическую зону идентифицирует
`AvailabilityZoneId`.

Готовый Terraform выбирает последний Canonical Ubuntu 24.04 AMI и первую
совместимую AZ текущего аккаунта. Системные пакеты `dpdk`/`dpdk-kmods` из
репозитория Ubuntu предоставляют `igb_uio` и диагностические утилиты; сетевые
пакеты обрабатывает ENA PMD 2.14.0 из встроенного в `.deb` DPDK 25.11.3. Скрипты
жёстко проверяют целевое ядро, ревизию ENA, `igb_uio` и загрузку пакетного DPDK.

Компактный `provenance.json` сохраняет instance IDs и placement metadata.
Сведения о среде опубликованной серии приведены выше; при независимом повторе к
артефактам следует также приложить результат
`aws ec2 describe-instances` с явным `--region` и полями `InstanceId`,
`Placement.AvailabilityZone`, `Placement.AvailabilityZoneId`, `InstanceType`,
`ImageId`.

## 2. Топология и назначение интерфейсов

На узле-источнике (`source`) работают `producer` и `sender`; на каждом
узле-получателе (`receiver`) - собственные `receiver` и `consumer`:

```text
source (m8a.xlarge)
  CPU 2: producer -> TX SPSC
  CPU 3: sender -> DPDK data ENI
                    |-> receiver 1 data ENI -> RX SPSC -> consumer
                    |-> receiver 2 data ENI -> RX SPSC -> consumer
                    `-> receiver 3 data ENI -> RX SPSC -> consumer
```

Каждый измерительный узел имеет два ENI в одной подсети:

- управляющий `control ENI` остаётся привязан к модулю ядра `ena.ko`; через него
  работают SSM, подготовка узла, S3 и синхронизация системных часов;
- измерительный `data ENI` передаётся DPDK через `igb_uio`; через него проходит
  измеряемый трафик.

Инвариант стенда: `control ENI` всегда принадлежит Linux, `data ENI` всегда
принадлежит DPDK. Так управление и синхронизация времени отделены от
измеряемого сетевого пути.

Измерительные узлы работают без публичных IPv4. Готовая инфраструктура направляет
исходящий трафик подготовки через временный NAT-узел `t4g.nano`. Эквивалентный
контур может использовать NAT Gateway, VPC endpoints или заранее подготовленный
AMI при сохранении свойств измерительных узлов.

Родительская `precision-time` placement group нужна для доступа к точным
источникам времени. Все четыре измерительных EC2 размещаются не прямо в ней, а в её
дочерней [`cluster`](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/placement-strategies.html)
  группе, предназначенной для низкой сетевой задержки. Имена, фактические ID,
стратегия и родительская связь сохраняются в manifest каждого запуска. Даже при
этом после пересоздания EC2 Claude нужно заново измерять рядом с нашим решением:
абсолютная односторонняя задержка включает остаточный межхостовый сдвиг часов.

Точная реализация сети и EC2 находится в
[`infra/runner/main.tf`](../infra/runner/main.tf), параметры - в
[`infra/runner/variables.tf`](../infra/runner/variables.tf).
Используемый Terraform provider `hashicorp/aws 6.60.0` ещё не предоставляет
`ParentGroupId` для `aws_placement_group`, поэтому дочерняя группа управляется
из `terraform_data` через EC2 API: создание, проверка стратегии/родителя и
удаление входят в жизненный цикл Terraform. Другой IaC может задать эту связь
нативным ресурсом.

## 3. Предварительные требования к рабочей станции и AWS

На машине, с которой выполняется развёртывание, нужны:

- Linux x86-64;
- Git и GNU Make;
- Docker с `buildx`;
- AWS CLI v2 с действующей сессией;
- Terraform `>= 1.15, < 2.0`;
- системный Python `>= 3.10` для оркестратора и Python `3.14` для отчёта;
- `jq`, `rg`, `bash`, `sha256sum`, `base64`, `tar`, `gzip`;
- `uv` для установки закреплённых Python-зависимостей и исполнения отчёта;
- исходящий HTTPS к репозиториям Ubuntu, Docker Hub, Terraform Registry,
  PyPI/files.pythonhosted, `apt.llvm.org`, `cmake.org`, GitHub,
  `gitlab.spectral.tech` и `fast.dpdk.org`.

Terraform state измерительной эпохи создан версией `1.16.0`. Минимальные
ограничения Terraform и Python закреплены в `versions.tf` и `pyproject.toml`, а
среда сборки приложения - digest образа в `packaging/Dockerfile.ubuntu24`.

Для AWS нужны:

- режим AWS-аккаунта, разрешающий запуск `m8a.xlarge`;
- не менее 18 Standard On-Demand vCPU в выбранном регионе: 16 для четырёх
  измерительных узлов и 2 для нашего NAT;
- свободная On-Demand capacity `m8a.xlarge` и `t4g.nano` в одной AZ;
- права на EC2, VPC, S3, SSM, IAM instance roles и EventBridge Scheduler;
- `servicequotas:GetServiceQuota` для проверки доступного числа On-Demand vCPU;
- локальный каталог для Terraform state; backend в готовой автоматизации
  локальный;
- instance role с `AmazonSSMManagedInstanceCore`, чтением конкретного `.deb` из
  S3 и записью результатов в выделенный префикс.

Готовая автоматизация рассчитана на IAM-контур этого репозитория:

- одноразовый модуль [`infra/bootstrap`](../infra/bootstrap/README.md) создаёт
  boundary `spectral-workload-boundary`;
- runner использует роли, instance profiles и S3 bucket с префиксом
  `spectral-`; эти имена проверяются в Terraform и в предварительной проверке;
- локальная AWS-сессия управляет инфраструктурой, а EC2 получают временные права
  через instance profiles; статические access keys на узлы не передаются.

В другом AWS-аккаунте эти имена и boundary адаптируются к принятой IAM-модели.
Эквивалентный набор прав включает перечисленные выше сервисы, чтение конкретного
`.deb` из S3 и запись результатов в выделенный префикс. Сам транспорт и методика
измерений от IAM-схемы не зависят.

Создание EC2 иногда несколько минут остаётся в `pending` из-за нехватки capacity.
Это допустимо. `InsufficientInstanceCapacity` сообщает о нехватке машин в
конкретной AZ; vCPU quota проверяется отдельно. Безопасные варианты - повторить
позже или явно выбрать другую совместимую AZ и начать новую измерительную эпоху.

## 4. Каноническая сборка

Релизный артефакт собирается одной командой из корня репозитория:

```bash
make deb
```

Результат появляется в `dist/` с именем, включающим отпечаток:
`spectral-task_<version>+sha<12>_amd64.deb`. Если там больше одного пакета,
дальше нужно явно передавать его абсолютный путь через `AWS_RUNNER_PACKAGE`.

Цепочка сборки:

1. [`Makefile`](../Makefile) вызывает
   [`scripts/build-deb-ubuntu24.sh`](../scripts/build-deb-ubuntu24.sh).
2. Скрипт использует
   [`packaging/Dockerfile.ubuntu24`](../packaging/Dockerfile.ubuntu24) и Docker
   `buildx --platform linux/amd64`.
3. В закреплённом образе Ubuntu 24.04 устанавливаются Clang 22, libc++, lld,
   CMake 4.2.5, nFPM 2.47.0 и DPDK 25.11.3.
4. DPDK собирается как динамическая библиотека только с `net/ena` и `test-pmd`.
5. CMake собирает `sender`, `receiver` и `clock_probe` как C++23 с модулями;
   отдельный harness собирает `producer` и `consumer` GCC как C++17.
6. В сборочном образе запускаются модульные тесты транспорта и harness.
7. Готовый `.deb` устанавливается в чистый проверочный образ Ubuntu 24.04; `ldd`
   проверяет разрешение всех динамических библиотек.

DPDK включается на этапе CMake только если `pkg-config` находит `libdpdk`:
это видно в [`CMakeLists.txt`](../CMakeLists.txt). Обычная локальная сборка без
DPDK создаст рабочий socket backend, но запуск с `--networking-backend dpdk`
будет недоступен. Канонический `.deb` всегда собирается с DPDK, потому что Docker
до CMake выставляет `PKG_CONFIG_PATH` на собранный DPDK 25.11.3.

Пакет устанавливает исполняемые файлы в
`/usr/libexec/spectral-task/bin/`, а DPDK и его ENA PMD - в
`/usr/libexec/spectral-task/dpdk-25.11.3/`. RUNPATH `sender` и `receiver`
указывает именно туда. Системные Ubuntu-пакеты DPDK предоставляют `igb_uio` и
диагностические утилиты, а измеряемые процессы загружают закреплённую библиотеку
DPDK 25.11.3 из каталога пакета.

Включённая в отчёт измерительная серия использовала пакет с SHA-256
`b56f3372f5d00b4c4b072e429a0015636842d17a8132ad8a03e5ba0a9d3ddc96`,
а отпечаток исполняемых исходников `f356e7c68422`. Git commit входит в метаданные
и SHA пакета, а отдельный отпечаток связывает измерение именно с входами сборки
исполняемого кода. В `run-summary.csv` поле `source_dirty=false` подтверждает
чистоту этих входов, а `runner_dirty` отдельно описывает рабочую копию
оркестрации.

## 5. Подготовка измерительных узлов

Чистый узел готовится в следующем порядке от привилегированной системной сессии,
затем перезагружается:

1. [`phc-prepare.sh`](../infra/runner/scripts/phc-prepare.sh) устанавливает
   штатное ядро `6.17.0-1020-aws`, собирает официальный ENA `2.17.2` через
   DKMS с `ENA_PHC_INCLUDE=1`, включает `phc_enable=1` и настраивает `chrony`:

   ```text
   refclock PHC /dev/ptp_ena poll 0 delay 0.000010 prefer
   ```

2. [`dpdk-prepare.sh`](../infra/runner/scripts/dpdk-prepare.sh) выделяет 512
   hugepages по 2 MiB, монтирует `/dev/hugepages`, включает
   `igb_uio wc_activate=1`, находит дополнительный ENA PCI device, сохраняет его
   PCI/MAC/IP в `/etc/spectral-task/dpdk.env` и привязывает этот интерфейс к
   `igb_uio`. Скрипт также устанавливает системные `dpdk`, `dpdk-dev` и
   `dpdk-kmods-dkms` и собирает `igb_uio` для целевого ядра.
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

Сдаваемый профиль задаётся следующими значениями. Сетевые параметры и настройки
пакетирования сохраняются в `manifest.json`; тип событий фиксирован значением
`mixed` в точке запуска producer и печатается в его журнале:

```text
networking backend     = dpdk
compact wire           = 1
DPDK LLQ policy        = 3 (Wide LLQ)
receiver count         = 1..3
warmup                  = 2000 ms
message type           = mixed (журнал producer)
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
нулевым. Цель и ожидание вычисляются до начала трафика и остаются постоянными на
весь запуск. При `N=3` получаются цели 1, 3, 6, 7 и 8 для `0,2M`, `2M`, `4M`,
`4,5M` и `5M` событий/с соответственно.

## 7. Наш автоматизированный путь

Этот раздел описывает готовый путь для IAM-контура репозитория. В нашем контуре
выбран `us-east-1`, а boundary, роли, bucket и placement groups имеют
фиксированные имена. Для другого AWS-аккаунта доступны два варианта:
адаптировать эти параметры в Terraform и предварительной проверке либо выполнить
переносимый сценарий из раздела 8 своей IaC.

Terraform state хранится локально в `infra/runner/terraform.tfstate`. Все фазы
одного стенда выполняются из одной рабочей копии с сохранением этого файла.
Параллельные оркестраторы в одном аккаунте и регионе конфликтуют из-за
фиксированных имён ресурсов. Для другого региона одно значение задаётся в
`workload_region` IAM bootstrap, `aws_region` файла
`infra/runner/terraform.tfvars` и переменной окружения `AWS_RUNNER_REGION`.

### 7.1. Создание стенда

После настройки локальной AWS-сессии:

```bash
make aws-cluster-up
```

Цель сама собирает `.deb`, показывает Terraform plan и выполняет Terraform в
три фазы: сначала сеть/EC2 с аварийным TTL, затем подготовка через SSM и reboot,
затем общий абсолютный TTL. Повтор команды продолжает незавершённую фазу. Для
заведомо неинтерактивного запуска можно явно добавить
`AWS_RUNNER_AUTO_APPROVE=1`. Успех означает, что SHA пакета, изоляция CPU, ядро,
ENA PHC/chrony, data ENI, hugepages и TTL проверены на всех четырёх узлах.

Для явной проверки:

```bash
make aws-cluster-status
make aws-cluster-phc-verify
make aws-cluster-dpdk-verify
```

Цели `aws-cluster-phc-ready` и `aws-cluster-dpdk-ready` нужны для восстановления
или отдельной диагностики. После успешного первичного создания повторная
установка не требуется.

### 7.2. Одиночные проверочные прогоны

Перед запуском задаётся полный профиль сдаваемого варианта:

```bash
export AWS_RUNNER_NETWORKING_BACKEND=dpdk
export AWS_RUNNER_COMPACT_WIRE=1
export AWS_RUNNER_COMPACT_WIRE_MIXED=0
export AWS_RUNNER_DPDK_LLQ_POLICY=3
export AWS_RUNNER_RECEIVER_COUNT=3
export AWS_RUNNER_MESSAGE_COUNT=1000000
export AWS_RUNNER_WARMUP_MS=2000
export AWS_RUNNER_BATCH_TARGET_FRAMES=auto
export AWS_RUNNER_BATCH_WAIT_NS=1200
export AWS_RUNNER_BATCH_PPS_BUDGET=2000000
export AWS_RUNNER_DPDK_RX_BURST_SIZE=32
export AWS_RUNNER_DPDK_RX_FREE_THRESHOLD=0
export AWS_RUNNER_STAGE_TIMESTAMPS=0
export AWS_RUNNER_DPDK_RX_HARDWARE_TIMESTAMPS=0
export AWS_RUNNER_CLOCK_PROBE=0
export AWS_RUNNER_MAX_CLOCK_ERROR_NS=150000
```

Низкая нагрузка:

```bash
make aws-cluster-run AWS_RUNNER_MESSAGE_RATE=200000
```

Высокая нагрузка:

```bash
make aws-cluster-run AWS_RUNNER_MESSAGE_RATE=2000000
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

Stop сохраняет EBS и Terraform state; после следующего start EC2 может оказаться
на другом физическом сервере. После start Claude и наше решение снимаются заново
в соседних блоках.

Каждый штатно завершившийся запуск сам скачивает свои результаты локально.
Команда `aws-cluster-fetch` копирует один запуск: указанный через
`AWS_RUNNER_RUN_ID` либо последний по имени в S3. Перед удалением нужно сверить
все нужные ID из `suite.json` и журналов с каталогами
`artifacts/aws-runner/<run-id>/`; недостающие запуски скачиваются по одному:

```bash
# Повторить для каждого отсутствующего локально запуска.
make aws-cluster-fetch AWS_RUNNER_RUN_ID=RUN_ID
make aws-cluster-down
```

`down` удаляет EC2, EBS, временный S3 bucket, роли и Scheduler, которыми владеет
runner Terraform, а затем сам проверяет отсутствие оставшихся проектных
ресурсов. S3 bucket настроен с `force_destroy=true`, поэтому локальная проверка
артефактов выполняется до этой команды.

Подробности реализации автоматизации находятся в
[`cluster.sh`](../infra/runner/scripts/cluster.sh) и в архитектурном документе
[`aws-runner-topology-and-build.md`](aws-runner-topology-and-build.md).

## 8. Перенос в другой IaC- и IAM-контур

Раздел задаёт проверяемый порядок действий для оркестратора принимающей стороны.
Готовый сквозной оркестратор приведён в разделе 7; при переносе те же барьеры
готовности, параллельные команды на узлах и сбор результатов реализуются через
принятый в организации SSM, SSH или другой механизм управления.

Последовательность подготовки и запуска:

1. Создать `precision-time` placement group, внутри неё дочернюю группу со
   стратегией `cluster`, затем четыре `m8a.xlarge` Ubuntu 24.04 в одной
   AZ/подсети и в этой дочерней группе. Проверить фактический `ParentGroupId`
   через EC2 API.
2. Дать каждому два ENI и сохранить control ENI у Linux.
3. Доставить на узлы один и тот же `.deb` с именем, включающим отпечаток, и
   скрипты `phc-prepare.sh`, `dpdk-prepare.sh`, `runner-bootstrap.sh`,
   `phc-verify.sh`, `dpdk-testpmd.sh`, `unicast-source.sh` и
   `unicast-receiver.sh`. Сохранить ожидаемый SHA-256 пакета.
4. На каждом узле выполнить подготовку строго в этом порядке:

   ```bash
   sudo env PHC_TARGET_KERNEL=6.17.0-1020-aws \
     sh phc-prepare.sh
   sudo env PHC_TARGET_KERNEL=6.17.0-1020-aws \
     sh dpdk-prepare.sh
   sudo env \
     PACKAGE_PATH=/absolute/path/spectral-task.deb \
     EXPECTED_SHA256=PASTE_64_HEX_SHA256_HERE \
     PHC_TARGET_KERNEL=6.17.0-1020-aws \
     sh runner-bootstrap.sh
   ```

   Последний скрипт проверяет SHA, устанавливает пакет и планирует reboot.
5. После загрузки выполнить
   `sudo env MAX_CLOCK_ERROR_NS=150000 sh phc-verify.sh`. Затем одновременно
   провести проверку `testpmd → testpmd` между двумя узлами. На получателе:

   ```bash
   sudo env DPDK_PROBE_ROLE=receiver sh dpdk-testpmd.sh
   ```

   На источнике, пока получатель ожидает трафик:

   ```bash
   sudo env \
     DPDK_PROBE_ROLE=source \
     DPDK_PEER_MAC=RECEIVER_DATA_MAC \
     DPDK_SOURCE_IP=SOURCE_DATA_IP \
     DPDK_DESTINATION_IP=RECEIVER_DATA_IP \
     sh dpdk-testpmd.sh
   ```

   Обе команды должны завершиться с `dpdk_probe_status=passed` и ненулевым
   числом пакетов.
6. Сначала запустить `receiver` и `consumer` на всех узлах-получателях, получить
   от каждого явный READY и только затем запустить узел-источник.
7. Запускать процессы через `taskset` на CPU 2/3, как описано выше.
8. Перед измеряемым диапазоном пропустить прогрев. При 2 секундах и 2 млн/с
   измерение начинается после `seq_id=4 000 000`.
9. Снять состояние часов всех узлов до и после нагрузки и сохранить исходные
   CSV, логи sender/receiver/consumer, SHA пакета, instance IDs и параметры
   запуска.

Низкоуровневые точки запуска находятся в
[`unicast-source.sh`](../infra/runner/scripts/unicast-source.sh) и
[`unicast-receiver.sh`](../infra/runner/scripts/unicast-receiver.sh). Их значения
по умолчанию предназначены для быстрой проверки сокетного backend, поэтому
ручной DPDK-запуск передаёт полный профиль из раздела 6. На источнике обязательны
`DESTINATIONS`, соответствующие `DESTINATION_MACS`, `NETWORKING_BACKEND=dpdk`,
`COMPACT_WIRE=1`, `DPDK_LLQ_POLICY=3`, `MESSAGE_TYPE=mixed`, `MESSAGE_RATE`, `MESSAGE_COUNT`,
`WARMUP_EVENTS`, рассчитанный `BATCH_TARGET_FRAMES` и `BATCH_WAIT_NS`. На каждом
получателе задаются те же `MESSAGE_COUNT`/`WARMUP_EVENTS`,
`NETWORKING_BACKEND=dpdk`, `DPDK_RX_BURST_SIZE=32`,
`DPDK_RX_FREE_THRESHOLD=0`, `STAGE_TIMESTAMPS=0` и
`DPDK_RX_HARDWARE_TIMESTAMPS=0`.

## 9. Как измеряется и валидируется результат

Перед source оркестратор получает READY со всех receiver. Producer прогоняет
`warmup_events = ceil(rate * warmup_ms / 1000)` через полный путь, но consumer
не записывает эти события. Затем каждый consumer сохраняет `seq,latency_ns` в
память и пишет CSV после горячего цикла.

После запуска [`summarize-fanout.py`](../scripts/summarize-fanout.py) создаёт
`fanout-summary.json`. Результат пригоден для сравнения только если:

- package SHA и настройки совпадают с заявленным вариантом;
- instance IDs, число получателей и placement metadata сохранены в manifest;
- выбранные для запуска регион, имя и физический ID AZ, тип EC2 и AMI сохранены;
  все четыре измерительных узла имеют одинаковые значения;
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
- центрированная кривая после вычитания собственного p50 каждого получателя
  показывает форму хвоста при постоянном сдвиге часов конкретной пары узлов.
  Основной метрикой остаётся исходная абсолютная задержка всех получателей.

Для p99.99 нужно не менее миллиона измеряемых событий и несколько повторов.
Даже тогда дальняя точка нестабильна, поэтому вывод должен сопровождаться
полным распределением и разбросом повторов.

Артефакты нашего runner скачиваются в
`artifacts/aws-runner/<run-id>/`; каталог намеренно не коммитится целиком.
Компактные производные данные сдаваемого notebook лежат в
[`data/submission`](../data/submission/README.md).

## 10. Повтор baseline Claude

Claude собирается из отдельной чистой рабочей копии на точном commit
`c86cc26ab2e84996137f922cf175d33e9a622c29`. Путь передаётся только через
переменную окружения:

```bash
git clone https://gitlab.spectral.tech/challenge/agent-solution.git \
  /absolute/path/to/claude-checkout
git -C /absolute/path/to/claude-checkout checkout \
  c86cc26ab2e84996137f922cf175d33e9a622c29
CLAUDE_BASELINE_DIR=/absolute/path/to/claude-checkout \
  scripts/claude-baseline.sh build
scripts/claude-baseline.sh install
```

Финальную матрицу запускает один оркестратор. Методика повторяет
контрсбалансированные блоки из
[отчёта Claude](https://gitlab.spectral.tech/challenge/agent-solution/-/blob/c86cc26ab2e84996137f922cf175d33e9a622c29/SOLUTION.md#measurement-methodology):
в каждом блоке обе реализации запускаются по одному разу, а порядок меняется
через блок — `Claude → DPDK`, затем `DPDK → Claude`. Это устраняет постоянное
преимущество второго запуска и частично сокращает линейный дрейф среды и
межхостовых часов.

Основание для этой схемы - наблюдаемый дрейф среды: разница в несколько
микросекунд между реализациями меняла знак между сессиями, а p99.99 одной
конфигурации менялся более чем на порядок. Единицей статистического сравнения
служит парная разность внутри короткого блока. Объединённые распределения
дополнительно показывают форму задержек.

Для важных выводов используются шесть блоков на каждую частоту:

```text
Claude → DPDK | DPDK → Claude | Claude → DPDK |
DPDK → Claude | Claude → DPDK | DPDK → Claude
```

При невалидном плече оркестратор записывает попытку в `invalid_attempts`,
исключает весь незавершённый блок и повторяет обе его половины в исходном
порядке. Так каждый зачтённый эффект остаётся соседней парой запусков.

Шесть блоков — первая точка, где точный двусторонний знаковый критерий при
одинаковом знаке всех разностей может дать `p < 0,05`:
`2 / 2^6 = 0,03125`. Помимо знака и диапазона шести эффектов публикуется
собственный межблочный разброс Claude. Эффект считается разрешённым, когда он
проходит знаковый критерий и превышает этот разброс. Времена начала и окончания
каждого плеча подтверждают временную близость запусков внутри блока.

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

Одна suite относится к одной непрерывной EC2-эпохе. После пересоздания или
stop/start вся матрица снимается заново. Claude и DPDK контрсбалансируются
отдельно для `N=1` и `N=3`, а дополнительный срез нашего решения при `N=1,2,3`
показывает масштабирование рассылки внутри той же эпохи.

Низкоуровневый `claude-baseline.sh run` предназначен для одиночной диагностики.
Финальную матрицу запускает общий оркестратор, который задаёт одинаковый прогрев,
проверяет чистоту рабочей копии Claude и контрсбалансирует реализации на тех же
работающих EC2. Диагностическая UDP-проба проходит через control ENI и
сохраняется отдельно от основной задержки DPDK.

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

Notebook исполняется из чистой рабочей копии без AWS и каталога `artifacts/`:
все нужные таблицы и эмпирические квантильные кривые уже находятся в
`data/submission`. Корень каталога содержит основную эпоху во вложенном
размещении `precision-time → cluster`. Подкаталог `precision-time-only`
содержит отдельную согласованную эпоху без дочерней `cluster` group. Notebook
показывает каждую на собственной абсолютной шкале. Выводы об эффекте реализации
строятся по сравнениям внутри одной эпохи.

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
Генератор читает исходные CSV по событиям в режиме только для чтения.

Аппаратная RX-метка сохраняется в сыром диагностическом запуске как значение
PHC data ENI. Количественная раскладка использует программные метки на общей
шкале `CLOCK_REALTIME`: доступный `/dev/ptp_ena` принадлежит control ENI, а ENA
PMD используемой версии не предоставляет `read_clock` для прямой калибровки
часов data ENI. Подстановка часов control ENI дала физически невозможные
отрицательные локальные интервалы. Поэтому notebook показывает доверенные
программные интервалы на одном узле и совокупный межхостовый участок.

## 12. Контрольный список приёмки

- [ ] `.deb` собран в контейнере Ubuntu 24.04 и содержит DPDK 25.11.3 ENA PMD.
- [ ] Выбранные для запуска регион, имя и физический ID AZ, AMI и тип EC2
      записаны; все четыре измерительных узла имеют одинаковую конфигурацию и по
      два ENI.
- [ ] Все четыре узла фактически находятся в одной дочерней `cluster` group;
      её родитель — сохранённая `precision-time` group.
- [ ] Control ENI работает на kernel ENA; data ENI - на `igb_uio`.
- [ ] Загружено ядро `6.17.0-1020-aws`, `/dev/ptp_ena` существует, `chrony`
      выбрал PHC.
- [ ] CPU 2-3 изолированы, процессы закреплены согласно роли.
- [ ] В manifest указаны `dpdk`, compact wire, LLQ policy 3, rate, N, warmup,
      цель пачки и package SHA.
- [ ] Журнал producer подтверждает `type=mixed`.
- [ ] Clock snapshots до/после валидны; correction равна 0.
- [ ] Каждый receiver получил требуемый непрерывный диапазон; после отбрасывания
      только несовпадающих краёв общий sequence range совпадает точно.
      Обе точки за рабочей границей помечены `expected_saturation=true` и
      подтверждены ненулевым аппаратным счётчиком ENA.
- [ ] Проверены ENA allowance/error counters.
- [ ] Claude сравнивается только на тех же живых instance IDs.
- [ ] Notebook исполняется с нуля и показывает наши/Claude распределения вместе.
- [ ] Нужные артефакты скачаны до удаления; после проверки стенд остановлен или
      уничтожен.
