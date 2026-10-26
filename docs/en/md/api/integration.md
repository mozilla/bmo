# Integration Best Practices

## Use supported interfaces

Use the [documented native REST API](core/v1/index.md) for new
integrations. BzAPI remains available as a compatibility layer, but it is
deprecated. Existing BzAPI integrations should migrate to the native REST API.
If immediate migration is not possible, use BMO's built-in `/bzapi/`
compatibility endpoint prefix instead of the retired standalone BzAPI service.
The compatibility layer performs additional request and response translation.

Do not rely on scraped HTML, bug lists exported as CSV or XML, or undocumented
endpoints when your integration requires a stable interface. Use documented
REST API methods that are not marked experimental. See the [API
overview](../integrating/apis.md) for the other interfaces that Bugzilla provides.

## Use a dedicated bot account

Do not reuse a person's account for automation. Human accounts may acquire
privileges that the integration does not need. Request a dedicated bot account
by [filing an Administration
bug](https://bugzilla.mozilla.org/enter_bug.cgi?product=bugzilla.mozilla.org&component=Administration).
Grant the account only the privileges required by the integration.

Authenticate with an API key in the `X-BUGZILLA-API-KEY` request header. Do not
put API keys in URLs, where they can be captured in logs and browser history.
See [REST API authentication](core/v1/general.md#authentication) for details.

## Poll responsibly

Following the [original BMO integration
policy](https://wiki.mozilla.org/index.php?title=BMO/Integration_Best_Practice&oldid=1148498),
do not poll BMO more frequently than once every five minutes. If an integration
needs lower-latency updates, use the [Webhooks
API](../extensions/Webhooks/api/v1/index.md). Contact the BMO team in the
[BMO Matrix channel](https://chat.mozilla.org/#/room/#bmo:mozilla.org) to
discuss requirements that the documented webhooks do not meet.

Authenticate polling and batch-read requests. BMO applies per-IP rate limits to
anonymous reads. The request that reaches a limit can return a JSON HTTP 400
rate-limit error, while subsequent requests from the blocked IP can return an
HTML HTTP 429 response. When either response occurs, retry with exponential
backoff and jitter. BMO does not currently send a `Retry-After` header. Apply
the same backoff to transient 5xx responses.

Poll incrementally instead of repeating a full search. The `last_change_time`
parameter to [Search Bugs](core/v1/bug.md#search-bugs) returns bugs modified at
or after the supplied timestamp. Bug searches may use a read replica, while
`GET /rest/time` reads the primary database. Because BMO does not guarantee a
maximum replication lag, an integration that requires a guaranteed polling
window should confirm the current operational guidance with the BMO team. A
polling cycle should:

- obtain BMO's current `db_time` from [GET /rest/time](core/v1/bugzilla.md#time)
  before searching;
- search from at least five minutes before the previous successful cycle's
  recorded time to provide headroom for replica lag and one-second timestamp
  precision;
- pass `order=bug_id` and choose an explicit page size below BMO's current
  10,000-result search cap, such as `limit=1000`. BMO silently lowers limits
  above the cap, so never use a larger requested value as the termination
  threshold. Page with `limit` and `offset` until a page contains fewer bugs
  than the chosen page size. The response does not indicate when more results
  are available. Do not use `limit=0` for paging; it discards the supplied
  `offset` and the search remains capped;
- collect the bug IDs from every page, then fetch and process every unique bug
  before saving the new `db_time`; and
- discard the de-duplication set after each cycle. If a bug appears in a later
  cycle, fetch it again even when its `last_change_time` matches the value
  previously processed, because multiple changes can occur within the API's
  one-second timestamp precision.

## Minimize requests and responses

Request only the fields the integration uses by setting
[include_fields](core/v1/general.md#rest-include-fields). This reduces response size and
server work. For polling searches, use `include_fields=id,last_change_time` and
fetch the full bugs after all pages have been collected.

Combine requests when possible. For example, request multiple bug IDs in one
call with `GET /rest/bug?id=123,456` instead of issuing one request per bug.
Keep each batch below both [BMO's request-target size
limit](core/v1/general.md#rest-query-string-limit) and the search result cap. This search
silently omits bugs that do not exist or that the caller cannot see, and
requests above the result cap may also omit IDs because the results were
truncated. For batches within these limits, compare the returned IDs with the
requested set and treat missing IDs as not visible, not as deleted. In
contrast, `GET /rest/bug/<id>` returns an explicit error for a missing or
invisible bug.

Whenever a search is paged with `limit` and `offset`, pass a stable `order`
such as `order=bug_id`.

## Write searches that survive configuration changes

Do not hard-code every open or closed status. Use `status=__open__` to search
all open bugs and `status=__closed__` to search all closed bugs. New workflow
statuses can then be added without breaking the integration.

Similarly, do not enumerate every resolution when searching for bugs that were
closed without being fixed. Use the custom-search parameters
`status=__closed__&f1=resolution&o1=notequals&v1=FIXED`. This allows new
non-fixed resolutions to be introduced without changing the integration.

When combining `last_change_time` with custom-search parameters, number the
`f<n>` charts contiguously starting with `f1`. Gaps in the numbering can cause
the generated change-time chart to replace an existing chart.
