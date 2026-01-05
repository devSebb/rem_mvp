# Documentación API para Comercios (ES)

Estos endpoints permiten a los comercios validar y consultar gift cards usando el mismo token efímero que se emplea para las redenciones. Todas las cantidades están expresadas en centavos (`amount_cents`, `remaining_balance_cents`, `balance_cents`) y **siempre** debes autenticarte con el `secret_key` del comercio:

```
Authorization: Bearer <MERCHANT_SECRET_KEY>
```

---

## Validar saldo

`POST /api/v1/gift_cards/validate`

### Body (JSON)

```json
{
  "token": "RAW_TOKEN_COMPARTIDO",
  "amount_cents": 2000
}
```

### Respuesta 200 OK

```json
{
  "valid": true,
  "gift_card_id": 42,
  "remaining_balance_cents": 8000,
  "currency": "USD"
}
```

### Respuesta 422 - ejemplo `insufficient_funds`

```json
{
  "valid": false,
  "error": "insufficient_funds",
  "gift_card_id": 42,
  "remaining_balance_cents": 1500,
  "currency": "USD"
}
```

Otros posibles errores (`valid: false`): `inactive_gift_card`, `expired_token`, `token_used`.

### cURL de ejemplo

```bash
curl -X POST http://localhost:3000/api/v1/gift_cards/validate \
  -H "Authorization: Bearer <MERCHANT_SECRET_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "token":"RAW_TOKEN_COMPARTIDO",
    "amount_cents":2000
  }'
```

---

## Consultar balance por token

`GET /api/v1/gift_cards/:token`

### Respuesta 200 OK

```json
{
  "gift_card_id": 42,
  "balance_cents": 8000,
  "currency": "USD",
  "status": "active"
}
```

### Respuesta 404

```json
{ "error": "Not Found" }
```

### Respuesta 422 (token expirado o usado)

```json
{ "error": "expired_token" }
```

### cURL de ejemplo

```bash
curl -X GET http://localhost:3000/api/v1/gift_cards/RAW_TOKEN_COMPARTIDO \
  -H "Authorization: Bearer <MERCHANT_SECRET_KEY>"
```

---

### Notas

- Los tokens expiran en ~90 segundos y se invalidan después de usarse.
- Los comercios no pueden acceder a información personal del comprador o destinatario; sólo reciben identificadores y datos de balance.
- Se recomienda reutilizar el mismo token que el cliente muestra en su app/QR justo antes de cobrar.

