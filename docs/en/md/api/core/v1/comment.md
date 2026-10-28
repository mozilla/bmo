# Comments

## Get Comments

This allows you to get data about comments, given a bug ID or comment ID.

**Request**

To get all comments for a particular bug using the bug ID or alias:

``` text
GET /rest/bug/(id_or_alias)/comment
```

To get a specific comment based on the comment ID:

``` text
GET /rest/bug/comment/(comment_id)
```

| name | type | description |
|----|----|----|
| **id_or_alias** | mixed | A single integer bug ID or alias. |
| **comment_id** | int | A single integer comment ID. |
| new_since | datetime | If specified, the method will only return comments *newer* than this time. This only affects comments returned from the `ids` argument. You will always be returned all comments you request in the `comment_ids` argument, even if they are older than this date. |
| include_fields | array | Pass `_collapsed_comments` to include comments that are collapsed in the web UI (see below). As with the other underscore-prefixed values it does not imply `_default`, so use `include_fields=_default,_collapsed_comments` to get the usual comment fields as well. |
| skip_private | boolean | If true, inaccessible or invalid bugs are omitted instead of causing an error. This parameter is experimental. |

Comments that are collapsed in the web UI -- those tagged with one of the tags
listed in the `collapsed_comment_tags` parameter (`spam`, `abusive`, etc),
and those authored by treeherder -- are left out of the comments returned for a
bug entirely unless `_collapsed_comments` is requested. Comments requested by
`comment_id` are always returned, collapsed or not.

**Response**

``` js
{
  "bugs": {
    "35": {
      "comments": [
        {
          "time": "2000-07-25T13:50:04Z",
          "text": "test bug to fix problem in removing from cc list.",
          "raw_text": "test bug to fix problem in removing from cc list.",
          "bug_id": 35,
          "count": 0,
          "attachment_id": null,
          "is_private": false,
          "tags": [],
          "collapsed": false,
          "creator": "user@bugzilla.org",
          "author": "user@bugzilla.org",
          "creation_time": "2000-07-25T13:50:04Z",
          "reactions": {
           "+1": 3,
           "heart": 2,
           "tada": 1
          },
          "id": 75
        }
      ]
    }
  },
  "comments": {}
}
```

This example assumes comment tagging and comment reactions are enabled.

Two items are returned:

`bugs` This is used for bugs specified in `ids`. This is an object, where the
keys are the numeric IDs of the bugs, and the value is an object with a single
key, `comments`, which is an array of comments. (The format of comments is
described below.)

Any individual bug will only be returned once, so if you specify an ID multiple
times in `ids`, it will still only be returned once.

`comments` Each individual comment requested in `comment_ids` is returned here,
in an object where the numeric comment ID is the key, and the value is the
comment. (The format of comments is described below.)

A "comment" as described above is an object that contains the following items:

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
<td>id</td>
<td>int</td>
<td>The globally unique ID for the comment.</td>
</tr>
<tr>
<td>bug_id</td>
<td>int</td>
<td>The ID of the bug that this comment is on.</td>
</tr>
<tr>
<td>attachment_id</td>
<td>int</td>
<td>If the comment was made on an attachment, this will be the ID of that
attachment. Otherwise it will be null.</td>
</tr>
<tr>
<td>count</td>
<td>int</td>
<td>The number of the comment local to the bug. The description is comment 0;
subsequent comments start with 1.</td>
</tr>
<tr>
<td>text</td>
<td>string</td>
<td>The body of the comment, including any special text (such as "this bug was
marked as a duplicate of...").</td>
</tr>
<tr>
<td>raw_text</td>
<td>string</td>
<td>The body of the comment without any special additional text.</td>
</tr>
<tr>
<td>creator</td>
<td>string</td>
<td>The login name of the comment's author.</td>
</tr>
<tr>
<td>author</td>
<td>string</td>
<td>A backwards-compatible alias for <code>creator</code>. New clients should
use <code>creator</code>.</td>
</tr>
<tr>
<td>tags</td>
<td>array</td>
<td>Tags attached to the comment. Only present when comment tagging is
enabled.</td>
</tr>
<tr>
<td>time</td>
<td>datetime</td>
<td>The time in UTC that the comment was added.</td>
</tr>
<tr>
<td>creation_time</td>
<td>datetime</td>
<td><p>This is exactly same as the <code>time</code> key. Use this field
instead of <code>time</code> for consistency with other methods including <a
href="bug.md#get-bug">Get Bug</a> and <a
href="attachment.md#get-attachment">Get Attachment</a>.</p>
<p>For compatibility, <code>time</code> is still usable. However, please note
that <code>time</code> may be deprecated and removed in a future
release.</p></td>
</tr>
<tr>
<td>is_private</td>
<td>boolean</td>
<td><code>true</code> if this comment is private (only visible to a certain
group called the "insidergroup"), <code>false</code> otherwise.</td>
</tr>
<tr>
<td>edit_count</td>
<td>int</td>
<td><p>The number of times this comment has been edited. <code>0</code> if the
comment has never been edited.</p>
<p>Only present for users who are allowed to edit other people's comments.
Revisions hidden by an edit-comments admin are only counted for members of the
edit-comments admins group.</p></td>
</tr>
<tr>
<td>last_change_time</td>
<td>datetime</td>
<td><p>The time in UTC of the most recent edit to this
comment, or null if the comment has never been edited.</p>
<p>Only present for users who are allowed to edit other people's comments, and
follows the same rules as <code>edit_count</code> for hidden
revisions.</p></td>
</tr>
<tr>
<td>reactions</td>
<td>object</td>
<td>An object containing reacted emoji names and corresponding counts. To
retrieve reacted users, use <a href="#get-comment-reactions">Get
Comment Reactions</a>. Only present when comment reactions are enabled.</td>
</tr>
<tr>
<td>collapsed</td>
<td>boolean</td>
<td><p><code>true</code> if this comment is collapsed in the web UI, either
because one of its tags is listed in the <code>collapsed_comment_tags</code>
parameter or because it was authored by treeherder. <code>false</code>
otherwise.</p>
<p>Only present when comment tagging is enabled.</p></td>
</tr>
</tbody>
</table>

**Errors**

This method can throw all the same errors as [Get
Bug](bug.md#get-bug). In addition, it can also throw the following
errors:

- 110 (Comment Is Private) You specified the id of a private comment in the
  "comment_ids" argument, and you are not in the "insider group" that can see
  private comments.
- 111 (Invalid Comment ID) You specified an id in the "comment_ids" argument
  that is invalid--either you specified something that wasn't a number, or
  there is no comment with that id.

## Create Comments

This allows you to add a comment to a bug in Bugzilla.

**Request**

To create a comment on a current bug.

``` text
POST /rest/bug/(id)/comment
```

``` js
{
  "comment" : "This is an additional comment",
  "is_private" : false,
  "is_markdown" : true,
  "comment_tags" : ["triaged"]
}
```

| name | type | description |
|----|----|----|
| **id** | int | The ID or alias of the bug to append a comment to. |
| **comment** | string | The comment to append to the bug. If this is empty or all whitespace, an error will be thrown saying that you did not set the `comment` parameter. |
| is_private | boolean | If set to true, the comment is private, otherwise it is assumed to be public. |
| is_markdown | boolean | If true, marks the comment for Markdown rendering. Rendering also requires the system `use_markdown` setting to be enabled. Defaults to the system `use_markdown` setting. |
| comment_tags | array | Tags to add to the new comment. Tags are added only if the user has permission to tag comments. |
| work_time | double | Adds this many hours to the "Hours Worked" on the bug. Changing this value requires time-tracking permission; unauthorized changes cause an error. |

**Response**

``` js
{
  "id" : 789
}
```

| name | type | description                      |
|------|------|----------------------------------|
| id   | int  | ID of the newly-created comment. |

**Errors**

- 54 (Hours Worked Too Large) You specified a "work_time" larger than the
  maximum allowed value of "99999.99".
- 100 (Invalid Bug Alias) If you specified an alias and there is no bug with
  that alias.
- 101 (Invalid Bug ID) The id you specified doesn't exist in the database.
- 109 (Bug Edit Denied) You did not have the necessary rights to edit the bug.
- 113 (Can't Make Private Comments) You tried to add a private comment, but
  don't have the necessary rights.
- 114 (Comment Too Long) You tried to add a comment longer than the maximum
  allowed length (65,535 characters).
- 115 (Illegal Change) You tried to change `work_time` without the necessary
  permission.
- 126 (Invalid Comment Tag) A tag in `comment_tags` was not valid (e.g.
  contains invalid characters).
- 127 (Comment Tag Too Long) A tag in `comment_tags` is longer than the maximum
  length.
- 128 (Comment Tag Too Short) A tag in `comment_tags` is shorter than the
  minimum length.

## Get Comment Reactions

Gets reactions left on a comment with reacted users’ details.

**Request**

To get the reactions attached to a comment:

``` text
GET /rest/bug/comment/(comment_id)/reactions
```

| name           | type | description                  |
|----------------|------|------------------------------|
| **comment_id** | int  | A single integer comment ID. |

**Response**

``` js
{
  "+1": [
    {
      "id": 2,
      "real_name": "Test User",
      "nick": "user",
      "name": "user@bugzilla.org",
      "email": "user@bugzilla.org"
    }
  ]
}
```

An object containing the comment's reactions, where the key is a reacted emoji
name, and the value is an array of reacted users, which are the same as user
objects returned by [Get Bug](bug.md#get-bug).

**Errors**

This method can throw all of the errors that [Get
Comments](#get-comments) throws, plus:

- 136 (Comment Reactions Disabled) Comment reactions are not enabled on this
  Bugzilla instance.

## Update Comment Reactions

Adds or removes reactions from a comment.

**Request**

To update the reactions attached to a comment:

``` text
PUT /rest/bug/comment/(comment_id)/reactions
```

Example:

``` js
{
  "add" : ["+1", "smile"]
}
```

| name           | type  | description                               |
|----------------|-------|-------------------------------------------|
| **comment_id** | int   | The ID of the comment to update.          |
| add            | array | The reactions to attach to the comment.   |
| remove         | array | The reactions to detach from the comment. |

Supported reactions: `+1`, `-1`, `tada`, `smile`, `sad` and `heart`.

**Response**

Same as [Get Comment Reactions](#get-comment-reactions).

**Errors**

This method can throw all of the errors that [Get
Comments](#get-comments) throws, plus:

- 136 (Comment Reactions Disabled) Comment reactions are not enabled on this
  Bugzilla instance.
- 137 (Invalid Comment Reaction) The comment reaction provided is not
  supported.
- 138 (Comment Reactions Closed) The bug has been closed for too long to allow
  comment reaction changes.
- 139 (Comment Reactions Restricted) You are not allowed to react to comments
  on this bug.

## Search Comment Tags

Searches for tags which contain the provided substring.

You must be logged in and have permission to tag comments.

**Request**

To search for comment tags:

``` text
GET /rest/bug/comment/tags/(query)
```

Example:

``` text
GET /rest/bug/comment/tags/spa
```

| name | type | description |
|----|----|----|
| **query** | string | Only tags containing this substring will be returned. |
| limit | int | If provided will return no more than `limit` tags. Defaults to `7`. |

**Response**

``` js
[
  "spam"
]
```

An array of matching tags.

**Errors**

This method can throw all of the errors that [Get Bug](bug.md#get-bug)
throws, plus:

- 125 (Comment Tagging Disabled) Comment tagging support is not available or
  enabled.

## Update Comment Tags

Adds or removes tags from a comment.

You must be logged in and have permission to tag comments.

**Request**

To update the tags attached to a comment:

``` text
PUT /rest/bug/comment/(comment_id)/tags
```

Example:

``` js
{
  "add" : ["spam", "bad"]
}
```

| name           | type  | description                          |
|----------------|-------|--------------------------------------|
| **comment_id** | int   | The ID of the comment to update.     |
| add            | array | The tags to attach to the comment.   |
| remove         | array | The tags to detach from the comment. |

**Response**

``` js
[
  "bad",
  "spam"
]
```

An array of strings containing the comment's updated tags.

**Errors**

This method can throw all of the errors that [Get Bug](bug.md#get-bug)
throws, plus:

- 125 (Comment Tagging Disabled) Comment tagging support is not available or
  enabled.
- 110 (Comment Is Private) You tried to tag a private comment without
  permission to view it.
- 126 (Invalid Comment Tag) The comment tag provided was not valid (e.g.
  contains invalid characters).
- 127 (Comment Tag Too Long) The comment tag provided is longer than the
  maximum length.
- 128 (Comment Tag Too Short) The comment tag provided is shorter than the
  minimum length.

## Render Comment

Returns the HTML rendering of the provided comment text.

**Request**

``` text
POST /rest/bug/comment/render
```

Example:

``` js
{
  "id" : 2345,
  "text" : "This issue has been fixed in bug 1234."
}
```

| name     | type   | description                                      |
|----------|--------|--------------------------------------------------|
| **text** | string | Comment text to render.                          |
| id       | int    | The ID of the bug to render the comment against. |

**Response**

``` js
{
  "html" : "This issue has been fixed in <a class=\"bz_bug_link bz_status_RESOLVED bz_closed\" title=\"RESOLVED FIXED - some issue that was fixed\" href=\"show_bug.cgi?id=1234\">bug 1234</a>."
}
```

| name | type   | description                         |
|------|--------|-------------------------------------|
| html | string | Text containing the HTML rendering. |

**Errors**

This method can throw all of the errors that [Get Bug](bug.md#get-bug)
throws.
