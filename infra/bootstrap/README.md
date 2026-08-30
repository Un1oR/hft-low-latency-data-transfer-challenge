# IAM bootstrap авторского AWS-аккаунта

Этот Terraform root-модуль один раз создаёт permissions boundary и
customer-managed policy для проектного разработчика, разрешающую управлять
только ролями и instance profiles с префиксом `spectral-`.

Значения по умолчанию привязаны к авторскому контуру: account
`753369745053`, IAM user `spectral-dev` и регион `us-east-1`. В другом аккаунте
модуль применяется только после явного переопределения `target_account_id`,
`target_user_name` и `workload_region` и проверки всех policy. Эквивалентные
права можно выдать принятой в организации IAM-схемой без использования этого
модуля.

Модуль также запрашивает EC2 Standard On-Demand quota `34` vCPU в `us-east-1`:
целевому стенду из четырёх `m8a.xlarge` и временного `t4g.nano` нужно 18 vCPU,
остальное является запасом. Увеличение quota может потребовать одобрения AWS и
не создаёт платных ресурсов само по себе. Фактическое значение следует проверять
через Service Quotas: наличие support case означает, что заявка рассматривается,
но ещё не одобрена.

Все проектные роли создаются с boundary, которая ограничивает их эффективные
права следующим набором:

- SSM Managed Instance Core;
- чтение только готового `.deb` из проектного S3 bucket;
- запись benchmark-результатов только в `results/*` того же bucket;
- запись логов только Lambda `spectral-budget-stop`;
- stop и terminate только EC2 в `us-east-1` с тегами
  `Project=spectral-task` и `AutoStop=true`.

Из корня репозитория в краткоживущей привилегированной административной сессии:

```bash
terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap plan \
  -out=bootstrap.tfplan \
  -var='target_account_id=<aws-account-id>' \
  -var='target_user_name=<project-deployer>' \
  -var='workload_region=us-east-1'
terraform -chdir=infra/bootstrap apply bootstrap.tfplan
```

После применения дальнейший жизненный цикл runner выполняется под ограниченной
проектной ролью или пользователем. Привилегированная сессия для штатного запуска
стенда не требуется.
