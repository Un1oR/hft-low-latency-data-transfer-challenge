# Временная инфраструктура AWS

Terraform разделён на три независимых root-модуля. Поэтому удаление временного
runner не затрагивает постоянный контроль расходов аккаунта.

## 0. Однократный IAM bootstrap

Каталог `bootstrap` применяется из отдельного root-профиля. Он создаёт
permissions boundary и выдаёт `spectral-dev` только те IAM-права, которые нужны
остальным Terraform-модулям. Там же Terraform запрашивает Standard On-Demand
quota 34 vCPU в `us-east-1`. Подробности и ограничения перечислены в
`bootstrap/README.md`.

После bootstrap root-профиль CLI удаляется, а все последующие операции снова
выполняются под `spectral-dev`.

## 1. Контроль бюджета

Каталог `billing-guard` создаёт месячный бюджет на 10 USD по расходу до
применения credits. Credits и refunds исключены из расчёта, поэтому Free Plan
не скрывает фактическое потребление ресурсов.

Настроены предупреждения:

- фактический расход 50%;
- фактический расход 80%;
- прогноз 100%;
- фактический расход 100%.

При фактических 100% отдельный SNS topic вызывает Lambda. Функция останавливает
только EC2-инстансы, у которых одновременно присутствуют теги:

```text
Project  = spectral-task
AutoStop = true
```

AWS Budgets получает обновления биллинга с задержкой, обычно не реже одного
раза в сутки. Поэтому это аварийный рубильник, а не точный real-time лимит.
Основная защита runner от лишних расходов - жёсткий TTL 15 минут.

Применение постоянного контура:

```bash
cd infra/billing-guard
cp terraform.tfvars.example terraform.tfvars
# Укажите alert_email или оставьте пустую строку.
terraform init
terraform plan
terraform apply
```

Email получает прямые уведомления AWS Budgets. SNS используется отдельно для
автоматической остановки и не зависит от почтового адреса.

## 2. Приватный временный runner

> Целевая топология, раскладка CPU и пакетный build flow зафиксированы в
> [`../docs/aws-runner-topology-and-build.md`](../docs/aws-runner-topology-and-build.md).

Каталог `runner` создаёт:

- один source и три receiver-узла Ubuntu 24.04 в одной приватной подсети;
- целевые `m8a.xlarge` с четырьмя физическими ядрами на каждом узле;
- взаимный benchmark-трафик только между узлами одной security group;
- отсутствие публичных IP и внешних входящих правил;
- доступ через SSM Session Manager;
- маленький временный NAT-инстанс для исходящего трафика;
- приватный S3 bucket с готовым Ubuntu 24.04 amd64 `.deb`;
- зашифрованные gp3 root volumes с удалением при завершении инстанса;
- обязательный IMDSv2;
- локальные shutdown-таймеры и одноразовый EventBridge Scheduler, которые
  завершают все benchmark nodes и NAT через `max_runtime_minutes`;
- IAM-роль Scheduler, которой разрешено завершить только instance ARN этого
  временного стенда.

Runner вообще не получает исходники. `make deb` собирает и проверяет пакет в
Ubuntu 24.04 Docker-контейнере. Terraform загружает указанный `package_path` в
приватный S3 и выдаёт instance role доступ `s3:GetObject` только к этому объекту.
SSM Association проверяет SHA-256 и устанавливает пакет через `dpkg --install`.
Компилятор, CMake, nFPM, SSH-ключи, GitHub-токены и доступ EC2 к приватной репе
не нужны.

Физическое имя bucket и префикс `source/` пока сохранены только для совместимости
с уже применённым permissions boundary. Исходников по этому пути больше нет;
смена имени потребовала бы снова применять bootstrap из root-профиля.

По умолчанию создаётся полный fan-out стенд `1 source → 3 receivers` на четырёх
`m8a.xlarge`. У M8a каждый vCPU является физическим ядром: CPU 0-1 остаются
housekeeping, CPU 2-3 изолируются для pinning benchmark-процессов.
Это целевой AWS-гейт, а не замена локальных функциональных тестов.

Число узлов намеренно не настраивается: AWS-стенд всегда воспроизводит полную
топологию `1 source -> 3 receivers`, ради которой и нужен облачный прогон.

Полному стенду и NAT нужно 18 Standard On-Demand vCPU. Уже запрошенная quota
34 vCPU достаточна и оставляет запас. `terraform apply` сам читает текущую
account quota и блокируется, пока она меньше фактически требуемого значения.

Сначала соберите пакет и укажите его путь в локальном `terraform.tfvars`:

```bash
make deb
cp infra/runner/terraform.tfvars.example infra/runner/terraform.tfvars
# Замените package_path на имя только что собранного файла из dist/.
```

Создание и подключение выполняются под `spectral-dev`:

```bash
cd infra/runner
terraform init
terraform plan
terraform apply
terraform output -json ssm_start_session_commands
```

Внутри SSM-сессии:

```bash
sudo tail -f /var/log/cloud-init-output.log
dpkg-query -W spectral-task
cat /proc/cmdline
systemctl status spectral-runner-ttl.timer
```

Удаляйте инфраструктуру сразу после теста:

```bash
terraform destroy
```

Если TTL уже завершил EC2, `terraform destroy` обновит state и удалит оставшиеся
бесплатные сетевые и IAM-ресурсы. После истечения TTL нельзя выполнять обычный
`terraform apply`: он воспримет отсутствующие инстансы как drift и создаст их
заново.

У NAT-инстанса есть публичный IPv4, у benchmark nodes его нет. NAT нужен только
для короткого bootstrap через Ubuntu apt, S3 и исходящих каналов SSM. Его можно
устранить отдельным переходом на заранее подготовленный AMI и VPC endpoints.
