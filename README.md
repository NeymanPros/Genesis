# Описание

Генератор Ruby-интеграций с платёжными провайдерами по OpenAPI-спецификации.

На вход YAML, на выход класс-сервис, который вписывается в
`Provider::BaseService` платформы Space Payments, гайд для оператора и
готовые фикстуры под тесты. В runtime — только парсер YAML, регекспы и
ERB-шаблоны.

---

## Что делает

Из `tasks/provider_api.yaml` (спека NovaPay из ТЗ) собирает четыре файла:

```
output/novapay/
├── novapay_service.rb    # class Provider::NovapayService < BaseService
├── INTEGRATION.md        # что настроить оператору
├── fixtures.json         # 7+ тестовых сценариев
└── UNSUPPORTED.md        # что взято best-effort, с готовым overrides для копипаста
```

Плюс скрытый `.integrate.meta.json` с версией, timestamp и SHA256
исходной спеки — чтобы всегда было понятно, из чего сгенерирован файл.

## Установка

```
bundle install
```

Включает три зависимости: `openapi3_parser`, `thor`, `rspec` (test-only). 

## Запуск

```sh
bin/integrate generate --spec tasks/provider_api.yaml --provider novapay
```

При успешном запуске:

```
Parsing spec...
Found 5 endpoints: POST /payouts, GET /payouts/{payout_id}, POST /payouts/{payout_id}/cancel, POST /webhooks/payout, GET /balance
Auth: ApiKeyAuth (header: X-API-Key)
Webhook signature: X-NovaPay-Signature (hmac_sha256)
Generating service...
Generating integration guide...
Generating test fixtures...
UNSUPPORTED: 6 ambiguous → ./output/novapay/UNSUPPORTED.md

Output:
  ./output/novapay/novapay_service.rb
  ./output/novapay/INTEGRATION.md
  ./output/novapay/fixtures.json
  ./output/novapay/UNSUPPORTED.md
  ./output/novapay/.integrate.meta.json
```

Проверка, что сгенерированный класс имеет все методы контракта
`Provider::BaseService`:

```sh
bin/integrate verify output/novapay/novapay_service.rb
# → ✓ Provider::NovapayService loaded under stub, all 4 contract methods present.
```

## Флаги

| Флаг         | Обязателен | По умолчанию          | Что делает                             |
|--------------|------------|-----------------------|----------------------------------------|
| `--spec`     | да         | —                     | путь к OpenAPI YAML                    |
| `--provider` | да         | —                     | slug (например `novapay`)              |
| `--output`   | нет        | `./output/<provider>` | куда писать файлы                      |
| `--rules`    | нет        | —                     | YAML с overrides / кастомными правилами|
| `--lang`     | нет        | `ruby`                | в MVP только `ruby`                    |

Exit-коды: `0` успех, `2` невалидная спека, `3` сломанный контракт (`verify`),
`65` невалидный overrides YAML, `66` файл не найден.

## Ambiguous и overrides

Многое из OpenAPI приходится домысливать, например, единицы `amount` (копейки vs
рубли), кодирование HMAC (hex vs base64), что именно подписывать (raw
body vs JSON.dump), нужен ли `credentials.fetch('key')` или
`credentials.key`. Генератор **не молчит про догадки** — каждая
эвристическая находка попадает в `UNSUPPORTED.md` с готовым YAML-куском
для копипаста:

```markdown
### amount → minor (units)
Source: description: "Сумма в копейках" at properties.amount.
To override:
```yaml
overrides:
  amount_unit: minor    # or `major`
```

Нужно скопировать в свой `overrides.yaml`, передать через `--rules` — и warning
исчез. Готовый пример: `examples/novapay_overrides.yaml`. Второй пример
(другой провайдер, `PayCloud`, bearer + HMAC-SHA512 + Stripe-format)
находится в `examples/paycloud_api.yaml` и `examples/paycloud_overrides.yaml`
— на нём же проверяется универсальность тулы.

Полный список примитивов overrides: `amount_unit`, `required_if`,
`signature.{algo,encoding,body,format}`, `credentials_access`,
`status_map`, `error_map`.

## Тесты

```sh
bundle exec rspec
# → 95 examples, 0 failures
```

Живут в `spec/`, покрывают все слои:

| Файл                                                        | Что проверяет |
|-------------------------------------------------------------|---------------|
| `spec/parser/openapi_spec.rb`                               | парсинг спеки в IR, роли эндпоинтов, auth, webhook |
| `spec/rules/{status_map,overrides}_spec.rb`                 | маппинг статусов, валидация overrides |
| `spec/generator/service_spec.rb`                            | snapshot сгенерированного `novapay_service.rb` |
| `spec/generator/service_paycloud_spec.rb`                   | snapshot для второго провайдера |
| `spec/generator/contract_spec.rb`                           | сгенерированный класс наследуется от `BaseService`, все 4 метода на месте |
| `spec/generator/behaviour_spec.rb`                          | `create_request` / `fetch_status` / `process_callback` вызываются с fake HTTP-клиентом, проверяются запросы и обработка 201/422/409/rate-limit/bad signature |
| `spec/generator/{doc,fixtures,unsupported}_spec.rb`         | секции INTEGRATION.md, валидность JSON, готовые `overrides:` в UNSUPPORTED.md |
| `spec/integration/*.rb`                                     | end-to-end прогон Runner на обеих спеках |
| `spec/cli_spec.rb`                                          | CLI, exit-коды |

Красивый вывод:

```sh
bundle exec rspec --format documentation
```

## Быстрая проверка

```sh
bundle install
bin/integrate generate --spec tasks/provider_api.yaml --provider novapay
cat output/novapay/novapay_service.rb   # ← основной артефакт
cat output/novapay/UNSUPPORTED.md       # ← что не смогли/угадали
bin/integrate verify output/novapay/novapay_service.rb
```

## Структура проекта

```
lib/integrate/    парсер, правила, генераторы
templates/        ERB-шаблоны сервиса, гайда, отчётов
config/           дефолтные YAML-правила (статусы, ошибки, поля)
spec/             95 тестов
examples/         вторая тест-спека (PayCloud) + готовые overrides
bin/integrate     CLI (Thor)
```

