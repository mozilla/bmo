# Customization FAQ

How do I...

...add a new field on a bug? Use [Custom Fields](../administering/custom-fields.md) or, if
you just want new form fields on bug entry but don't need Bugzilla to track the
field separately thereafter, you can use a [custom bug entry
form](templates.md#custom-bug-entry).

...change the name of a built-in bug field? [Edit](templates.md) the
relevant value in the template
`template/en/default/global/field-descs.none.tmpl`.

...use a word other than 'bug' to describe bugs? [Edit or
override](templates.md) the appropriate values in the template
`template/en/default/global/variables.none.tmpl`.

...call the system something other than 'Bugzilla'? [Edit or
override](templates.md) the appropriate value in the template
`template/en/default/global/variables.none.tmpl`.

...alter who can change what field when? See [Altering Who Can Change
What](extensions.md#altering-who-can-change-what).
