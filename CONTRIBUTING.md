# Contributing to Bugzilla

Bugzilla welcomes contribution from everyone. Here are the guidelines if you are
thinking of helping us:

## Contributions

Contributions to Bugzilla should be made in the form of GitHub pull requests.
Each pull request will be reviewed by a core contributor (someone with
permission to land patches) and either landed in the main tree or given
feedback for changes that would be required. All contributions should follow
this format, even those from core contributors.

Should you wish to work on an issue, please claim it first by commenting on
the bug that you want to work on it. This is to prevent duplicated
efforts from contributors on the same issue.

Head over to [Codetribute](https://codetribute.mozilla.org/projects/bugzilla)
to find good tasks to start with.

See [`README.md`](README.md) for more information
on how to start working on Bugzilla.

## Pull Request Checklist

- Branch from the master branch and, if needed, rebase to the current master
  branch before submitting your pull request. If it doesn't merge cleanly with
  master you may be asked to rebase your changes.

- Commits should be as small as possible, while ensuring that each commit is
  correct independently (i.e., each commit should compile and pass tests).

- **Start your PR title and commit message with `Bug XXXXXXX`** (e.g.
  `Bug 1234567 - Fix the thing`). This triggers a webhook that automatically
  links your PR to the corresponding Bugzilla bug.

- If your patch is not getting reviewed or you need a specific person to review
  it, you can @-reply a reviewer asking for a review in the pull request or a
  comment, or you can ask for a review in the
  [bugzilla.mozilla.org](https://chat.mozilla.org/#/room/#bmo:mozilla.org)
  channel on Matrix.

- Add tests relevant to the fixed bug or new feature.

For specific git instructions, see [GitHub's guide to pull requests](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests).

## Conduct

In all Bugzilla-related forums, we follow the
[Mozilla Community Participation Guidelines](https://www.mozilla.org/about/governance/policies/participation/).
 For escalation or moderation issues, please contact us on Matrix or email bmo-mods@mozilla.com.
 To report incidents, see [How to Report](https://www.mozilla.org/about/governance/policies/participation/reporting/).
 We will respond within 24 hours.

## Communication

Bugzilla contributors frequent the [bugzilla.mozilla.org](https://chat.mozilla.org/#/room/#bmo:mozilla.org) channel on Matrix.
