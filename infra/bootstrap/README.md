# Bootstrap IAM через root

Этот Terraform root-модуль нужен один раз. Он создаёт permissions boundary и
customer-managed policy для `spectral-dev`, разрешающую управлять только ролями
и instance profiles с префиксом `spectral-`.

Модуль также запрашивает EC2 Standard On-Demand quota `34` vCPU в `us-east-1`:
целевому стенду из четырёх `m8a.xlarge` и временного `t4g.nano` нужно 18 vCPU,
остальное является запасом. Увеличение quota может потребовать одобрения AWS и
не создаёт платных ресурсов само по себе. Фактическое значение следует проверять
через Service Quotas: наличие support case означает, что заявка рассматривается,
но ещё не одобрена.

Новые роли обязательно создаются с boundary. Даже если в inline policy роли
случайно окажется лишнее действие, её эффективные права не выйдут за пределы:

- SSM Managed Instance Core;
- чтение только готового `.deb` из проектного S3 bucket;
- запись benchmark-результатов только в `results/*` того же bucket;
- запись логов только Lambda `spectral-budget-stop`;
- stop и terminate только EC2 в `us-east-1` с тегами
  `Project=spectral-task` и `AutoStop=true`.

Из root-профиля:

```bash
terraform init
terraform plan
terraform apply
```

После применения root-профиль CLI следует удалить командой `aws logout`, а
обычную работу продолжать под `spectral-dev`. Текущая версия boundary с точечной
записью в `results/*` уже применена; повторный root login для штатного runner
flow не требуется.
