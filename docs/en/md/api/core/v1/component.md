# Components

This part of the Bugzilla API looks at individual components and also allows
updating their information.

## Get Component

This allows you to retrieve information about a specific component.

**Request**

To get information about the General component under the Firefox product:

``` text
GET /rest/component/Firefox/General
```

To get information about a component where the product name contains a slash
(/) character. Named parameters must be used instead of path based parameters.

``` text
GET /rest/component?product=Firefox%20%2F%20Bugs&component=General
```

**Response**

``` js
{
  "default_assignee": "nobody@mozilla.org",
  "default_bug_type": "--",
  "default_qa_contact": "",
  "description": "For bugs in Firefox which do not fit into other more specific Firefox components",
  "id": 2,
  "is_active": true,
  "name": "General",
  "team_name": "Mozilla",
  "triage_owner": "admin@mozilla.bugs"
}
```

<a id="rest_component_object"></a>

Component Object

| name | type | description |
|----|----|----|
| id | int | An integer ID uniquely identifying the component in this installation only. |
| name | string | The name of the component. |
| description | string | A description of the component, which may contain HTML. |
| is_active | boolean | A boolean indicating if the component is active. |
| default_bug_type | string | The default type for bugs filed under this component. |
| default_assignee | string | The login of the default assignee for the component. |
| default_qa_contact | string | The login of the default qa contact for the component. |
| triage_owner | string | The login of the default triage owner for the component. |
| team_name | string | The team name the component belongs to. |
| bug_description_template | string | The string included in the comment field of a new bug when the component is selected. |

## Create Component

This allows you to create a new component under a specific product in Bugzilla.

**Request**

To create a new component called `TestComponent` under the `Firefox` product:

``` text
{
  "name" : "TestComponent",
  "description" : "This is a new test component",
  "default_assignee" : "admin@mozilla.bugs",
  "team_name" : "Mozilla"
}
```

| name | type | description |
|----|----|----|
| name | string | The name of the component. |
| description | string | A description of the component, which may contain HTML. |
| default_bug_type | string | The default type for bugs filed under this component. If empty, then product's default bug type is used. (optional). |
| default_assignee | string | The login of the default assignee for the component. |
| default_qa_contact | string | The login of the default qa contact for the component (optional). |
| triage_owner | string | The login of the triage owner for the component (optional). |
| team_name | string | The team name the component belongs to. |
| bug_description_template | string | The string included in the comment field of a new bug when the component is selected (optional). |

**Response**

``` js
{
  "default_assignee": "admin@mozilla.bugs",
  "default_bug_type": "--",
  "default_qa_contact": "",
  "description": "This is a new test component",
  "id": 2,
  "is_active": true,
  "name": "TestComponent",
  "team_name": "Mozilla",
  "triage_owner": ""
}
```

A component object [rest_component_object](#rest_component_object) is
returned.

## Update Component

This allows you to update an existing component in Bugzilla.

**Request**

``` text
PUT /rest/component/Firefox/General
```

To update information about a component where the product name contains a slash
(/) character. Named parameters must be used instead of path based parameters.

``` text
PUT /rest/component?product=Firefox%20%2F%20Bugs&component=General
```

The body of the request should look similar to below.

``` js
{
  "default_assignee" : "admin@mozilla.bugs",
  "triage_owner" : "nobody@mozilla.org"
}
```

| name | type | description |
|----|----|----|
| name | string | The name of this component. |
| description | string | A description for this component. Allows some simple HTML. |
| default_assignee | string | The login of the default assignee for the component. |
| default_qa_contact | string | The login of the default qa contact for the component. |
| default_bug_type | string | The default type for bugs filed under this component. If empty, then product's default bug type is used. |
| is_active | boolean | `true` if you want the component to be active. `false` if not. |
| triage_owner | string | The login of the triage owner for the component. |
| team_name | string | The team name the component belongs to. |
| bug_description_template | string | The string included in the comment field of a new bug when the component is selected. |

**Response**

``` js
{
  "default_assignee": "admin@mozilla.bugs",
  "default_bug_type": "--",
  "default_qa_contact": "",
  "description": "For bugs in Firefox which do not fit into other more specific Firefox components",
  "id": 2,
  "is_active": true,
  "name": "General",
  "team_name": "Mozilla",
  "triage_owner": "nobody@mozilla.org",
}
```

A component object [rest_component_object](#rest_component_object) is
returned.
