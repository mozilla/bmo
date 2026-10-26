/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * This Source Code Form is "Incompatible With Secondary Licenses", as
 * defined by the Mozilla Public License, v. 2.0. */

$(function() {
    'use strict';

    // comment collapse/expand

    const update_spinner = (spinner, expanded) => {
        const str = spinner.data('strings');

        spinner.attr({
            'aria-label': expanded ? str.collapse_label : str.expand_label,
            'aria-expanded': expanded,
        });
    };

    function toggleChange(spinner, forced) {
        var spinnerID = spinner.attr('id');
        var id = spinnerID.substring(spinnerID.indexOf('-') + 1);

        // non-comment toggle
        if (spinnerID.substr(0, 1) == 'a') {
            var changeSet = spinner.parents('.change-set');
            if (forced == 'hide') {
                changeSet.find('.activity').hide();
                $('#ar-' + id).hide();
                update_spinner(spinner, false);
            }
            else if (forced == 'show' || forced == 'reset') {
                changeSet.find('.activity').show();
                $('#ar-' + id).show();
                update_spinner(spinner, true);
            }
            else {
                changeSet.find('.activity').slideToggle('fast', function() {
                    $('#ar-' + id).toggle();
                    if (changeSet.find('.activity' + ':visible').length) {
                        update_spinner(spinner, true);
                    }
                    else {
                        update_spinner(spinner, false);
                    }
                });
            }
            return;
        }

        // find the "real spinner", which is the one on the non-default-collapsed block
        var realSpinner = $('#cs-' + id);
        var defaultCollapsed = realSpinner.data('ch');
        if (defaultCollapsed === undefined) {
            defaultCollapsed = spinner.attr('id').substring(0, 4) === 'ccs-';
            realSpinner.data('ch', defaultCollapsed);
        }
        if (forced === 'reset') {
            forced = defaultCollapsed ? 'hide' : 'show';
        }

        // comment toggle
        if (forced === 'hide') {
            if (defaultCollapsed) {
                $('#ch-' + id).hide();
                $('#cc-' + id).show();
            }
            $(`#ct-${id}, #cr-${id}, #cre-${id}, #ctag-${id}`).hide();
            $(`#c${id}`).find('.activity, .attachment').hide();
            update_spinner(realSpinner, false);
        }
        else if (forced == 'show') {
            if (defaultCollapsed) {
                $('#cc-' + id).hide();
                $('#ch-' + id).show();
            }
            $(`#ct-${id}, #cr-${id}, #cre-${id}, #ctag-${id}`).show();
            $(`#c${id}`).find('.activity, .attachment').show();
            update_spinner(realSpinner, true);
        }
        else {
            $(`#ct-${id}, #cre-${id}, #c${id} .attachment`).slideToggle('fast').promise().done(() => {
                $('#c' + id).find('.activity').toggle();
                if ($('#ct-' + id + ':visible').length) {
                    $(`#cr-${id}, #ctag-${id}`).show();
                    update_spinner(realSpinner, true);
                    if (defaultCollapsed) {
                        $('#cc-' + id).hide();
                        $('#ch-' + id).show();
                    }
                }
                else {
                    $(`#cr-${id}, #ctag-${id}`).hide();
                    update_spinner(realSpinner, false);
                    if (defaultCollapsed) {
                        $('#ch-' + id).hide();
                        $('#cc-' + id).show();
                    }
                }
            });
        }
    }

    // Reference the form element’s jQuery object. We use event delegation so these still work after
    // dynamic HTML updates.
    const form = $('#changeform');

    // individual comment toggles: logged-out users don’t have the form, so bind to `#main-inner`
    $('#main-inner').on('click', '.change-spinner', function(event) {
        event.preventDefault();
        toggleChange($(this));
    });

    // view and tag menus

    $('#view-reset')
        .click(function() {
            $('.change-spinner:visible').each(function() {
                toggleChange($(this), 'reset');
            });
        });

    $('#view-collapse-all')
        .click(function() {
            $('.change-spinner:visible').each(function() {
                toggleChange($(this), 'hide');
            });
        });

    $('#view-expand-all')
        .click(function() {
            $('.change-spinner:visible').each(function() {
                toggleChange($(this), 'show');
            });
        });

    $('#view-comments-only')
        .click(function() {
            $('.change-spinner:visible').each(function() {
                toggleChange($(this), this.id.substr(0, 3) === 'cs-' ? 'show' : 'hide');
            });
        });

    $('#view-toggle-treeherder')
        .click(function() {
            var that = $(this);
            var userids = that.data('userids');
            if (that.data('hidden') === '0') {
                that.data('hidden', '1');
                that.text('Show Treeherder Comments');
                userids.forEach((id) => {
                    $('.ca-' + id).each(function() {
                        toggleChange($(this).find('.default-collapsed .change-spinner').first(), 'hide');
                    });
                });
            }
            else {
                that.data('hidden', '0');
                that.text('Hide Treeherder Comments');
                userids.forEach((id) => {
                    $('.ca-' + id).each(function() {
                        toggleChange($(this).find('.default-collapsed .change-spinner').first(), 'show');
                    });
                });
            }
        });

    function updateTagsMenu() {
        var tags = [];
        $('.comment-tags').each(function() {
            $.each(tagsFromDom($(this)), function() {
                var tag = this.toLowerCase();
                if (tag in tags) {
                    tags[tag]++;
                }
                else {
                    tags[tag] = 1;
                }
            });
        });
        var tagNames = Object.keys(tags);
        tagNames.sort();

        var btn = $('#comment-tags-btn');
        if (tagNames.length === 0) {
            btn.hide();
            return;
        }
        btn.show();

        // clear out old li items. Always leave the first one (Reset)
        var $li = $('#comment-tags-menu li');
        for (var i = 1, l = $li.length; i < l; i++) {
            $li.eq(i).remove();
        }

        // add new li items
        $.each(tagNames, function(key, value) {
            $('#comment-tags-menu')
                .append($('<li role="presentation">')
                    .append($('<a role="menuitem" tabindex="-1" data-comment-tag="' + value + '">')
                        .append(value + ' (' + tags[value] + ')')));
        });

        $('a[data-comment-tag]').each(function() {
            $(this).click(function() {
                var $that = $(this);
                var tag = $that.data('comment-tag');
                if (tag === '') {
                    $('.change-spinner:visible').each(function() {
                        toggleChange($(this), 'reset');
                    });
                    return;
                }
                var firstComment = false;
                $('.change-spinner:visible').each(function() {
                    var $that = $(this);
                    var commentTags = tagsFromDom($that.parents('.comment').find('.comment-tags'));
                    var hasTag = $.inArrayIn(tag, commentTags) >= 0;
                    toggleChange($that, hasTag ? 'show' : 'hide');
                    if (hasTag && !firstComment) {
                        firstComment = $that;
                    }
                });
                if (firstComment)
                    $.scrollTo(firstComment);
            });
        });
    }

    //
    // anything after this point is only executed for logged in users
    //

    if (BUGZILLA.user.id === 0) return;

    // comment tagging

    function taggingError(commentNo, message) {
        $('#ctag-' + commentNo + ' .comment-tags').append($('#ctag-error'));
        $('#ctag-error-message').text(message);
        $('#ctag-error').show();
    }

    async function deleteTag(event) {
        event.preventDefault();
        $('#ctag-error').hide();

        var that = $(this);
        var comment = that.parents('.comment');
        var commentNo = comment.data('no');
        var commentID = comment.data('id');
        var tagNode = that.parent('.comment-tag');
        var deleteTag = tagNode.data('tag');

        // update ui
        tagNode.remove();
        updateTagsMenu();

        // update Bugzilla
        try {
            var result = await Bugzilla.API.put(
              `bug_modal/update_comment_tags/${commentID}`,
              { remove: [deleteTag] }
            );
            renderTags(commentNo, result.html);
            updateTagsMenu();
        } catch ({ message }) {
            taggingError(commentNo, message);
        }
    }

    form.on('click', '.comment-tag a.remove', deleteTag);

    function tagsFromDom(commentTagsDiv) {
        return commentTagsDiv
            .find('.comment-tag')
            .map(function() {return $(this).data('tag');})
            .toArray();
    }

    function renderTags(commentNo, html) {
        cancelRefresh();
        var root = $('#ctag-' + commentNo + ' .comment-tags');
        root.find('.comment-tag').remove();
        root.append($(html));
        root.find('.comment-tag .remove').click(deleteTag);
        $('#ctag-' + commentNo + ' .comment-tags').append($('#ctag-error'));
    }

    let abort_controller;

    const refreshTags = async (commentNo, commentID) => {
        cancelRefresh();

        try {
            abort_controller = new AbortController();

            const { signal } = abort_controller;
            var result = await Bugzilla.API.get(
                `bug_modal/comment_tags/${commentID}`,
                {}, { signal }
            );
            renderTags(commentNo, result.html);
        } catch ({ name, message }) {
            if (name !== 'AbortError') {
                taggingError(commentNo, message);
            }
        } finally {
            abort_controller = undefined;
        }
    }

    function cancelRefresh() {
        if (abort_controller) {
            abort_controller.abort();
            abort_controller = undefined;
        }
    }

    const saveTag = async () => {
        hideTaggingUI();
        $('#ctag-error').hide();

        const $comment = $('#ctag').parents('.comment');
        const commentNo = $comment.data('no');
        const commentID = $comment.data('id');
        const newTags = $('#ctag-add').val().trim().split(/[ ,]/);
        const { min_comment_tag_length: min, max_comment_tag_length: max } = BUGZILLA.constant;

        if (!newTags.length) {
            return;
        }

        // validate
        try {
            newTags.forEach(tag => {
                if (tag.length < min) {
                    throw `Comment tags must be at least ${min} characters.`;
                }
                if (tag.length > max) {
                    throw `Comment tags cannot be longer than ${max} characters.`;
                }
            });
        } catch(ex) {
            taggingError(commentNo, ex);
            return;
        }

        // update Bugzilla
        try {
            var result = await Bugzilla.API.put(
              `bug_modal/update_comment_tags/${commentID}`,
              { add: newTags }
            );
            renderTags(commentNo, result.html);
            updateTagsMenu();
        } catch ({ message }) {
            taggingError(commentNo, message);
            refreshTags(commentNo, commentID);
        }
    };

    const hideTaggingUI = () => {
        $('#ctag').hide().data('commentNo', '');
    };

    /**
     * Initialize emoji comment reactions.
     */
    const initReactions = () => {
        document.querySelectorAll('.comment-reactions').forEach((/** @type {HTMLElement} */ $wrapper) => {
            new Bugzilla.BugModal.CommentReactions($wrapper);
        });
    };

    $('#ctag-add')
        .devbridgeAutocomplete({
            appendTo: $('#main-inner'),
            forceFixPosition: true,
            deferRequestBy: 250,
            minChars: 3,
            tabDisabled: true,
            autoSelectFirst: true,
            triggerSelectOnValidInput: false,
            lookup: (query, done) => {
                // Note: `async` doesn't work for this `lookup` function, so use a `Promise` chain instead
                Bugzilla.API.get(`bug/comment/tags/${encodeURIComponent(query)}`)
                    .then(data => data.map(tag => ({ value: tag })))
                    .catch(() => [])
                    .then(suggestions => done({ suggestions }));
            },
            formatResult: function(suggestion, currentValue) {
                // disable <b> wrapping of matched substring
                return suggestion.value.htmlEncode();
            }
        })
        .keydown(event => {
            if (event.which === 27) {
                event.preventDefault();
                hideTaggingUI();
            }
            else if (event.which === 13) {
                event.preventDefault();
                saveTag();
            }
        });

    $('#ctag-save')
        .click(event => {
            event.preventDefault();
            saveTag();
        });

    $('#ctag-cancel')
        .click(event => {
            event.preventDefault();
            hideTaggingUI();
        });

    form
        .on('click', '.tag-btn', function(event) {
            event.preventDefault();
            var that = $(this);
            var commentNo = that.data('no');
            var commentID = that.data('id');
            var ctag = $('#ctag');
            $('#ctag-error').hide();

            // toggle -> hide
            if (ctag.data('commentNo') === commentNo) {
                ctag.hide().data('commentNo', '');
                window.focus();
                return;
            }
            ctag.data('commentNo', commentNo);
            ctag.data('commentID', commentID);

            // kick off a refresh of the tags
            refreshTags(commentNo, commentID);

            // expand collapsed comments
            if ($('#ct-' + commentNo + ':visible').length === 0) {
                $('#cs-' + commentNo + ', #ccs-' + commentNo).click();
            }

            // move, show, and focus tagging ui
            ctag.prependTo('#ctag-' + commentNo + ' .comment-tags').show();
            $('#ctag-add').val('').focus();
        })
        .on('click', '.close-btn', function(event) {
            event.preventDefault();
            $('#' + $(this).data('for')).hide();
        });

    updateTagsMenu();
    initReactions();
});

/**
 * Reference or define the Bugzilla app namespace.
 * @namespace
 */
var Bugzilla = Bugzilla || {}; // eslint-disable-line no-var

/**
 * Reference or define the Review namespace.
 * @namespace
 */
Bugzilla.BugModal = Bugzilla.BugModal || {};

/**
 * Implement the modal bug view's comment-related functionality.
 */
Bugzilla.BugModal.Comments = class Comments {
  /**
   * Initiate a new Comments instance.
   */
  constructor() {
    this.prepare_inline_attachments();
  }

  /**
   * Prepare to show an attachment inline if possible.
   */
  prepare_inline_attachments() {
    // Check the Bugzilla instance parameter, user setting, bug security, sensitive keywords, API
    // support and connectivity. If any of these conditions are not met, skip the inline attachment
    // rendering.
    if (
      !BUGZILLA.param.allow_attachment_display ||
      !BUGZILLA.user.settings.inline_attachments ||
      BUGZILLA.bug_secure ||
      /\b(?:hang|assertion|crash)\b/.test(BUGZILLA.bug_keywords ?? '') ||
      typeof IntersectionObserver !== 'function' ||
      navigator.connection?.type === 'cellular'
    ) {
      return;
    }

    document.querySelectorAll('.change-set').forEach($set => {
      // Skip if the comment has the `hide-attachment` tag
      const $comment = $set.querySelector('.comment:not([data-tags~="hide-attachment"])');
      // Skip if the attachment is obsolete or deleted
      const $attachment = $set.querySelector('.attachment:not(.obsolete):not(.deleted)');

      if ($comment && $attachment) {
        this.attachment = new Bugzilla.InlineAttachment($attachment);
      }
    });
  }
};

/**
 * Implement emoji comment reactions. Users can pick `+1`, `heart` and other emojis to react to a bug comment and see
 * the names of reacted users with a tooltip on the emoji buttons. This functionality makes use of the relatively new
 * Popover API with a WAI-ARIA-based fallback for older browsers, including Firefox 115 ESR.
 * @see https://developer.mozilla.org/en-US/docs/Web/API/Popover_API
 */
Bugzilla.BugModal.CommentReactions = class CommentReactions {
  /**
   * Check the availability of the Popover API. This also detects the CSS Anchor Positioning API, as positioning doesn’t
   * work well without it, depending on how the page layout (fixed global header) is structured.
   * @type {Boolean}
   */
  canUsePopover = 'popover' in HTMLElement.prototype && CSS.supports('anchor-name', '--comment-reactions');
  /** @type {Record<string, object[]> | null} */
  reactionCache = null;
  /** @type {Intl.ListFormat} */
  listFormatter = new Intl.ListFormat('en-US');

  /**
   * Initialize a new `CommentReactions` instance.
   * @param {HTMLElement} $wrapper Wrapper element with `.comment-reactions`.
   */
  constructor($wrapper) {
    /** @type {HTMLElement} */
    this.$wrapper = $wrapper;
    /** @type {HTMLElement & { popoverTargetElement?: HTMLElement, popoverTargetAction?: string }} */
    this.$anchor = $wrapper.querySelector('.anchor');
    /** @type {HTMLElement} */
    this.$picker = $wrapper.querySelector('.picker');
    /** @type {Number} */
    this.commentId = Number(/** @type {HTMLElement} */ ($wrapper.parentElement.querySelector('.comment')).dataset.id);
    /** @type {string} */
    this.anchorName = `--comment-${this.commentId}-reactions`;

    this.attachTooltipListeners();

    // When reactions are disabled (no anchor button), tooltips are still
    // available above but adding new reactions is not.
    if (!this.$anchor) {
      return;
    }

    if (this.canUsePopover) {
      // Set the anchor name dynamically
      this.$wrapper.style.setProperty('anchor-name', this.anchorName);
      this.$picker.style.setProperty('position-anchor', this.anchorName);

      this.$anchor.popoverTargetElement = this.$picker;
      this.$anchor.popoverTargetAction = 'toggle';
      this.$picker.popover = 'auto';

      this.$picker.addEventListener('toggle', (/** @type {ToggleEvent} */ { newState }) => {
        this.$picker.inert = newState === 'closed';
      });

      // Work around Safari issues
      document.addEventListener('click', (event) => {
        if (event.target === this.$anchor) {
          event.stopPropagation();
          this.$picker.inert = !this.$picker.inert;
        } else if (this.isPickerOpen) {
          this.isPickerOpen = false;
        }
      });
    } else {
      this.$picker.id = `c${this.commentId}-reactions-picker`;
      this.$anchor.setAttribute('aria-haspopup', 'dialog');
      this.$anchor.setAttribute('aria-expanded', 'false');
      this.$anchor.setAttribute('aria-controls', this.$picker.id);

      this.$anchor.addEventListener('click', (event) => {
        event.stopPropagation();
        this.isPickerOpen = !this.isPickerOpen;
      });

      this.$picker.addEventListener('keydown', (event) => {
        if (this.isPickerOpen && event.key === 'Escape') {
          this.isPickerOpen = false;
        }
      });

      document.addEventListener('click', () => {
        if (this.isPickerOpen) {
          this.isPickerOpen = false;
        }
      });
    }

    // Automatically close the popover when the focus moves out
    document.addEventListener('focusin', () => {
      if (this.isPickerOpen && !this.$picker.contains(document.activeElement)) {
        this.isPickerOpen = false;
      }
    });

    this.buttons.forEach(($button) => {
      $button.addEventListener('click', async () => {
        this.toggleReaction($button);
      });
    });
  }

  /**
   * Attach `mouseenter` and `focus` listeners on `.sum` buttons to fetch and display reaction
   * tooltips. This is called for both active and disabled reaction states so that users can
   * always see who reacted.
   */
  attachTooltipListeners() {
    const updateButtons = () => this.updateButtons();

    this.buttons
      .filter(($button) => $button.matches('.sum'))
      .forEach(($button) => {
        $button.addEventListener('mouseenter', updateButtons);
        $button.addEventListener('focus', updateButtons);
      });
  }

  /**
   * All the emoji buttons.
   */
  get buttons() {
    return /** @type {HTMLButtonElement[]} */ ([...this.$wrapper.querySelectorAll('button[data-reaction-name]')]);
  }

  /**
   * Whether the reaction picker is displayed.
   */
  get isPickerOpen() {
    return !this.$picker.inert;
  }

  /**
   * Open or close the reaction picker.
   */
  set isPickerOpen(open) {
    if (this.canUsePopover) {
      if (open) {
        this.$picker.showPopover();
      } else {
        this.$picker.hidePopover();
      }
    } else {
      if (!open && this.$picker.contains(document.activeElement)) {
        this.$anchor.focus();
      }

      this.$anchor.setAttribute('aria-expanded', String(open));
    }

    this.$picker.inert = !open;
  }

  /**
   * Retrieve the current reactions if a cache is not yet created, and update all the buttons, including the count and
   * tooltip.
   */
  async updateButtons() {
    this.reactionCache ??= await Bugzilla.API.get(`bug/comment/${this.commentId}/reactions`);

    this.buttons.forEach(($button) => {
      const { reactionName, reactionLabel } = $button.dataset;
      /** @type {{ id: number, nick: string, real_name: string, name: string }[]} */
      const reactedUsers = [...(this.reactionCache?.[reactionName] ?? [])];

      const totalCount = reactedUsers.length;
      const isMyReaction = reactedUsers.some((u) => u.id === BUGZILLA.user.id);
      const userNames = reactedUsers.splice(0, 10).map((u) => u.nick || u.real_name || u.name);
      const restCount = reactedUsers.length;

      if (restCount) {
        userNames.push(`${restCount} ${restCount > 1 ? 'others' : 'other'}`);
      }

      $button.dataset.reactionCount = String(totalCount);
      $button.setAttribute('aria-pressed', String(isMyReaction));

      if ($button.matches('.sum')) {
        const $count = $button.querySelector('.count');

        $button.title = totalCount ? `${this.listFormatter.format(userNames)} reacted with ${reactionLabel} emoji` : '';
        $button.hidden = !totalCount;
        $count.textContent = String(totalCount);
        $count.setAttribute(
          'aria-label',
          `${totalCount} ${totalCount === 1 ? 'person' : 'people'} reacted with ${reactionLabel} emoji`,
        );
      }
    });
  }

  /**
   * Add or remove a reaction via the API.
   * @param {HTMLButtonElement} $button Reaction button.
   */
  async toggleReaction($button) {
    const { reactionName, reactionCount } = $button.dataset;
    const action = $button.matches('[aria-pressed="true"]') ? 'remove' : 'add';
    const newCount = Number(reactionCount) + (action === 'add' ? 1 : -1);

    if (this.isPickerOpen) {
      this.isPickerOpen = false;
    }

    // Update the UI immediately without waiting for API response
    this.$wrapper
      .querySelectorAll(`button[data-reaction-name="${CSS.escape(reactionName)}"]`)
      .forEach((/** @type {HTMLButtonElement} */ $_button) => {
        $_button.dataset.reactionCount = String(newCount);
        $_button.setAttribute('aria-pressed', String(action === 'add'));

        if ($_button.matches('.sum')) {
          $_button.hidden = !newCount;
          $_button.querySelector('.count').textContent = String(newCount);
        }
      });

    this.reactionCache = await Bugzilla.API.put(`bug/comment/${this.commentId}/reactions`, {
      [action]: [reactionName],
    });

    this.updateButtons();
  }
};

/**
 * Implement the inline attachment renderer that will be used for bug comments. For a better performance, this
 * functionality uses the Intersection Observer API to show an attachment when the comment goes into the viewport.
 */
Bugzilla.InlineAttachment = class InlineAttachment {
  /**
   * Initiate a new InlineAttachment instance.
   * @param {HTMLElement} $attachment Attachment container on each comment.
   */
  constructor($attachment) {
    this.$attachment = $attachment;
    this.id = Number(this.$attachment.dataset.id);
    this.link = this.$attachment.querySelector('.link').href;
    this.name = this.$attachment.querySelector('[itemprop="name"]').content;
    this.size = Number(this.$attachment.querySelector('[itemprop="contentSize"]').content);
    this.type = this.$attachment.querySelector('[itemprop="encodingFormat"]').content;
    this.media = this.type.split('/').shift();

    // Show image smaller than 2 MB, excluding SVG and non-standard formats
    if (this.type.match(/^image\/(?!vnd|svg).+$/) && this.size < 2000000) {
      this.show_image();
    }

    // Show audio and video
    if (this.type.match(/^(?:audio|video)\/(?!vnd).+$/) && document.createElement(this.media).canPlayType(this.type)) {
      this.show_media();
    }

    // Detect text (code from attachment.js)
    this.is_patch = this.$attachment.matches('.patch');
    this.is_markdown = !!this.name.match(/\.(?:md|mkdn?|mdown|markdown)$/);
    this.is_source = !!this.name.match(/\.(?:cpp|es|h|js|json|rs|rst|sh|toml|ts|tsx|xml|yaml|yml)$/);
    this.is_text = this.type.match(/^text\/(?!x-).+$/) || this.is_patch || this.is_markdown || this.is_source;

    // Show text smaller than 50 KB
    if (this.is_text && this.size < 50000) {
      this.show_text();
    }
  }

  /**
   * Show an image attachment.
   */
  async show_image() {
    // Insert a placeholder first
    this.$attachment.insertAdjacentHTML('beforeend', `<a href="${this.link}" class="outer lightbox"></a>`);

    // Wait until the container goes into the viewport
    await this.watch_visibility();

    const $image = new Image();

    try {
      await new Promise((resolve, reject) => {
        $image.addEventListener('load', () => resolve(), { once: true });
        $image.addEventListener('error', () => reject(), { once: true });
        $image.src = this.link;
      });

      $image.setAttribute('itemprop', 'image');
      this.$outer.title = this.name;
      this.$outer.appendChild($image);
    } catch (ex) {
      this.$outer.remove();
    }
  }

  /**
   * Show an audio or video attachment.
   */
  async show_media() {
    // Insert a placeholder first
    this.$attachment.insertAdjacentHTML('beforeend', '<span class="outer"></span>');

    // Wait until the container goes into the viewport
    await this.watch_visibility();

    const $media = document.createElement(this.media);

    try {
      await new Promise((resolve, reject) => {
        $media.addEventListener('loadedmetadata', () => resolve(), { once: true });
        $media.addEventListener('error', () => reject(), { once: true });
        $media.src = this.link;
      });

      $media.setAttribute('itemprop', this.media);
      $media.controls = true;
      this.$outer.appendChild($media);
    } catch (ex) {
      this.$outer.remove();
    }
  }

  /**
   * Show a text attachment. Fetch the raw text via the API.
   */
  async show_text() {
    // Insert a placeholder first
    this.$attachment.insertAdjacentHTML('beforeend',
      `<button type="button" role="link" title="${this.name.htmlEncode()}" class="outer"></button>`);

    // Wait until the container goes into the viewport
    await this.watch_visibility();

    try {
      const { attachments } = await Bugzilla.API.get(`bug/attachment/${this.id}`, { include_fields: 'data' });
      const text = decodeURIComponent(escape(atob(attachments[this.id].data)));
      const lang = this.is_patch ? 'diff' : this.type.match(/\w+$/)[0];

      this.$outer.innerHTML = `<pre class="language-${lang}" role="img" itemprop="text">${text.htmlEncode()}</pre>`;

      // Make the button work as a link. It cannot be `<a>` because Prism Autolinker plugin may add links to `<pre>`
      this.$attachment.querySelector('[role="link"]').addEventListener('click', () => location.href = this.link);

      if (Prism) {
        Prism.highlightElement(this.$attachment.querySelector('pre'));
        this.$attachment.querySelectorAll('pre a').forEach($a => $a.tabIndex = -1);
      }
    } catch (ex) {
      this.$outer.remove();
    }
  }

  /**
   * Use the Intersection Observer API to watch the visibility of the attachment container.
   * @returns {Promise} Resolved once the container goes into the viewport.
   * @see https://developer.mozilla.org/en-US/docs/Web/API/Intersection_Observer_API
   */
  async watch_visibility() {
    this.$outer = this.$attachment.querySelector('.outer');

    return new Promise(resolve => {
      const observer = new IntersectionObserver(entries => entries.forEach(entry => {
        if (entry.intersectionRatio > 0) {
          observer.disconnect();
          resolve();
        }
      }), { root: document.querySelector('#bugzilla-body') });

      observer.observe(this.$attachment);
    });
  }
};

/**
 * Implement the instant update functionality for the modal bug page that allows users to submit a
 * new comment without reloading the page. This functionality uses optimistic rendering to show a
 * placeholder comment immediately after the user submits a new comment, and then updates the
 * comment section and other affected elements from the server response.
 */
Bugzilla.BugModal.InstantUpdater = class InstantUpdater {
  /**
   * Reference to the bug form element.
   * @type {HTMLFormElement}
   */
  $form = null;

  /**
   * Reference to the comment textarea element.
   * @type {HTMLTextAreaElement}
   */
  $commentTextArea = null;

  /**
   * Reference to the last change set element before the placeholder.
   * @type {HTMLElement}
   */
  $lastChangeSet = null;

  /**
   * Reference to the change set placeholder template.
   * @type {HTMLTemplateElement}
   */
  $placeholderTemplate = null;

  /**
   * Reference to the placeholder change set element.
   * @type {HTMLElement}
   */
  $placeholder = null;

  /**
   * Initial form data captured on page load for change detection.
   * @type {FormData}
   */
  initialFormData = null;

  /**
   * Fields to ignore when detecting changes.
   */
  IGNORED_FIELDS = ['delta_ts', 'token', 'editing', 'defined_groups'];

  /**
   * Selectors for elements whose `value` attributes need to be updated.
   */
  VALUE_REPLACE_SELECTORS = ['input[name="delta_ts"]', 'input[name="token"]'];

  /**
   * Selectors for elements whose `innerHTML` need to be updated.
   */
  CONTENT_REPLACE_SELECTORS = ['#field-status_summary'];

  /**
   * Initialize the instant update functionality. This captures the initial form data for later
   * change detection.
   * @param {HTMLFormElement} $form The bug form element.
   */
  constructor($form) {
    this.$form = $form;
    this.$placeholderTemplate = document.querySelector('#changeset-template');
    this.$commentTextArea = document.querySelector('#comment');
    this.initialFormData = new FormData($form);
    this.commentBoxPosition = BUGZILLA.user.settings?.comment_box_position ?? 'after_comments';
    this.commentSortOrder = BUGZILLA.user.settings?.comment_sort_order ?? 'oldest_to_newest';
  }

  /**
   * Submit the form data via the API, show a placeholder comment, fetch the updated page, and
   * update the comment section and other affected elements.
   * @throws {Error} When any step fails.
   */
  async submit() {
    const currentFormData = new FormData(this.$form);
    /** @type {Record<string, any>} */
    const changedFields = {};

    // Detect changed fields
    currentFormData.forEach((value, key) => {
      if (
        // New or changed field
        (!this.IGNORED_FIELDS.includes(key) && this.initialFormData.get(key) !== value) ||
        // “Clear needinfo” checkbox for myself, which is ticked by default
        key.startsWith('needinfo_override_') ||
        // “Add me to CC” checkbox, which is also ticked by default depending on user settings
        key === 'addselfcc'
      ) {
        changedFields[key] = value;
      }
    });

    const changedKeys = Object.keys(changedFields);

    // Only the `comment` field is supported for instant update at the moment
    if (changedKeys.length !== 1 || changedKeys[0] !== 'comment') {
      throw new Error('BEFORE_SUBMIT_HALT', {
        cause: 'Unsupported field changes detected.',
      });
    }

    // `@nickname` mentions are only processed for comments submitted through the form, not the
    // API, so let the form handle them. This loosely mirrors `_extract_mentions` in the Needinfo
    // extension. A false positive only costs a page reload.
    if (/(?<![\w@./-])@[\p{L}\p{N}|._-]/u.test(changedFields.comment)) {
      throw new Error('BEFORE_SUBMIT_HALT', {
        cause: 'Comment mentions users.',
      });
    }

    // Show a placeholder comment immediately. Don't `await` this because the HTML rendering doesn’t
    // block the following operations.
    try {
      this.#showPlaceholder();
    } catch {
      throw new Error('BEFORE_SUBMIT_HALT', {
        cause: 'Failed to show the placeholder comment.',
      });
    }

    // Reset the initial form data for the next submission
    this.initialFormData = currentFormData;

    const { comment } = changedFields;
    const is_markdown = BUGZILLA.param.use_markdown;

    try {
      // Submit the new comment via the API
      await Bugzilla.API.post(`bug/${BUGZILLA.bug_id}/comment`, { comment, is_markdown });
    } catch {
      throw new Error('DURING_SUBMIT_HALT', {
        cause: 'Failed to submit the new comment.',
      });
    }

    try {
      this.#updatePage(await this.#fetchUpdatedDoc());
    } catch {
      throw new Error('AFTER_SUBMIT_HALT', {
        cause: 'Failed to fetch or update the page with the new comment.',
      });
    }
  }

  /**
   * Show a placeholder comment while waiting for the server response.
   */
  async #showPlaceholder() {
    // Disable the textarea
    this.$commentTextArea.readOnly = true;
    this.$commentTextArea.hidden = true;

    const changeSets = [...document.querySelectorAll('.change-set')];
    const lastChangeSetIndex =
      this.commentSortOrder === 'newest_to_oldest'
        ? 0
        : this.commentSortOrder === 'newest_to_oldest_desc_first'
        ? 1
        : changeSets.length - 1;

    this.$placeholder = this.$placeholderTemplate.content.firstElementChild.cloneNode(true);
    this.$lastChangeSet = changeSets[lastChangeSetIndex];

    const rawComment = this.$commentTextArea.value;
    const commentCount = changeSets.filter(({ id }) => id.match(/^c\d+/)).length;
    const $placeholderCommentBody = this.$placeholder.querySelector('.comment-text');

    // Update the placeholder content
    this.$placeholder.querySelector('.change-name a').textContent = `Comment ${commentCount}`;
    this.$placeholder.querySelector('.change-time span').textContent = 'Just now';
    this.$placeholder.querySelectorAll('button').forEach(($btn) => {
      $btn.disabled = true;
    });

    // Insert the raw comment first; don’t use `innerHTML` here to avoid XSS
    $placeholderCommentBody.textContent = rawComment;

    // Insert the placeholder before or after the last change set
    this.$lastChangeSet.insertAdjacentElement(
      this.commentSortOrder === 'oldest_to_newest' ? 'afterend' : 'beforebegin',
      this.$placeholder
    );

    // Fetch the rendered HTML from the server
    const { html } = await Bugzilla.API.post('bug/comment/render', { text: rawComment });

    // Replace the raw comment; safe to use `innerHTML` here
    $placeholderCommentBody.innerHTML = html;
  }

  /**
   * Fetch the updated bug page from the server. We have to fetch the whole page because the comment
   * section may be affected by other users’ changes in the meantime, and we also need to update the
   * CSRF token and last change time in the form.
   * @returns {Promise<Document>} Parsed HTML document from the server response.
   * @throws {Error} When the response does not contain the expected elements.
   */
  async #fetchUpdatedDoc() {
    const response = await fetch(`${BUGZILLA.config.basepath}show_bug.cgi?id=${BUGZILLA.bug_id}`);
    const html = await response.text();
    const updatedDoc = new DOMParser().parseFromString(html, 'text/html');

    if (!updatedDoc.querySelector('#changeform')) {
      // Something went wrong, e.g. mid-air collision, session timeout, or CSRF failure.
      throw new Error('Failed to submit the changes in background.');
    }

    return updatedDoc;
  }

  /**
   * Update the page with the new comment and other updated elements from the server response.
   * @param {Document} updatedDoc Parsed HTML document from the server response.
   */
  #updatePage(updatedDoc) {
    /** @type {HTMLElement[]} */
    const allChangeSets = [...updatedDoc.querySelectorAll('.change-set')];
    const lastChangeSetIndex = allChangeSets.findIndex(({ id }) => id === this.$lastChangeSet.id);
    const newChangeSetRange =
      this.commentSortOrder === 'newest_to_oldest'
        ? [0, lastChangeSetIndex]
        : this.commentSortOrder === 'newest_to_oldest_desc_first'
        ? [1, lastChangeSetIndex]
        : [lastChangeSetIndex + 1];
    const newChangeSets = allChangeSets.slice(...newChangeSetRange);

    // Replace the placeholder with the new change sets
    this.$placeholder.replaceWith(...newChangeSets);

    newChangeSets.forEach(($changeSet) => {
      this.#hydrateChangeSet($changeSet);
    });

    // Re-enable and clear the comment textarea
    this.$commentTextArea.readOnly = false;
    this.$commentTextArea.hidden = false;
    this.$commentTextArea.value = '';

    // Switch to preview mode to show the comment box
    document.querySelector('#add-comment [data-command="edit"]').click();

    // Re-enable the save button
    document.querySelectorAll('.save-btn').forEach(($btn) => {
      $btn.disabled = false;
    });

    // Update the last change time and CSRF tokens in the form
    this.VALUE_REPLACE_SELECTORS.forEach((selector) => {
      document.querySelector(selector).value = updatedDoc.querySelector(selector).value;
    });

    // Update the status summary, including the timestamp
    this.CONTENT_REPLACE_SELECTORS.forEach((selector) => {
      document.querySelector(selector).innerHTML = updatedDoc.querySelector(selector).innerHTML;
    });

    Bugzilla.Toast.show('New comment added', {
      position: this.commentBoxPosition === 'before_comments' ? 'top' : 'bottom',
    });
  }

  /**
   * Hydrate interactive components such as emoji reactions and inline attachments in a change set.
   * @param {HTMLElement} $changeSet Change set element.
   */
  #hydrateChangeSet($changeSet) {
    const $comment = $changeSet.querySelector('.comment-text');
    const $reactions = $changeSet.querySelector('.comment-reactions');
    const $attachment = $changeSet.querySelector('.attachment');

    if ($comment) {
      // `InlineCommentEditor` is undefined when the user is not allowed to edit comments
      Bugzilla.InlineCommentEditor?.activate($changeSet);
    }

    if ($reactions) {
      new Bugzilla.BugModal.CommentReactions($reactions);
    }

    if ($attachment) {
      new Bugzilla.InlineAttachment($attachment);
    }
  }
};

document.addEventListener('DOMContentLoaded', () => new Bugzilla.BugModal.Comments(), { once: true });
