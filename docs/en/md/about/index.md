# About This Documentation

This is the documentation for version 4.2 of Bugzilla, a bug-tracking system
from Mozilla. Bugzilla is an enterprise-class piece of software that tracks
millions of bugs and issues for thousands of organizations around the world.

The most current version of this document can always be found on the [Bugzilla
website](https://www.bugzilla.org/docs/).

## Evaluating Bugzilla

If you want to try out Bugzilla to see if it meets your needs, you can do so on
[Mozilla’s Bugzilla (BMO) test server](https://bugzilla-dev.allizom.org/),
though it comes with various Mozilla-specific customizations. The easiest way
to explore the admin tools and more is [running a minimum local copy of
BMO](https://github.com/mozilla-bteam/bmo/blob/master/README.md) using Docker.
We are not offering any online vanilla test environment at this time.

The [Bugzilla FAQ](https://wiki.mozilla.org/Bugzilla:FAQ) may also be helpful,
as it answers a number of questions people sometimes have about whether
Bugzilla is for them.

## Getting More Help

If this document does not answer your questions, we run a [Mozilla
forum](https://www.mozilla.org/about/forums/#support-bugzilla) which can be
accessed as a newsgroup, mailing list, or over the web as a Google Group.
Please [search
it](https://groups.google.com/forum/#!forum/mozilla.support.bugzilla) first,
and then ask your question there.

If you need a guaranteed response, commercial support is
[available](https://www.bugzilla.org/support/consulting.html) for Bugzilla from
a number of people and organizations.

## Document Conventions

This document uses the following conventions:

> [!WARNING]
> This is a warning—something you should be aware of.

> [!NOTE]
> This is just a note, for your information.

A filename or a path to a filename is displayed like this:
`/path/to/filename.ext`

A command to type in the shell is displayed like this: `command --arguments`

A sample of code is illustrated like this:

    First Line of Code
    Second Line of Code
    ...

This documentation is maintained in [GitHub-flavored
Markdown](https://github.github.com/gfm/) in the `docs/en/md` directory of
the BMO source tree, and is served directly by Bugzilla itself. Please file
any bugs you find in the [Bugzilla
Documentation](https://bugzilla.mozilla.org/enter_bug.cgi?product=Bugzilla;component=Documentation)
component in Mozilla's installation of Bugzilla. If you also want to make a
patch, that would be wonderful. Changes are best submitted as pull requests
against the [BMO repository](https://github.com/mozilla-bteam/bmo). There is
a [Style Guide](../style.md) to help you write any new text and markup.

## License

Bugzilla is [free](http://www.gnu.org/philosophy/free-sw.html) and [open
source](http://opensource.org/osd) software, which means (among other things)
that you can download it, install it, and run it for any purpose whatsoever
without the need for license or payment. Isn't that refreshing?

Bugzilla's code is made available under the [Mozilla Public License
2.0](http://www.mozilla.org/MPL/2.0/) (MPL), specifically the variant which is
Incompatible with Secondary Licenses. However, again, if you only want to
install and run Bugzilla, you don't need to worry about that; it's only
relevant if you redistribute the code or any changes you make.

Bugzilla's documentation is made available under the [Creative Commons CC-BY-SA
International License 4.0](https://creativecommons.org/licenses/by-sa/4.0/), or
any later version.

## Credits

The people listed below have made significant contributions to the creation of
this documentation:

Andrew Pearson, Ben FrantzDale, Byron Jones, Dave Lawrence, Dave Miller, Dawn
Endico, Eric Hanson, Gervase Markham, Jacob Steenhagen, Joe Robins, Kevin
Brannen, Martin Wulffeld, Matthew P. Barnson, Ron Teitelbaum, Shane Travis,
Spencer Smith, Tara Hernandez, Terry Weissman, Vlad Dascalu, Zach Lipton.
