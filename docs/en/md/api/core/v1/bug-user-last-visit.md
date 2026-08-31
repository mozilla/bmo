# Bug User Last Visited

## Update Last Visited

Update the last-visited time for the specified bug and current user.

**Request**

To update the time for a single bug id:

``` text
POST /rest/bug_user_last_visit/(id)
```

To update one or more bug ids at once:

``` text
POST /rest/bug_user_last_visit
```

``` js
{
  "ids" : [35,36,37]
}
```

| name    | type  | description                    |
|---------|-------|--------------------------------|
| **id**  | int   | An integer bug id.             |
| **ids** | array | One or more bug ids to update. |

**Response**

``` js
[
  {
    "id" : 100,
    "last_visit_ts" : "2014-10-16T17:38:24Z"
  }
]
```

An array of objects containing the items:

| name          | type     | description                                  |
|---------------|----------|----------------------------------------------|
| id            | int      | The bug id.                                  |
| last_visit_ts | datetime | The timestamp the user last visited the bug. |

**Errors**

- 1300 (User Not Involved with Bug) The caller's account is not involved with
  the bug id provided.

## Get Last Visited

**Request**

Get the last-visited timestamp for one or more specified bug ids or get a list
of the last 20 visited bugs and their timestamps.

To return the last-visited timestamp for a single bug id:

``` text
GET /rest/bug_user_last_visit/(id)
```

To return more than one specific bug timestamps:

``` text
GET /rest/bug_user_last_visit/123?ids=234&ids=456
```

To return all the timestamps stored during the retention period:

``` text
GET /rest/bug_user_last_visit
```

| name    | type  | description                          |
|---------|-------|--------------------------------------|
| **id**  | int   | An integer bug id.                   |
| **ids** | array | One or more optional bug ids to get. |

**Response**

``` js
[
  {
    "id" : 100,
    "last_visit_ts" : "2014-10-16T17:38:24Z"
  }
]
```

An array of objects containing the following items:

| name          | type     | description                                  |
|---------------|----------|----------------------------------------------|
| id            | int      | The bug id.                                  |
| last_visit_ts | datetime | The timestamp the user last visited the bug. |
