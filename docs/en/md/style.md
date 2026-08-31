# Writing Bugzilla Documentation

The Bugzilla documentation is written in [GitHub-flavored
Markdown](https://github.github.com/gfm/) and lives in the `docs/en/md`
directory of the BMO source tree. Bugzilla renders it directly at
`/docs/en/md/`, so a page is published simply by landing it in the
repository — there is no separate build step.

Bugzilla's particular documentation conventions are as follows:

## Headings and Anchors

Every page starts with a single `#` heading, which is also used as the
page title in the viewer. Use `##` for sections within a page, and deeper
levels (`###`, `####`) for subsections; try not to go deeper than the
fourth level.

Headings automatically get GitHub-style anchors: the heading text is
lowercased, spaces become hyphens, and punctuation is dropped. So link to
sections like this: `[Third Level Heading](#third-level-heading)`, or from
another page: `[Searching](using/finding.md#searching-on-relative-dates)`.
If you need an anchor that must survive a heading being reworded, place an
explicit `<a id="unique-anchor-name"></a>` element before the heading and
link to that instead.

## Links Between Pages

Always link to other documentation pages with relative paths that include
the `.md` extension, e.g. `[User Guide](../using/index.md)`. These links
work both in the in-app viewer and when reading the files on GitHub.
Images live in `docs/en/images/` and are referenced relatively as well,
e.g. `![description](../../images/example.png)`. Give every image a
meaningful description for screen readers.

## Block Types

Notes and warnings use GFM alert blockquotes:

> [!NOTE]
> This is just a note, for your information.

> [!WARNING]
> This is a warning of a potential serious problem you should be aware of.

Use both of the above block types sparingly. Consider putting the
information in the main text, omitting it, or (if long) placing it in a
subsidiary file.

Code blocks are fenced with triple backticks, with the language named so
it can be highlighted:

``` perl
# This is some Perl code
print "Hello";
```

We currently use `console`, `perl`, and `sql`. Leave the language off for
plain text.

Use two-space indentation for continuation lines in bulleted lists, and
indent nested lists by two spaces.

## Inline Conventions

- A filename or a path to a filename:
  `/path/to/{variable-bit-of-path}/filename.ext`
- A command to type in the shell: `command --arguments`
- A parameter value: `DB`
- A group name: `editbugs`
- A bug field name: `Summary`
- Any string from the UI: **Administration**
- A specific BMO bug: [bug
  201069](https://bugzilla.mozilla.org/show_bug.cgi?id=201069)
