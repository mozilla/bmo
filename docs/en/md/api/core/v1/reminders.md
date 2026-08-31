# Reminders

This part of the Bugzilla API allows creating, listing, and removing of
Bugzilla reminders.

## Get Reminder

This allows you to retrieve information about a specific reminder.

**Request**

``` text
GET /rest/reminder/123
```

**Response**

``` js
{
  "id": 123,
  "bug_id": 456,
  "note": "This is a reminder note",
  "reminder_ts": "2024-06-08",
  "creation_ts": "2024-06-07",
  "sent": false
}
```

To get all reminders for your account:

``` text
GET /rest/reminder
```

**Response**

``` js
{
  "reminders": [
    {
      "id": 123,
      "bug_id": 456,
      "note": "This is a reminder note",
      "reminder_ts": "2024-06-08",
      "creation_ts": "2024-06-07",
      "sent": false
    }
  ]
}
```

<a id="rest_reminder_object"></a>

Reminder Object

| name | type | description |
|----|----|----|
| id | int | An integer ID uniquely identifying the reminder in this installation only. |
| bug_id | int | Bug ID associated with the reminder. |
| note | string | A descriptive note associated with the reminder. |
| reminder_ts | date | The date when the reminder will be sent out. |
| creation_ts | date | The date when the reminder was originally created. |
| sent | boolean | A boolean value that is set to true when delivered. |

## Create Reminder

This allows you to create a new reminder associated with a specific bug in
Bugzilla.

**Request**

To create a new reminder:

``` text
{
  "bug_id": 456,
  "note" : "This is a reminder note",
  "reminder_ts" : "2024-06-08"
}
```

<table>
<thead>
<tr>
<th>name</th>
<th>type</th>
<th>description</th>
</tr>
</thead>
<tbody>
<tr>
<td>bug_id</td>
<td>int</td>
<td><blockquote>
<p>Bug ID associated with the reminder.</p>
</blockquote></td>
</tr>
<tr>
<td>note</td>
<td>string</td>
<td><blockquote>
<p>A descriptive note associated with the reminder.</p>
</blockquote></td>
</tr>
<tr>
<td>reminder_ts</td>
<td>date</td>
<td><blockquote>
<p>The date when the reminder will be sent out.</p>
</blockquote></td>
</tr>
</tbody>
</table>

**Response**

``` js
{
  "id": 123,
  "bug_id": 456,
  "note": "This is a reminder note",
  "reminder_ts": "2024-06-08",
  "creation_ts": "2024-06-07",
  "sent": false
}
```

A reminder object [rest_reminder_object](#rest_reminder_object) is
returned.

## Remove Reminder

This allows you to remove an existing reminder in Bugzilla.

**Request**

``` text
DELETE /rest/reminder/123
```

**Response**

If the removal of the reminder was successful, it should look like:

``` js
{
  "success": 1
}
```
