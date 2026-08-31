# Webhooks

These methods are used to access information about and update your configured
webhooks.

NOTE: You will need to pass in a valid API key with the
`X-Bugzilla-API-Key` header to perform an
operations.

## List

Returns a list of your currently configured webhooks.

**Request**

``` text
GET /rest/webhooks/list
```

**Response**

``` js
{
  "webhooks": [
    {
      "component": "General",
      "creator": "admin@mozilla.bugs",
      "enabled": true,
      "errors": 0,
      "event": "create,change,attachment,comment",
      "id": 1,
      "name": "Test Webhooks",
      "product": "Firefox",
      "url": "http://server.example.com"
    }
  ]
}
```

| name | type | description |
|----|----|----|
| id | integer | The integer ID of the webhook. |
| creator | string | The account which created the webhook. |
| name | string | The name of the webhook. |
| url | string | The URL that is called when the webhook executes. |
| event | string | Comma delimited list of bug events that the webhook will execute. |
| product | string | The product for which the webhook will execute. |
| component | string | The component for which the webhook will execute. |
| enabled | boolean | Whether the webhook is current enabled or not. |
| errors | integer | Current count of any errors encounted when executing the webhook. |
