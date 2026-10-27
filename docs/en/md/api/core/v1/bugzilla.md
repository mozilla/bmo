# Bugzilla Information

These methods are used to get general configuration information about this
Bugzilla instance.

## Version

Returns the current version of Bugzilla. Normally in the format of `X.X` or
`X.X.X`. For example, `4.4` for the initial release of a new branch. Or `4.4.6`
for a minor release on the same branch.

**Request**

``` text
GET /rest/version
```

**Response**

``` js
{
  "version": "4.5.5+"
}
```

| name    | type   | description                          |
|---------|--------|--------------------------------------|
| version | string | The current version of this Bugzilla |

## Extensions

Gets information about the extensions that are currently installed and enabled
in this Bugzilla.

**Request**

``` text
GET /rest/extensions
```

**Response**

``` js
{
  "extensions": {
    "Voting": {
      "version": "4.5.5+"
    },
    "BmpConvert": {
      "version": "1.0"
    }
  }
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
<td>extensions</td>
<td>object</td>
<td><p>An object containing the extensions enabled as keys. Each extension
object contains the following keys:</p>
<ul>
<li><code>version</code> (string) The version of the extension.</li>
</ul></td>
</tr>
</tbody>
</table>

## Timezone

Returns the timezone in which Bugzilla expects to receive dates and times on
the API. Currently hard-coded to UTC ("+0000"). This is unlikely to change.

**Request**

``` text
GET /rest/timezone
```

``` js
{
  "timezone": "+0000"
}
```

**Response**

| name     | type   | description                                                     |
|----------|--------|-----------------------------------------------------------------|
| timezone | string | The timezone offset as a string in (+/-)XXXX (RFC 2822) format. |

## Time

Gets information about what time the Bugzilla server thinks it is, and what
timezone it's running in.

**Request**

``` text
GET /rest/time
```

**Response**

``` js
{
  "web_time_utc": "2014-09-26T18:01:30Z",
  "db_time": "2014-09-26T18:01:30Z",
  "web_time": "2014-09-26T18:01:30Z",
  "tz_offset": "+0000",
  "tz_short_name": "UTC",
  "tz_name": "UTC"
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
<td>db_time</td>
<td>string</td>
<td><p>The current time in UTC, according to the Bugzilla database server.</p>
<p>Note that Bugzilla assumes that the database and the webserver are running
in the same time zone. However, if the web server and the database server
aren't synchronized or some reason, <em>this</em> is the time that you should
rely on or doing searches and other input to the WebService.</p></td>
</tr>
<tr>
<td>web_time</td>
<td>string</td>
<td><p>This is the current time in UTC, according to Bugzilla's web server.</p>
<p>This might be different by a second from <code>db_time</code> since this
comes from a different source. If it's any more different than a second, then
there is likely some problem with this Bugzilla instance. In this case you
should rely on the <code>db_time</code>, not the
<code>web_time</code>.</p></td>
</tr>
<tr>
<td>web_time_utc</td>
<td>string</td>
<td>Identical to <code>web_time</code>. (Exists only for
backwards-compatibility with versions of Bugzilla before 3.6.)</td>
</tr>
<tr>
<td>tz_name</td>
<td>string</td>
<td>The literal string <code>UTC</code>. (Exists only for
backwards-compatibility with versions of Bugzilla before 3.6.)</td>
</tr>
<tr>
<td>tz_short_name</td>
<td>string</td>
<td>The literal string <code>UTC</code>. (Exists only for
backwards-compatibility with versions of Bugzilla before 3.6.)</td>
</tr>
<tr>
<td>tz_offset</td>
<td>string</td>
<td>The literal string <code>+0000</code>. (Exists only for
backwards-compatibility with versions of Bugzilla before 3.6.)</td>
</tr>
</tbody>
</table>

## Job Queue Status

Reports the status of the job queue.

**Request**

``` text
GET /rest/jobqueue_status
```

This method requires an authenticated user.

**Response**

``` js
{
  "total": 12,
  "errors": 0
}
```

| name   | type    | description                                         |
|--------|---------|-----------------------------------------------------|
| total  | integer | The total number of jobs in the job queue.          |
| errors | integer | The number of errors produced by jobs in the queue. |
