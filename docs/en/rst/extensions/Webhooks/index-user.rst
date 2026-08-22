.. _webhooks:

Webhooks
========

A webhook is a callback triggered by one or more events. When an event occurs,
Bugzilla sends an HTTP POST request to a configured URL.

Bugzilla webhooks can be triggered when a bug is created or changed. The
webhook payload contains information about the bug and the event so another
web application can respond to it.

For example, a webhook could:

* Update a copy of a Bugzilla bug in another system, such as Jira.
* Send a message to a chat service, such as Matrix or Slack.

Creating a webhook
------------------

The :guilabel:`Webhooks` preferences tab is available only when webhooks are
enabled and your account belongs to the group configured by the Bugzilla
administrator.

#. Log in to your Bugzilla account.
#. Go to :guilabel:`Preferences`, then select the :guilabel:`Webhooks` tab.
#. Fill in the webhook parameters:

   Name
      A descriptive name for the webhook, such as "Jira webhook for new and
      updated bugs in Core::Graphics".

   URL
      The URL that will receive and process the webhook.

   Events
      The bug events that will trigger the webhook:

      * When a new bug is created.
      * When an existing bug is modified.
      * When a new attachment is created.
      * When an existing attachment is modified.
      * When a new comment is created.

   Filters
      Bug properties that determine which bugs the webhook receives:

      Product
         The product containing the bugs you want to receive. The
         :guilabel:`Any` option is available only to members of a group
         configured by the Bugzilla administrator.

      Component
         The component containing the bugs you want to receive. Select
         :guilabel:`Any` to receive bugs from every component in the product.

   API keys
      If the endpoint requires authentication, you can provide a header and
      API key for the endpoint. For example, for the following header::

         Authorization: Token zQ5TSBzq7tTZMtKYq9K1ZqJMjifKx3cPL7pIGk9Q

      enter ``Authorization`` as the API Key Header and
      ``Token zQ5TSBzq7tTZMtKYq9K1ZqJMjifKx3cPL7pIGk9Q`` as the API Key Value.

      Bugzilla adds the header only when both values are set. If either value
      is empty, Bugzilla sends the webhook without the authentication header.

#. Click :guilabel:`Add`.

Registered webhooks appear on the same preferences tab. To delete one or more
webhooks, select them in the :guilabel:`Your webhooks` table and click
:guilabel:`Remove selected`.

You can also enable or disable each webhook from this table. If a webhook has
queued messages, the error count links to a page where you can inspect the
queue and delete individual messages.

Delivered webhooks
------------------

When a webhook is triggered, Bugzilla sends an HTTP POST request containing a
JSON payload. The payload includes the webhook ID, webhook name, event
information, and information about the bug that matched the event and filters.

Bugzilla ordinarily sends a webhook only if its owner can see the affected bug
and its product. A public-to-private transition can also be sent using the
bug's previous public state so the receiving system can remove information
that is no longer public. When a bug becomes public again, Bugzilla sends an
``is_private`` modification event containing its current public data. When a
payload's bug is private, its details are reduced to the bug ID and privacy
status. Private comments and attachments are sent only when the webhook owner
is authorized to see them; their payloads are also reduced to IDs and privacy
status. The receiving system must use the REST API with suitable credentials
to retrieve additional details.

Webhooks are delivered in the same order as the events that triggered them.
Bug creation and modification events each produce a separate request. The
``changes`` field is sent only for modification events and contains every
change made to the bug.

The payloads below are representative. Bug objects can also contain custom
fields configured for their product and component.

Public bug request
~~~~~~~~~~~~~~~~~~

.. code-block:: json

   {
     "bug": {
       "alias": "",
       "assigned_to": "nobody@mozilla.org",
       "assigned_to_detail": {
         "id": 1,
         "login": "nobody@mozilla.org",
         "real_name": "Nobody; OK to take it and work on it"
       },
       "classification": "Client Software",
       "component": "Sync",
       "creation_time": "2020-10-16T06:24:06",
       "creator": "nobody@mozilla.org",
       "creator_detail": {
         "id": 1,
         "login": "nobody@mozilla.org",
         "real_name": "Nobody; OK to take it and work on it"
       },
       "flags": [],
       "id": 1629704,
       "is_private": false,
       "keywords": [],
       "last_change_time": "2020-10-16T06:26:21",
       "operating_system": "Unspecified",
       "platform": "Unspecified",
       "priority": "P1",
       "product": "Firefox",
       "qa_contact": "nobody@mozilla.org",
       "qa_contact_detail": {
         "id": 1,
         "login": "nobody@mozilla.org",
         "real_name": "Nobody; OK to take it and work on it"
       },
       "resolution": "",
       "see_also": [],
       "severity": "--",
       "status": "NEW",
       "summary": "Webhook Test - Disregard",
       "target_milestone": "---",
       "type": "defect",
       "url": "",
       "version": "unspecified",
       "whiteboard": ""
     },
     "event": {
       "action": "modify",
       "routing_key": "bug.modify:priority",
       "target": "bug",
       "time": "2020-07-24T20:11:22",
       "user": {
         "id": 1,
         "login": "nobody@mozilla.org",
         "real_name": "Nobody; OK to take it and work on it"
       },
       "changes": [
         {
           "field": "priority",
           "removed": "P3",
           "added": "P1"
         }
       ]
     },
     "webhook_id": 23,
     "webhook_name": "test-bug"
   }

Private bug request
~~~~~~~~~~~~~~~~~~~

.. code-block:: json

   {
     "bug": {
       "id": 2,
       "is_private": true
     },
     "event": {
       "action": "modify",
       "routing_key": "bug.modify:priority",
       "target": "bug",
       "time": "2020-07-24T20:11:22",
       "user": {
         "id": 1,
         "login": "nobody@mozilla.org",
         "real_name": "Nobody; OK to take it and work on it"
       }
     },
     "webhook_id": 23,
     "webhook_name": "test-bug"
   }

Response
~~~~~~~~

Bugzilla treats any HTTP 2xx response as successful.

New comment
~~~~~~~~~~~

.. code-block:: json

   {
     "bug": {
       "alias": "",
       "assigned_to": "nobody@mozilla.org",
       "assigned_to_detail": {
         "id": 1,
         "login": "nobody@mozilla.org",
         "real_name": "Nobody; OK to take it and work on it"
       },
       "classification": "Client Software",
       "comment": {
         "body": "another test comment",
         "creation_time": "2020-10-16T06:28:41",
         "id": 14748073,
         "is_private": false,
         "number": 2
       },
       "component": "Sync",
       "creation_time": "2020-10-16T06:24:06",
       "creator": "nobody@mozilla.org",
       "creator_detail": {
         "id": 1,
         "login": "nobody@mozilla.org",
         "real_name": "Nobody; OK to take it and work on it"
       },
       "flags": [],
       "id": 1629704,
       "is_private": false,
       "keywords": [],
       "last_change_time": "2020-10-16T06:26:21",
       "operating_system": "Unspecified",
       "platform": "Unspecified",
       "priority": "",
       "product": "Firefox",
       "qa_contact": "",
       "resolution": "",
       "see_also": [],
       "severity": "--",
       "status": "NEW",
       "summary": "Webhook Test - Disregard",
       "target_milestone": "---",
       "type": "defect",
       "url": "",
       "version": "unspecified",
       "whiteboard": ""
     },
     "event": {
       "action": "create",
       "routing_key": "comment.create",
       "target": "comment",
       "time": "2020-10-16T06:28:41",
       "user": {
         "id": 1,
         "login": "nobody@mozilla.org",
         "real_name": "Nobody; OK to take it and work on it"
       }
     },
     "webhook_id": 23,
     "webhook_name": "test-comment"
   }

New attachment
~~~~~~~~~~~~~~

.. code-block:: json

   {
     "bug": {
       "alias": "",
       "assigned_to": "nobody@mozilla.org",
       "assigned_to_detail": {
         "id": 1,
         "login": "nobody@mozilla.org",
         "real_name": "Nobody; OK to take it and work on it"
       },
       "attachment": {
         "content_type": "text/plain",
         "creation_time": "2020-10-16T07:08:12",
         "description": "test attachment",
         "file_name": "file_1629704.txt",
         "flags": [],
         "id": 9180115,
         "is_obsolete": false,
         "is_patch": false,
         "is_private": false,
         "last_change_time": "2020-10-16T07:08:12"
       },
       "classification": "Client Software",
       "component": "Sync",
       "creation_time": "2020-10-16T06:24:06",
       "creator": "nobody@mozilla.org",
       "creator_detail": {
         "id": 1,
         "login": "nobody@mozilla.org",
         "real_name": "Nobody; OK to take it and work on it"
       },
       "flags": [],
       "id": 1629704,
       "is_private": false,
       "keywords": [],
       "last_change_time": "2020-10-16T06:26:21",
       "operating_system": "Unspecified",
       "platform": "Unspecified",
       "priority": "",
       "product": "Firefox",
       "qa_contact": "",
       "resolution": "",
       "see_also": [],
       "severity": "--",
       "status": "NEW",
       "summary": "Webhook Test - Disregard",
       "target_milestone": "---",
       "type": "defect",
       "url": "",
       "version": "unspecified",
       "whiteboard": ""
     },
     "event": {
       "action": "create",
       "routing_key": "attachment.create",
       "target": "attachment",
       "time": "2020-10-16T07:08:12",
       "user": {
         "id": 1,
         "login": "nobody@mozilla.org",
         "real_name": "Nobody; OK to take it and work on it"
       }
     },
     "webhook_id": 23,
     "webhook_name": "test-attachment"
   }

Errors and retries
------------------

If an endpoint does not return an HTTP 2xx response, or if delivery fails for
another reason, Bugzilla puts the message in the webhook's queue. After each
failed queued attempt, it schedules the next attempt using increasing delays:
5 seconds after the first failure, then 25, 125, and 625 seconds. After later
failures, the delay is 15 minutes. The delivery daemon polls every 30 seconds,
so an attempt can occur later than its scheduled time.

If a message remains stuck, later messages for that webhook are stored in a
queue in the order they were triggered. Bugzilla delivers them in that order
after the first message in the queue succeeds.

An administrator can configure an error limit. When a webhook reaches that
limit, Bugzilla disables it and emails its owner. The owner can re-enable it
from the :guilabel:`Webhooks` preferences tab after fixing the problem.
