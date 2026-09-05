# General

This is the standard REST API for external programs that want to
interact with Bugzilla. It provides a REST interface to various Bugzilla
functions.

## Basic Information

**Data Format**

The REST API only supports JSON input, and either JSON or JSONP output.
So objects sent and received must be in JSON format.

If you need JSONP output, you must set the
`Accept: application/javascript` HTTP header and add a `callback`
parameter to name your callback.

Parameters may also be passed in as part of the query string for non-GET
requests and will override any matching parameters in the request body.

Example request which returns the current version of Bugzilla:

``` http
GET /rest/version HTTP/1.1
Host: bugzilla.example.com
```

Example response:

``` http
HTTP/1.1 200 OK
Vary: Accept
Content-Type: application/json

{
  "version" : "4.2.9+"
}
```

**Errors**

When an error occurs over REST, an object is returned with the key
`error` set to `true`.

The error contents look similar to:

``` js
{
  "error": true,
  "message": "Some message here",
  "code": 123
}
```

To protect the application from large requests, Bugzilla returns a 302
redirect to the homepage when your query string is too long. The current
limit is 10 KB, which can accept roughly 1,000 bug IDs in the `id`
parameter for the `/rest/bug` method, but it could be smaller or may
lead to a 414 URI Too Long HTTP error depending on the server
configuration. Split your query into multiple requests if you encounter
the issue.

## Common Data Types

The Bugzilla API uses the following various types of parameters:

<table>
<thead>
<tr class="header">
<th>type</th>
<th>description</th>
</tr>
</thead>
<tbody>
<tr class="odd">
<td>int</td>
<td>Integer.</td>
</tr>
<tr class="even">
<td>double</td>
<td>A floating-point number.</td>
</tr>
<tr class="odd">
<td>string</td>
<td>A string.</td>
</tr>
<tr class="even">
<td><p>email</p></td>
<td><p>A string representing an email address. This value, when
returned, may be filtered based on if the user is logged in or
not.</p></td>
</tr>
<tr class="odd">
<td>date</td>
<td>A specific date. Example format: <code>YYYY-MM-DD</code>.</td>
</tr>
<tr class="even">
<td><p>datetime</p></td>
<td><p>A date/time. Timezone should be in UTC unless otherwise noted.
Example format: <code>YYYY-MM-DDTHH24:MI:SSZ</code>.</p></td>
</tr>
<tr class="odd">
<td>boolean</td>
<td><code>true</code> or <code>false</code>.</td>
</tr>
<tr class="even">
<td><p>base64</p></td>
<td><p>A base64-encoded string. This is the only way to transfer binary
data via the API.</p></td>
</tr>
<tr class="odd">
<td><p>array</p></td>
<td><p>An array. There may be mixed types in an array. <code>[</code>
and <code>]</code> are used to represent the beginning and end of
arrays.</p></td>
</tr>
<tr class="even">
<td><p>object</p></td>
<td><p>A mapping of keys to values. Called a "hash", "dict", or "map" in
some other programming languages. The keys are strings, and the values
can be any type. <code>{</code> and <code>}</code> are used to represent
the beginning and end of objects.</p></td>
</tr>
</tbody>
</table>

Parameters that are required will be displayed in **bold** in the
parameters table for each API method.

## Authentication

Some methods do not require you to log in. An example of this is
`rest_single_bug`. However, authenticating yourself allows you to see
non-public information, for example, a bug that is not publicly visible.

To authenticate yourself, you will need to use API keys:

**API Keys**

You can specify 'X-BUGZILLA-API-KEY' header with the API key as a value
to any request, and you will be authenticated as that user if the key is
correct and has not been revoked.

You can set up an API key by using the `API Keys tab <api-keys>` in the
Preferences pages.

**WARNING**: It should be noted that additional authentication methods
exist, but they are **not recommended** for use and are likely to be
deprecated in future versions of BMO, due to security concerns. These
additional methods include the following:

> - api key via `Bugzilla_api_key` or simply `api_key` in query
>   parameters.

## Useful Parameters

Many calls take common arguments. These are documented below and linked
from the individual calls where these parameters are used.

**Including Fields**

Many calls return an array of objects with various fields in the
objects. (For example, `rest_single_bug` returns a list of `bugs` that
have fields like `id`, `summary`, `creation_time`, etc.)

These parameters allow you to limit what fields are present in the
objects, to improve performance or save some bandwidth.

`include_fields`: The (case-sensitive) names of fields in the response
data. Only the fields specified in the object will be returned, the rest
will not be included. Fields should be comma delimited.

Invalid field names are ignored.

Example request to `rest_user_get`:

``` text
GET /rest/user/1?include_fields=id,name
```

would return something like:

``` js
{
  "users" : [
    {
      "id" : 1,
      "name" : "user@domain.com"
    }
  ]
}
```

**Excluding Fields**

`exclude_fields`: The (case-sensitive) names of fields in the return
value. The fields specified will not be included in the returned
objects. Fields should be comma delimited.

Invalid field names are ignored.

Specifying fields here overrides `include_fields`, so if you specify a
field in both, it will be excluded, not included.

Example request to `rest_user_get`:

``` js
GET /rest/user/1?exclude_fields=name
```

would return something like:

``` js
{
  "users" : [
    {
      "id" : 1,
      "real_name" : "John Smith"
    }
  ]
}
```

Some calls support specifying "subfields". If a call states that it
supports "subfield" restrictions, you can restrict what information is
returned within the first field. For example, if you call
`rest_product_get` with an `include_fields` of `components.name`, then
only the component name would be returned (and nothing else). You can
include the main field, and exclude a subfield.

There are several shortcut identifiers to ask for only certain groups of
fields to be returned or excluded:

<table>
<thead>
<tr class="header">
<th>value</th>
<th>description</th>
</tr>
</thead>
<tbody>
<tr class="odd">
<td><p>_all</p></td>
<td><p>All possible fields are returned if this is specified in
<code>include_fields</code>.</p></td>
</tr>
<tr class="even">
<td><p>_default</p></td>
<td><p>Default fields are returned if <code>include_fields</code> is
empty or this is specified. This is useful if you want the default
fields in addition to a field that is not normally returned.</p></td>
</tr>
<tr class="odd">
<td><p>_extra</p></td>
<td><p>Extra fields are not returned by default and need to be manually
specified in <code>include_fields</code> either by exact field name, or
adding <code>_extra</code>.</p></td>
</tr>
<tr class="even">
<td><blockquote>
<p>_custom</p>
</blockquote></td>
<td><p>Custom fields are normally returned by default unless this is
added to <code>exclude_fields</code>. Also you can use it in
<code>include_fields</code> if for example you want specific field names
plus all custom fields. Custom fields are normally only relevant to bug
objects.</p></td>
</tr>
</tbody>
</table>
