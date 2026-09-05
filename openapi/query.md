Documentation:
```rst
.. _rest_add_attachment:

Create Attachment
-----------------

This allows you to add an attachment to a bug in Bugzilla.

**Request**

To create attachment on a current bug:

.. code-block:: text

   POST /rest/bug/(bug_id)/attachment

.. code-block:: js

   {
     "ids" : [ 35 ],
     "is_patch" : true,
     "comment" : "This is a new attachment comment",
     "summary" : "Test Attachment",
     "content_type" : "text/plain",
     "data" : "(Some base64 encoded content)",
     "file_name" : "test_attachment.patch",
     "obsoletes" : [],
     "is_private" : false,
     "flags" : [
       {
         "name" : "review",
         "status" : "?",
         "requestee" : "user@bugzilla.org",
         "new" : true
       }
     ]
   }


The params to include in the POST body, as well as the returned
data format, are the same as below. The ``bug_id`` param will be
overridden as it it pulled from the URL path.

================  =======  ======================================================
name              type     description
================  =======  ======================================================
**ids**           array    The IDs or aliases of bugs that you want to add this
                           attachment to. The same attachment and comment will be
                           added to all these bugs.
**data**          base64   The content of the attachment. You must encode it in
                           base64 using an appropriate client library such as
                           ``MIME::Base64`` for Perl.
**file_name**     string   The "file name" that will be displayed in the UI for
                           this attachment and also downloaded copies will be
                           given.
**summary**       string   A short string describing the attachment.
**content_type**  string   The MIME type of the attachment, like ``text/plain``
                           or ``image/png``.
comment           string   A comment to add along with this attachment.
is_patch          boolean  ``true`` if Bugzilla should treat this attachment as a
                           patch. If you specify this, you do not need to specify
                           a ``content_type``. The ``content_type`` of the
                           attachment will be forced to ``text/plain``. Defaults
                           to ``false`` if not specified.
is_private        boolean  ``true`` if the attachment should be private
                           (restricted to the "insidergroup"), ``false`` if the
                           attachment should be public. Defaults to ``false`` if
                           not specified.
flags             array    Flags objects to add to the attachment. The object
                           format is described in the Flag object below.
bug_flags         array    Flag objects to add to the attachment's bug. See the
                           ``flags`` param for :ref:`rest_create_bug` for the
                           object format.
================  =======  ======================================================

Flag object:

To create a flag, at least the ``status`` and the ``type_id`` or ``name`` must
be provided. An optional requestee can be passed if the flag type is requestable
to a specific user.

=========  ======  ==============================================================
name       type    description
=========  ======  ==============================================================
name       string  The name of the flag type.
type_id    int     The internal flag type ID.
status     string  The flags new status (i.e. "?", "+", "-" or "X" to clear a
                   flag).
requestee  string  The login of the requestee if the flag type is requestable to
                   a specific user.
=========  ======  ==============================================================

**Response**

.. code-block:: js

   {
     "ids" : [
       "2797"
     ]
   }

====  =====  =========================
name  type   description
====  =====  =========================
ids   array  Attachment IDs created.
====  =====  =========================

**Errors**

This method can throw all the same errors as :ref:`rest_single_bug`, plus:

* 129 (Flag Status Invalid)
  The flag status is invalid.
* 130 (Flag Modification Denied)
  You tried to request, grant, or deny a flag but only a user with the required
  permissions may make the change.
* 131 (Flag not Requestable from Specific Person)
  You can't ask a specific person for the flag.
* 133 (Flag Type not Unique)
  The flag type specified matches several flag types. You must specify
  the type id value to update or add a flag.
* 134 (Inactive Flag Type)
  The flag type is inactive and cannot be used to create new flags.
* 140 (Markdown Disabled)
  You tried to set the "is_markdown" flag of the comment to true but the Markdown feature is not enabled.
* 600 (Attachment Too Large)
  You tried to attach a file that was larger than Bugzilla will accept.
* 601 (Invalid MIME Type)
  You specified a "content_type" argument that was blank, not a valid
  MIME type, or not a MIME type that Bugzilla accepts for attachments.
* 603 (File Name Not Specified)
  You did not specify a valid for the "file_name" argument.
* 604 (Summary Required)
  You did not specify a value for the "summary" argument.
* 606 (Empty Data)
  You set the "data" field to an empty string.
```

OpenAPI:
```yaml
put:
  summary: Update attachment metadata
  description: This allows you to update attachment metadata in Bugzilla.
  operationId: update_attachment
  parameters:
    - name: attachment_id
      in: path
      description: Integer attachment ID.
      required: true
      schema:
        type: integer
  requestBody:
    required: true
    content:
      application/json:
        schema:
          type: object
          properties:
            ids:
              description: The IDs of the attachments you want to update.
              type: array
              items:
                type: string
            file_name:
              description: >-
                The "file name" that will be displayed in the UI for this
                attachment.
              type: string
            summary:
              description: A short string describing the attachment.
              type: string
            comment:
              description: An optional comment to add to the attachment's bug.
              type: string
            content_type:
              description: >-
                The MIME type of the attachment, like ``text/plain`` or
                ``image/png``.
              type: string
            is_patch:
              description: >-
                ``true`` if Bugzilla should treat this attachment as a patch. If
                you specify this, you do not need to specify a ``content_type``.
                The ``content_type`` of the attachment will be forced to
                ``text/plain``.
              type: boolean
            is_private:
              description: >-
                `true` if the attachment should be private, `false` if the
                attachment should be public.
              type: boolean
            is_obsolete:
              description: '`true` if the attachment is obsolete, `false` otherwise.'
              type: boolean
            flags:
              description: An array of Flag objects with changes to the flags.
              type: array
              items:
                $ref: ../components/schemas/FlagUpdate.yaml
            bug_flags:
              description: >-
                An optional array of Flag objects with changes to the flags of
                the attachment's bug.
              type: array
              items:
                $ref: ../components/schemas/FlagUpdate.yaml
          required:
            - ids
        example:
          ids:
            - 2796
          summary: Test XML file
          comment: Changed this from a patch to a XML file
          content_type: text/xml
          is_patch: 0
  responses:
    '200':
      description: Attachment metadata updated.
      content:
        application/json:
          schema:
            type: object
            properties:
              attachments:
                type: array
                items:
                  type: object
                  properties:
                    id:
                      description: The ID of the attachment that was updated.
                      type: integer
                    last_change_time:
                      description: >-
                        The exact time that this update was done at, for this
                        attachment. If no update was done (that is, no fields
                        had their values changed and no comment was added) then
                        this will instead be the last time the attachment was
                        updated.
                      type: string
                      format: date-time
                    changes:
                      description: >-
                        The changes that were actually done on this attachment.
                        The keys are the names of the fields that were changed,
                        and the values are an object with two items:
                      type: object
                      additionalProperties:
                        type: object
                        properties:
                          added:
                            description: >-
                              The values that were added to this field. Possibly
                              a comma-and-space-separated list if multiple
                              values were added.
                            type: string
                          removed:
                            description: The values that were removed from this field.
                            type: string
          example:
            attachments:
              - id: 2796
                last_change_time: '2014-09-29T14:41:53Z'
                changes:
                  content_type:
                    added: text/xml
                    removed: text/plain
                  is_patch:
                    added: '0'
                    removed: '1'
                  summary:
                    added: Test XML file
                    removed: test patch
    default:
      description: >
        This method can throw all the same errors as [Get
        Bug](#tag/Bugs/paths/~1bug~1{id_or_alias}/get), plus:


        * 129 (Flag Status Invalid)
          The flag status is invalid.
        * 130 (Flag Modification Denied)
          You tried to request, grant, or deny a flag but only a user with the required
          permissions may make the change.
        * 131 (Flag not Requestable from Specific Person)
          You can't ask a specific person for the flag.
        * 132 (Flag not Unique)
          The flag specified has been set multiple times. You must specify the id
          value to update the flag.
        * 133 (Flag Type not Unique)
          The flag type specified matches several flag types. You must specify
          the type id value to update or add a flag.
        * 134 (Inactive Flag Type)
          The flag type is inactive and cannot be used to create new flags.
        * 140 (Markdown Disabled)
          You tried to set the "is_markdown" flag of the "comment" to true but Markdown feature is
          not enabled.
        * 601 (Invalid MIME Type)
          You specified a "content_type" argument that was blank, not a valid
          MIME type, or not a MIME type that Bugzilla accepts for attachments.
        * 603 (File Name Not Specified)
          You did not specify a valid for the "file_name" argument.
        * 604 (Summary Required)
          You did not specify a value for the "summary" argument.
      content:
        application/json:
          schema:
            $ref: ../components/schemas/Error.yaml
  tags:
    - Attachments
```

Documentation:
```rst
.. _rest-bug-user-last-visit-update:

Update Last Visited
-------------------

Update the last-visited time for the specified bug and current user.

**Request**

To update the time for a single bug id:

.. code-block:: text

   POST /rest/bug_user_last_visit/(id)

To update one or more bug ids at once:

.. code-block:: text

   POST /rest/bug_user_last_visit

.. code-block:: js

   {
     "ids" : [35,36,37]
   }

=======  =====  ==============================
name     type   description
=======  =====  ==============================
**id**   int    An integer bug id.
**ids**  array  One or more bug ids to update.
=======  =====  ==============================

**Response**

.. code-block:: js

   [
     {
       "id" : 100,
       "last_visit_ts" : "2014-10-16T17:38:24Z"
     }
   ]

An array of objects containing the items:

=============  ========  ============================================
name           type      description
=============  ========  ============================================
id             int       The bug id.
last_visit_ts  datetime  The timestamp the user last visited the bug.
=============  ========  ============================================

**Errors**

* 1300 (User Not Involved with Bug)
  The caller's account is not involved with the bug id provided.
```

OpenAPI:
