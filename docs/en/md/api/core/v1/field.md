# Bug Fields

The Bugzilla API for getting details about bug fields.

## Fields

Get information about valid bug fields, including the lists of legal values for
each field.

**Request**

To get information about all fields:

``` text
GET /rest/field/bug
```

To get information related to a single field:

``` text
GET /rest/field/bug/(id_or_name)
```

| name       | type  | description                                                |
|------------|-------|------------------------------------------------------------|
| id_or_name | mixed | An integer field ID or string representing the field name. |

**Response**

``` js
{
  "fields": [
    {
      "display_name": "Priority",
      "name": "priority",
      "type": 2,
      "is_mandatory": false,
      "value_field": null,
      "values": [
        {
          "sortkey": 100,
          "sort_key": 100,
          "visibility_values": [],
          "name": "P1"
        },
        {
          "sort_key": 200,
          "name": "P2",
          "visibility_values": [],
          "sortkey": 200
        },
        {
          "sort_key": 300,
          "visibility_values": [],
          "name": "P3",
          "sortkey": 300
        },
        {
          "sort_key": 400,
          "name": "P4",
          "visibility_values": [],
          "sortkey": 400
        },
        {
          "name": "P5",
          "visibility_values": [],
          "sort_key": 500,
          "sortkey": 500
        }
      ],
      "visibility_values": [],
      "visibility_field": null,
      "is_on_bug_entry": false,
      "is_custom": false,
      "id": 13
    }
  ]
}
```

`field` (array) Field objects each containing the following items:

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
<td>An integer ID uniquely identifying this field in this installation
only.</td>
</tr>
<tr>
<td>type</td>
<td>int</td>
<td><p>The number of the fieldtype. The following values are defined:</p>
<ul>
<li><code>0</code> Field type unknown</li>
<li><code>1</code> Single-line string field</li>
<li><code>2</code> Single value field</li>
<li><code>3</code> Multiple value field</li>
<li><code>4</code> Multi-line text value</li>
<li><code>5</code> Date field with time</li>
<li><code>6</code> Bug ID field</li>
<li><code>7</code> See Also field</li>
<li><code>8</code> Keywords field</li>
<li><code>9</code> Date field</li>
<li><code>10</code> Integer field</li>
</ul></td>
</tr>
<tr>
<td>is_custom</td>
<td>boolean</td>
<td><code>true</code> when this is a custom field, <code>false</code>
otherwise.</td>
</tr>
<tr>
<td>name</td>
<td>string</td>
<td>The internal name of this field. This is a unique identifier for this
field. If this is not a custom field, then this name will be the same across
all Bugzilla installations.</td>
</tr>
<tr>
<td>display_name</td>
<td>string</td>
<td>The name of the field, as it is shown in the user interface.</td>
</tr>
<tr>
<td>is_mandatory</td>
<td>boolean</td>
<td><code>true</code> if the field must have a value when filing new bugs.
Also, mandatory fields cannot have their value cleared when updating bugs.</td>
</tr>
<tr>
<td>is_on_bug_entry</td>
<td>boolean</td>
<td>For custom fields, this is <code>true</code> if the field is shown when you
enter a new bug. For standard fields, this is currently always
<code>false</code>, even if the field shows up when entering a bug. (To know
whether or not a standard field is valid on bug entry, see <a
href="bug.md#create-bug">Create Bug</a>.</td>
</tr>
<tr>
<td>visibility_field</td>
<td>string</td>
<td>The name of a field that controls the visibility of this field in the user
interface. This field only appears in the user interface when the named field
is equal to one of the values is <code>visibility_values</code>. Can be
null.</td>
</tr>
<tr>
<td>visibility_values</td>
<td>array</td>
<td>This field is only shown when <code>visibility_field</code> matches one of
these string values. When <code>visibility_field</code> is null, then this is
an empty array.</td>
</tr>
<tr>
<td>value_field</td>
<td>string</td>
<td>The name of the field that controls whether or not particular values of the
field are shown in the user interface. Can be null.</td>
</tr>
<tr>
<td>values</td>
<td>array</td>
<td>Objects representing the legal values for select-type (drop-down and
multiple-selection) fields. This is also populated for the
<code>component</code>, <code>version</code>, <code>target_milestone</code>,
and <code>keywords</code> fields, but not for the <code>product</code> field
(you must use <code>get_accessible_products</code> for that). For fields that
aren't select-type fields, this will simply be an empty array. Each object
contains the items described in the Value object below.</td>
</tr>
</tbody>
</table>

Value object:

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
<td>name</td>
<td>string</td>
<td>The actual value--this is what you would specify for this field in
<code>create</code>, etc.</td>
</tr>
<tr>
<td>sort_key</td>
<td>int</td>
<td>Values, when displayed in a list, are sorted first by this integer and then
secondly by their name.</td>
</tr>
<tr>
<td>visibility_values</td>
<td>array</td>
<td>If <code>value_field</code> is defined for this field, then this value is
only shown if the <code>value_field</code> is set to one of the values listed
in this array. Note that for per-product fields, <code>value_field</code> is
set to <code>product</code> and <code>visibility_values</code> will reflect
which product(s) this value appears in.</td>
</tr>
<tr>
<td>is_active</td>
<td>boolean</td>
<td>This value is defined only for certain product-specific fields such as
version, target_milestone or component. When true, the value is active;
otherwise the value is not active.</td>
</tr>
<tr>
<td>description</td>
<td>string</td>
<td>The description of the value. This item is only included for the
<code>keywords</code> field.</td>
</tr>
<tr>
<td>is_open</td>
<td>boolean</td>
<td>For <code>bug_status</code> values, determines whether this status
specifies that the bug is "open" (<code>true</code>) or "closed"
(<code>false</code>). This item is only included for the
<code>bug_status</code> field.</td>
</tr>
<tr>
<td>can_change_to</td>
<td>array</td>
<td><p>For <code>bug_status</code> values, this is an array of objects that
determine which statuses you can transition to from this status. (This item is
only included for the <code>bug_status</code> field.)</p>
<p>Each object contains the following items:</p>
<ul>
<li>name: (string) The name of the new status</li>
<li>comment_required: (boolean) <code>true</code> if a comment is required when
you change a bug into this status using this transition.</li>
</ul></td>
</tr>
</tbody>
</table>

**Errors**

- 51 (Invalid Field Name or Id) You specified an invalid field name or id.

## Legal Values

**DEPRECATED** Use ''Fields'' instead.

Tells you what values are allowed for a particular field.

**Request**

To get information on the values for a field based on field name:

``` text
GET /rest/field/bug/(field)/values
```

To get information based on field name and a specific product:

``` text
GET /rest/field/bug/(field)/(product_id)/values
```

| name | type | description |
|----|----|----|
| field | string | The name of the field you want information about. This should be the same as the name you would use in [Create Bug](bug.md#create-bug), below. |
| product_id | int | If you're picking a product-specific field, you have to specify the ID of the product you want the values for. |

**Response**

``` js
{
  "values": [
    "P1",
    "P2",
    "P3",
    "P4",
    "P5"
  ]
}
```

| name | type | description |
|----|----|----|
| values | array | The legal values for this field. The values will be sorted as they normally would be in Bugzilla. |

**Errors**

- 106 (Invalid Product) You were required to specify a product, and either you
  didn't, or you specified an invalid product (or a product that you can't
  access).
- 108 (Invalid Field Name) You specified a field that doesn't exist or isn't a
  drop-down field.
