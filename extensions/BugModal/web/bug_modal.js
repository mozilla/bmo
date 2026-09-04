/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * This Source Code Form is "Incompatible With Secondary Licenses", as
 * defined by the Mozilla Public License, v. 2.0. */

// expand/collapse module
function slide_module(module, action, fast) {
    if (!module.attr('id'))
        return;
    var latch = module.find('.module-latch');
    var spinner = module.find('.module-spinner');
    var content = $(module.children('.module-content')[0]);
    var duration = fast ? 0 : 200;

    function slide_done() {
        var is_visible = content.is(':visible');
        spinner.attr({
            'aria-expanded': is_visible,
            'aria-label': is_visible ? latch.data('label-expanded') : latch.data('label-collapsed'),
        });
        if (BUGZILLA.user.settings.remember_collapsed && module.is(':visible'))
            Bugzilla.Storage.set(module.attr('id') + '.visibility', is_visible ? 'show' : 'hide');
    }

    if (action == 'show') {
        content.slideDown(duration, 'swing', slide_done);
    }
    else if (action == 'hide') {
        content.slideUp(duration, 'swing', slide_done);
    }
    else {
        content.slideToggle(duration, 'swing', slide_done);
    }
}

function init_module_visibility() {
    if (!BUGZILLA.user.settings.remember_collapsed)
        return;
    $('.module').each(function() {
        var that = $(this);
        var id = that.attr('id');
        if (!id) return;
        if (that.data('non-stick')) return;
        var stored = Bugzilla.Storage.get(id + '.visibility');
        if (stored) {
            slide_module(that, stored, true);
        }
    });
}

/**
 * Initialize the Keyword field’s autocomplete functionality.
 * @param {string[]} keywords Available keyword list.
 */
function initKeywordsAutocomplete(keywords) {
    const $keywords = document.querySelector('#keywords');

    $($keywords)
        .devbridgeAutocomplete({
            appendTo: $('#main-inner'),
            forceFixPosition: true,
            lookup: function(_query, done) {
                const enteredKeywords = $keywords.value
                    .split(',')
                    .map((keyword) => keyword.trim().toLowerCase());
                const query = enteredKeywords.pop();
                const matchStart = [];
                const matchSub = [];

                keywords.forEach((keyword) => {
                    const lowerKeyword = keyword.toLowerCase();

                    if (enteredKeywords.includes(lowerKeyword) || !lowerKeyword.includes(query)) {
                        return;
                    }

                    if (lowerKeyword.startsWith(query)) {
                        matchStart.push(keyword);
                    } else {
                        matchSub.push(keyword);
                    }
                });

                done({ suggestions: [...matchStart, ...matchSub].map((value) => ({ value })) });
            },
            tabDisabled: true,
            delimiter: /,\s*/,
            minChars: 0,
            autoSelectFirst: false,
            triggerSelectOnValidInput: false,
            formatResult: function(suggestion, currentValue) {
                // disable <b> wrapping of matched substring
                return suggestion.value.htmlEncode();
            },
            onSearchStart: function(params) {
                var that = $(this);
                // adding spaces shouldn't initiate a new search
                var parts = that.val().split(/,\s*/);
                var query = parts[parts.length - 1];
                return query === $.trim(query);
            },
            onSelect: function() {
                this.value = this.value + ', ';
                this.focus();
            }
        })
        .addClass('bz_autocomplete');
};

/**
 * Initialize the Dependency Tree module if the container element is present on the page.
 */
const initDependencyTree = async () => {
  const $treeContainer = document.querySelector('#dependency-tree-container');
  const $listContainer = document.querySelector('#dependency-list-container');

  if (!$treeContainer || !$listContainer) {
    return;
  }

  const removeTree = () => {
    $treeContainer.remove();
    $listContainer.hidden = false;
  };

  const { config: { basepath }, bug_id: bugId } = BUGZILLA;
  const url = `${basepath}showdependencytree.cgi?id=${bugId}&hide_resolved=1&embed=1`;
  const response = await fetch(url);

  if (!response.ok) {
    removeTree();

    return;
  }

  // Safe to inject HTML as is: same-origin fetch, Template Toolkit escapes all user-supplied data
  $treeContainer.innerHTML = await response.text();
  new Bugzilla.DependencyTree();

  // Add a button to hide the dependency tree and show the original flat list of dependencies again
  const $button = Object.assign(document.createElement('button'), {
    type: 'button',
    id: 'hide-dependency-tree-btn',
    className: 'ghost',
    textContent: 'Hide Dependency Tree',
  });

  $button.addEventListener('click', (event) => removeTree(), { once: true });
  $treeContainer.querySelector('[role="toolbar"]')?.insertAdjacentElement('beforeend', $button);
};

$(function() {
    'use strict';

    /**
     * Reference to the main bug change form.
     * @type {HTMLFormElement}
     */
    const $form = document.querySelector('#changeform');

    /**
     * Flag indicating whether we are creating a new bug or editing an existing one.
     */
    const isNewBug = BUGZILLA.bug_id === undefined;

    /**
     * Instance of the instant update handler.
     */
    const instantUpdater =
      $form && !isNewBug
        ? new Bugzilla.BugModal.InstantUpdater($form)
        : undefined;

    /**
     * Flag indicating whether the user is in Edit mode or not. This affects the behavior of the
     * Save button.
     */
    let editMode = isNewBug || false;

    // update relative dates
    var relative_timer_duration = 60000;
    var relative_timer_id = window.setInterval(relativeTimer, relative_timer_duration);

    window.addEventListener('visibilitychange', () => {
      if (document.hidden) {
        window.clearInterval(relative_timer_id);
      } else {
        relative_timer_id = window.setInterval(relativeTimer, relative_timer_duration);
      }
    });

    function relativeTimer() {
        var now = Math.floor(new Date().getTime() / 1000);
        $('.rel-time').each(function() {
            $(this).text(timeAgo(now - $(this).data('time')));
        });
        $('.rel-time-title').each(function() {
            $(this).attr('title', timeAgo(now - $(this).data('time')));
        });
    }

    // all keywords for autocompletion (lazy-loaded on edit)
    var keywords = [];

    // products with descriptions (also lazy-loaded)
    var products = [];

    // restore edit mode after navigating back
    function restoreEditMode() {
        if (!$('#editing').val()) {
            if (Bugzilla.Storage.get('modal-perm-edit-mode') === true) {
                $('#mode-btn').click();
                $('#action-enable-perm-edit').attr('aria-checked', 'true');
            }
            return;
        }
        $('.module')
            .each(function() {
                slide_module($(this), 'hide', true);
            });
        $($('#editing').val().split(' '))
            .each(function() {
                slide_module($('#' + this), 'show', true);
            });
        $('#mode-btn').click();
        $('.save-btn').prop('disabled', false);
        $('#editing').val('');
    }

    /**
     * Local storage key to be used to cache the entered comment. Use `0` as the bug ID on the New Bug form.
     */
    const bugCommentCacheKey = `bug-modal-saved-comment-${BUGZILLA.bug_id ?? 0}`;

    function saveBugComment(text) {
        if (text.length < 1) return clearSavedBugComment();
        if (text.length >  65535) return;
        let value = {
            text: text,
            savedAt: Date.now()
        };
        Bugzilla.Storage.set(bugCommentCacheKey, JSON.stringify(value));
    }

    /**
     * Clear comment cache once the comment field is emptied or the bug is successfully updated.
     * @param {Number} [bug_id] Bug ID to be used for the cache key. The updated bug will be different from the current
     * bug when the user has changed the “after changing a bug” preference to “show next bug in my list.” Pass a bug ID
     * to take such special cases into account. Otherwise the current bug’s comment cache will be removed.
     */
    const clearSavedBugComment = (bug_id = BUGZILLA.bug_id) => {
        Bugzilla.Storage.delete(`bug-modal-saved-comment-${bug_id}`);
    };

    /**
     * Reference to an element showing the change summary on an created/updated bug page. It’s hidden by default.
     */
    const $changeSummary = document.querySelector('.change-summary.bug');

    if ($changeSummary) {
        const { type, id } = $changeSummary.dataset;

        if (type === 'created') {
            clearSavedBugComment(0);
        } else if (type === 'bug') {
            clearSavedBugComment(Number(id));
        }
    }

    function restoreSavedBugComment() {
        expireSavedComments();
        let value = Bugzilla.Storage.get(bugCommentCacheKey);
        if (value){
            let commentBox = document.querySelector("textarea#comment");
            if (commentBox.value === '')
              commentBox.value = value['text'];
            // Resize the textarea and enable the Preview button
            commentBox.dispatchEvent(new InputEvent('input'));
        }
    }

    function expireSavedComments() {
        const AGE_THRESHOLD = 7 * 24 * 60 * 60 * 1000; // 7 days in milliseconds.
        let expiredKeys = [];
        for (let i = 0; i < window.localStorage.length; i++) {
            let key = window.localStorage.key(i);
            if (key.match(/^bug-modal-saved-comment-/)) {
                let value = Bugzilla.Storage.get(key);
                let savedAt = value['savedAt'] || 0;
                let age = Date.now() - savedAt;
                if (age < 0 || age > AGE_THRESHOLD) {
                    expiredKeys.push(key);
                }
            }
        }
        expiredKeys.forEach((key) => {
            Bugzilla.Storage.delete(key);
        });
    }

    // expand/collapse module
    $('.module-latch')
        .click(function(event) {
            event.preventDefault();
            slide_module($(this).parents('.module'));
        })
        .keydown(function(event) {
            // expand/collapse module with the enter or space key
            if (event.keyCode === 13 || event.keyCode === 32) {
                event.preventDefault();
                slide_module($(this).parents('.module'));
            }
        });

    // toggle obsolete/external attachments
    let attachObsoleteShowing = false;
    let attachExternalShowing = false;

    function updateAttachmentRows() {
        // A row may be obsolete, external, or both. It is only visible when
        // every category it belongs to has been toggled on, so external rows
        // stay hidden while "Show External" is off even if they are obsolete.
        $('#attachments tr.attach-obsolete, #attachments tr.attach-external').each(function() {
            const $row = $(this);
            const visible =
                (!$row.hasClass('attach-obsolete') || attachObsoleteShowing) &&
                (!$row.hasClass('attach-external') || attachExternalShowing);
            $row.toggle(visible);
        });
        $('#attachments-obsolete-btn').text(attachObsoleteShowing ? 'Hide Obsolete' : 'Show Obsolete');
        $('#attachments-external-btn').text(attachExternalShowing ? 'Hide External' : 'Show External');
    }

    $('#attachments-obsolete-btn').click(function(event) {
        event.preventDefault();
        attachObsoleteShowing = !attachObsoleteShowing;
        updateAttachmentRows();
    });

    $('#attachments-external-btn').click(function(event) {
        event.preventDefault();
        attachExternalShowing = !attachExternalShowing;
        updateAttachmentRows();
    });

    // top btn
    $('#top-btn')
        .click(function(event) {
            event.preventDefault();
            $.scrollTo($('#main-inner'));
        });

    // bottom btn
    $('#bottom-btn')
        .click(function(event) {
            event.preventDefault();
            $.scrollTo($('#bottom-actions'));
        });

    // show floating message after creating/updating a bug/attachment
    const { changeSummary } = $form?.dataset ?? {};

    if (changeSummary) {
        Bugzilla.Toast.show(changeSummary);
    }

    const $tooltipParent = document.querySelector('#bugzilla-body');

    // use non-native tooltips for relative/absolute times and bug summaries
    const tooltip_sources = $('.rel-time, .rel-time-title, .abs-time-title, .bz_bug_link, .tt').tooltip({
        position: { my: "left top+8", at: "left bottom", collision: "flipfit" },
        show: { effect: 'none' },
        hide: { effect: 'none' },
        // Change the parent element from `<body>` to the main scrolling area and recalculate the
        // position when a tooltip is displayed, so that it won’t be affected by the fixed header
        open: (event, ui) => {
          const $tooltip = /** @type {HTMLElement} */ (ui.tooltip[0]);
          const currentTop = Number.parseInt($tooltip.style.top, 10);

          $tooltip.style.top = `${currentTop - $tooltipParent.offsetTop + $tooltipParent.scrollTop}px`;
          $tooltipParent.appendChild($tooltip);
        }
    });

    // Don't show the tooltip when the window gets focus
    window.addEventListener('focus', event => {
      // Temporarily disable the tooltip and enable it again
      tooltip_sources.tooltip('option', 'disabled', true);
      window.setTimeout(() => {
        tooltip_sources.tooltip('option', 'disabled', false);
      }, 150);
    });

    // tooltips create a new ui-helper-hidden-accessible div each time a
    // tooltip is shown.  this is never removed leading to memory leak and
    // bloated dom.  http://bugs.jqueryui.com/ticket/10689
    $('.ui-helper-hidden-accessible').remove();

    // product/component info
    $('.spin-toggle, #product-latch, #component-latch')
        .click(function(event) {
            spin_toggle(event);
        }).keydown(function(event) {
            // allow space or enter to toggle visibility
            if (event.keyCode == 13 || event.keyCode == 32) {
                spin_toggle(event);
            }
        });

    function spin_toggle(event) {
        event.preventDefault();
        var type  = $(event.target).data('for');
        var latch = $('#' + type + '-latch');
        var name  = $('#' + type + '-name');
        var info  = $('#' + type + '-info');
        var label = latch.attr('aria-label');

        if (latch.data('expanded')) {
            label = label.replace(/^hide/, 'show');
            latch.data('expanded', false).html('&#9656;');
            latch.attr('aria-expanded', false);
            info.hide();
        }
        else {
            label = label.replace(/^show/, 'hide');
            latch.data('expanded', true).html('&#9662;');
            latch.attr('aria-expanded', true);
            info.show();
        }
        latch.attr('aria-label', label);
        name.attr('title', label);
    }

    // cc list

    function ccListLoading() {
        $('#cc-list').html(
            `<img src="${BUGZILLA.config.basepath}extensions/BugModal/web/throbber.gif" width="16" height="11"> Loading...`
        );
    }

    async function ccListUpdate() {
        try {
            const { html } = await Bugzilla.API.get(`bug_modal/cc/${BUGZILLA.bug_id}`);

            $('#io-error').empty().hide();
            $('#cc-list').html(html);
            $('#cc-latch').data('fetched', true);
            $('#cc-list .cc-user').hover(
                function() {
                    $('#ccr-' + $(this).data('n')).css('visibility', 'visible');
                },
                function() {
                    $('#ccr-' + $(this).data('n')).css('visibility', 'hidden');
                }
            );
            $('#cc-list .cc-remove')
                .click(function(event) {
                    event.preventDefault();
                    $('#top-save-btn').show();
                    var n = $(this).data('n');
                    var ccu = $('#ccu-' + n);
                    if (ccu.hasClass('cc-removed')) {
                        ccu.removeClass('cc-removed');
                        $('#cc-' + n).remove();
                    }
                    else {
                        $('#removecc').val('on');
                        ccu.addClass('cc-removed');
                        $('<input>').attr({
                            type: 'hidden',
                            id: 'cc-' + n,
                            value: $('#ccr-' + n).data('login'),
                            name: 'cc'
                        }).appendTo('#changeform');
                    }
                });
        } catch ({ message }) {
            $('#io-error').html(message).show('fast');
        }
    }

    if (BUGZILLA.user.id) {
        $('#cc-summary').addClass('cc-loadable');
        $('#cc-latch, #cc-summary')
            .click(function(event) {
                cc_toggle(event);
            }).keydown(function(event) {
                // allow space or enter to toggle visibility
                if (event.keyCode == 13 || event.keyCode == 32) {
                    cc_toggle(event);
                }
            });
    }

    function cc_toggle(event) {
        event.preventDefault();
        var latch = $('#cc-latch');
        var label = latch.attr('aria-label');
        if (latch.data('expanded')) {
            label = label.replace(/^hide/, 'show');
            latch.data('expanded', false).html('&#9656;');
            $('#cc-list').hide();
        }
        else {
            latch.data('expanded', true).html('&#9662;');
            label = label.replace(/^show/, 'hide');
            $('#cc-list').show();
            if (!latch.data('fetched')) {
                ccListLoading();
                ccListUpdate();
            }
        }
        latch.attr('aria-label', label);
        $('#cc-summary').attr('aria-label', label);
    }

    // copy summary to clipboard

    if ($('#copy-summary').length) {
        if (Bugzilla.Clipboard.canCopy) {
            const copy = (data, name) => {
                const capitalizedName = `${name[0].toUpperCase()}${name.slice(1)}`;

                Bugzilla.Clipboard.copy(data, {
                    successMessage: `${capitalizedName} copied!`,
                    errorMessage: `Couldn’t copy ${name}`,
                });
            }

            const url = BUGZILLA.bug_url;

            const bugNumberText = `bug ${BUGZILLA.bug_id}`;
            const summaryText = `Bug ${BUGZILLA.bug_id} - ${BUGZILLA.bug_summary}`;
            const summaryHTML = `<a href="${url}">${summaryText.htmlEncode()}</a>`;

            const htmlData = {
                'text/plain': summaryText,
                'text/html': summaryHTML,
            };

            $('#copy-summary').click(() => {
                // We used to include `{ 'text/uri-list': url }` in the data, but not all browsers
                // support it with the Clipboard API. So we just copy the HTML and plain text.
                copy(htmlData, "bug summary");
            });

            $('#copy-markdown-summary').click(() => {
                copy(`[${summaryText}](${url})`, "markdown link with bug summary");
            });
            $('#copy-markdown-bug-number').click(() => {
                copy(`[${bugNumberText}](${url})`, "markdown link with bug number");
            });

            $('#copy-text-summary').click(() => {
                copy(summaryText, "bug summary");
            });

            $('#copy-html-summary').click(() => {
                copy(htmlData, "HTML link with bug summary");
            });
        }
        else {
            $('#copy-summary').hide();
            $('#copy-menu-dropdown').hide();
        }
    }

    // lightboxes
    $('.lightbox, .comment-text .lightbox + span:first-of-type a:first-of-type, .comment-text .lightbox + p span:first-of-type a:first-of-type')
        .click(function(event) {
            if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey)
                return;
            event.preventDefault();
            lb_show(this);
        });

    // action button actions

    // enable perm edit mode
    $('#action-enable-perm-edit')
        .click(function(event) {
            event.preventDefault();
            const enabled = $(this).attr('aria-checked') !== 'true';
            $(this).attr('aria-checked', enabled);
            Bugzilla.Storage.set('modal-perm-edit-mode', enabled);
        });

    // reset
    $('#action-reset')
        .click(function(event) {
            event.preventDefault();
            var visible = $(this).data('modules');
            $('.module-content').each(function() {
                var content = $(this);
                var moduleID = content.parent('.module').attr('id');
                var isDefault = $.inArray(moduleID, visible) !== -1;
                if (content.is(':visible') && !isDefault) {
                    slide_module($('#' + moduleID), 'hide');
                }
                else if (content.is(':hidden') && isDefault) {
                    slide_module($('#' + moduleID), 'show');
                }
            });
        })
        .data('modules', $('.module-content:visible').map(function() {
            return $(this).parent('.module').attr('id');
        }));

    // expand all modules
    $('#action-expand-all')
        .click(function(event) {
            event.preventDefault();
            $('.module-content:hidden').each(function() {
                slide_module($(this).parent('.module'));
            });
        });

    // collapse all modules
    $('#action-collapse-all')
        .click(function(event) {
            event.preventDefault();
            $('.module-content:visible').each(function() {
                slide_module($(this).parent('.module'));
            });
        });

    // add comment menuitem, scroll the textarea into view
    $('#action-add-comment, #add-comment-btn')
        .click(function(event) {
            event.preventDefault();
            // focus first to grow the textarea, so we scroll to the correct location
            $('#comment', '#changeform').focus();
            $.scrollTo($('#bottom-save-btn'));
        });

    // last comment menuitem
    $('#action-last-comment')
        .click(function(event) {
            event.preventDefault();
            var id = $('.comment:last')[0].parentNode.id;
            $.scrollTo(id);
        });

    // show bug history
    $('#action-history')
        .click(function(event) {
            event.preventDefault();
            window.open(`${BUGZILLA.config.basepath}show_activity.cgi?id=${BUGZILLA.bug_id}`, '_blank');
        });

    // use scrollTo for in-page activity links
    $('.activity-ref')
        .click(function(event) {
            event.preventDefault();
            $.scrollTo($(this).attr('href').substr(1));
        });

    // Update readable bug status
    var rbs = $("#readable-bug-status");
    var rbs_text = bugzillaReadableStatus.readable(rbs.data('readable-bug-status'));
    rbs.text(rbs_text);

    if (BUGZILLA.user.id === 0) return;

    //
    // anything after this point is only executed for logged in users
    //

    // dirty field tracking
    $('#changeform select').each(function() {
        const that = $(this);
        const id = that.attr('id');
        const dirty = $(`#${id}-dirty`);

        if (!dirty) return;

        // store the option that had the selected attribute when we
        // initially loaded
        var value = that.find('option[selected]').map(function() { return this.value; }).toArray();
        if (value.length === 0 && !that.attr('multiple'))
            value = that.find('option:first').map(function() { return this.value; }).toArray();
        that.data('preselected', value);

        // if the user hasn't touched a field, override the browser's choice
        // with Bugzilla's, unless it's the component field
        if (id !== 'component' && !dirty.val())
            that.val(value);
    });

    // edit/save mode button
    $('#mode-btn')
        .click(async event => {
            event.preventDefault();
            editMode = true;

            // hide buttons, old error messages
            $('#mode-btn-readonly').hide();

            // toggle visibility
            $('.edit-hide').hide();
            $('.edit-show').show();

            // expand specific modules during the initial edit
            if (!$('#editing').val())
                slide_module($('#module-details'), 'show');

            // if there's no current user-story, it's a better experience if it's editable by default
            if ($('#cf_user_story').val() === '') {
                $('#user-story-edit-btn').click();
            }

            // "loading.." ui
            $('#mode-btn-loading').show();
            $('#cancel-btn').prop('disabled', true);
            $('#mode-btn').prop('disabled', true);

            // load the missing select data
            try {
                const data = await Bugzilla.API.get(`bug_modal/edit/${BUGZILLA.bug_id}`);

                $('#io-error').empty().hide();
                $('#mode-btn').hide();

                // populate select menus
                for (const [key, value] of Object.entries(data.options)) {
                    const $select = document.querySelector(`#${key}`);
                    if (!$select) {
                        continue;
                    }
                    // It can be radio-button-like UI
                    const use_buttons = $select.matches('.buttons.toggle');
                    const is_required = $select.matches('[aria-required="true"]');
                    const selected = use_buttons ? $select.querySelector('input').value : $select.value;
                    $select.innerHTML = '';
                    for (const { name } of value) {
                        if (is_required && name === '--') {
                            continue;
                        }
                        if (use_buttons) {
                            $select.insertAdjacentHTML('beforeend', `
                              <div class="item">
                                <input id="${$select.id}_${name}_radio" type="radio" name="${$select.id}"
                                        value="${name}" ${name === selected ? 'checked' : ''}>
                                <label for="${$select.id}_${name}_radio">
                                ${$select.id === 'bug_type' ? `
                                  <span class="bug-type-label iconic-text" data-type="${name}">
                                    <span class="icon" aria-hidden="true"></span>${name}
                                  </span>
                                ` : `${name}`}
                                </label>
                              </div>
                            `);
                        } else {
                            $select.insertAdjacentHTML('beforeend', `
                              <option value="${name}" ${name === selected ? 'selected' : ''}>${name}</option>
                            `);
                        }
                    }
                    if ($select.matches('[multiple]') && value.length < 5) {
                        $select.size = value.length;
                    }
                }

                // build our product description hash
                for (const { name, description } of data.options.product) {
                    products[name] = description;
                }

                // keywords is a multi-value autocomplete
                keywords = data.keywords;
                initKeywordsAutocomplete(keywords);

                $('#cancel-btn').prop('disabled', false);
                $('#top-save-btn').show();
                $('#cancel-btn').show();
                $('#commit-btn').show();
            } catch ({ message }) {
                $('#io-error').html(message).show('fast');
                $('#mode-btn-readonly').show();
                $('#mode-btn-loading').hide();
                $('#mode-btn').prop('disabled', false);
                $('#mode-btn').show();
                $('#cancel-btn').hide();
                $('#commit-btn').hide();

                $('.edit-show').hide();
                $('.edit-hide').show();
            }
        });
    $('#mode-btn').prop('disabled', false);

    // disable the save buttons while posting
    $('.save-btn')
        .click(async function(event) {
            event.preventDefault();

            // Check if all the required fields are entered/selected.
            // This replaces the legacy `validateEnterBug()` function.
            const hasInvalidField = [...$form.querySelectorAll('[aria-required="true"]')]
                .map(($input) => {
                    let invalid = false;

                    if ($input.type === 'text') {
                        invalid = !$input.value.trim();
                    } else if ($input.type === 'select-one') {
                        invalid = $input.selectedIndex === -1;
                    } else if ($input.matches('[class="buttons toggle"]')) {
                        invalid = !$form[$input.id].value;
                    }

                    $input.setAttribute('aria-invalid', invalid);
                    document.getElementById($input.getAttribute('aria-errormessage'))?.classList
                        .toggle('bz_default_hidden', !invalid);

                    return invalid ? $input : undefined;
                })
                .some(($input) => {
                    // Focus on the first invalid field
                    if ($input) {
                        $input.scrollIntoView();
                        $input.focus();
                    }

                    return !!$input;
                });

            if (hasInvalidField || !$form.checkValidity())
                return;

            // unfortunately native html form validation doesn't support
            // patterns on selects, so we have to check for valid severities
            // manaully.
            if (
                BUGZILLA.user.can_triage
                && getKeywords().includes('triaged')
                && !hasGoodSeverity()
            ) {
                $('#bug_severity').addClass('attention');
                Bugzilla.Toast.show('Severity of S1-S4 is required to mark a bug as triaged.');
                return;
            }

            $('.save-btn').attr('disabled', true);

            if (editMode) {
                // Submit the form normally as the user has probably changed multiple fields
                $form.submit();
            } else {
                try {
                    // Try to do an instant update via the API
                    event.stopPropagation();
                    await instantUpdater.submit();
                    clearSavedBugComment();
                } catch (ex) {
                    console.error(ex);

                    if (ex.message === 'AFTER_SUBMIT_HALT') {
                        // The comment was posted successfully, but further processing is halted.
                        // Reload the page to show the updated bug.
                        clearSavedBugComment();
                        window.location.reload();
                    } else {
                        // Fallback to a full form submission
                        $form.submit();
                    }
                }
            }

            // remember expanded modules
            $('#editing').val(
                $('.module .module-content:visible')
                    .parent()
                    .map(function(el) { return $(this).attr('id'); })
                    .toArray()
                    .join(' ')
            );
        })
        .attr('disabled', false);

    // re-enable the save buttons when the user goes back to the page due to any
    // field error or mid-air collision
    $(window).on('pageshow', function() {
        $('.save-btn').attr('disabled', false);
    });

    // cc toggle (follow/stop following)
    $('#cc-btn')
        .click(async event => {
            event.preventDefault();
            var is_cced = $(event.target).data('is-cced') == '1';

            var cc_change;
            var cc_count = $('#cc-summary').data('count');
            if (is_cced) {
                cc_change = { remove: [ BUGZILLA.user.login ] };
                cc_count--;
                $('#cc-btn')
                    .text('Follow')
                    .data('is-cced', '0')
                    .prop('disabled', true);
            }
            else {
                cc_change = { add: [ BUGZILLA.user.login ] };
                cc_count++;
                $('#cc-btn')
                    .text('Stop Following')
                    .data('is-cced', '1')
                    .prop('disabled', true);
            }
            is_cced = !is_cced;

            // update visible count
            $('#cc-summary').data('count', cc_count);
            if (cc_count == 1) {
                $('#cc-summary').text(is_cced ? 'Just you' : '1 person');
            }
            else {
                $('#cc-summary').text(`${cc_count} people${is_cced ? ' including you' : ''}`);
            }

            // clear/update user list
            $('#cc-latch').data('fetched', false);
            if ($('#cc-latch').data('expanded'))
                ccListLoading();

            // show message
            Bugzilla.Toast.show(
              is_cced
                ? 'You are now following this bug'
                : 'You are no longer following this bug'
            );

            // show/hide "add me to the cc list"
            if (is_cced) {
                $('#add-self-cc-container').hide();
                $('#add-self-cc').attr('disabled', true);
            }
            else {
                $('#add-self-cc-container').show();
                $('#add-self-cc').attr('disabled', false);
            }

            try {
                const { bugs } = await Bugzilla.API.put(`bug/${BUGZILLA.bug_id}`, { cc: cc_change });
                const { changes } = bugs[0];

                $('#io-error').empty().hide();
                $('#cc-btn').prop('disabled', false);

                if (!(changes && changes.cc)) {
                    return;
                }

                if (changes.cc.added == BUGZILLA.user.login) {
                    $('#cc-btn').text('Stop Following').data('is-cced', '1');
                } else if (changes.cc.removed == BUGZILLA.user.login) {
                    $('#cc-btn').text('Follow').data('is-cced', '0');
                }

                if ($('#cc-latch').data('expanded')) {
                    ccListUpdate();
                }
            } catch ({ message }) {
                $('#io-error').html(message).show('fast');
                $('#cc-btn').prop('disabled', false);

                if ($('#cc-latch').data('expanded')) {
                    ccListUpdate();
                }
            }
        });

    // bug reminder button
    $('#reminder-btn')
        .click(event => {
            event.preventDefault();
            const is_reminded = $(event.target).data('is-reminded') == '1';
            const has_needinfo_from = $(event.target).data('has-needinfo-from');
            let query_string = "tab=reminders";
            if (!is_reminded) {
                query_string += `&bug_id=${BUGZILLA.bug_id}`;
            }
            if (has_needinfo_from) {
                query_string += `&note=Needinfo+requested+by+${encodeURIComponent(has_needinfo_from)}`;
            }
            window.location = `${BUGZILLA.config.basepath}userprefs.cgi?${query_string}`;
        });

    // cancel button, reset the ui back to read-only state
    // for now, do this with a redirect to self
    // ideally this should revert all field back to their initially loaded
    // values and switch the ui back to read-only mode without the redirect
    $('#cancel-btn')
        .click(function(event) {
            event.preventDefault();
            window.location.replace(`${BUGZILLA.config.basepath}show_bug.cgi?id=${BUGZILLA.bug_id}`);
        });

    // Open help page
    $('#help-btn')
        .click(function(event) {
            event.preventDefault();
            window.open("https://wiki.mozilla.org/BMO/UserGuide", "_blank");
        });

    // needinfo in people section -> scroll to near-comment ui
    $('#needinfo-scroll')
        .click(function(event) {
            event.preventDefault();
            $.scrollTo($('#needinfo_container'), function() { $('#needinfo_role', '#needinfo_container').focus(); });
        });

    // knob
    $('#bug_status, #bottom-bug_status')
        .change(function(event) {
            var that = $(this);
            var val = that.val();
            var other = $(that.attr('id') == 'bug_status' ? '#bottom-bug_status' : '#bug_status');
            other.val(val);
            if (val == "RESOLVED" || val == "VERIFIED") {
                $('#resolution, #bottom-resolution').change().show();
                $('#duplicate-actions').hide();
            }
            else {
                $('#resolution, #bottom-resolution').hide();
                $('#duplicate-container, #bottom-duplicate-container').hide();
                $('#mark-as-dup-btn, #bottom-mark-as-dup-btn').show();
                $('#duplicate-actions').show();
            }
        })
        .change();
    $('#resolution, #bottom-resolution')
        .change(function(event) {
            var that = $(this);
            var val = that.val();
            var other = $(that.attr('id') == 'resolution' ? '#bottom-resolution' : '#resolution');
            other.val(val);
            var bug_status = $('#bug_status').val();
            if ((bug_status == "RESOLVED" || bug_status == "VERIFIED") && val == "DUPLICATE") {
                $('#duplicate-container, #bottom-duplicate-container').show();
                $('#mark-as-dup-btn, #bottom-mark-as-dup-btn').hide();
                if (that.attr('id') == 'resolution') {
                    if ($("#dup_id").is(":visible")) {
                        $('#dup_id').focus();
                    }
                } else {
                    if ($("#bottom-dup_id").is(":visible")) {
                        $('#bottom-dup_id').focus();
                        window.setTimeout(() => { $('#bottom-dup_id')[0].scrollIntoView() }, 0);
                    }
                }
            }
            else {
                $('#duplicate-container, #bottom-duplicate-container').hide();
                $('#mark-as-dup-btn, #bottom-mark-as-dup-btn').show();
            }
        })
        .change();
    $('#mark-as-dup-btn, #bottom-mark-as-dup-btn')
        .click(function(event) {
            event.preventDefault();
            $('#bug_status').val('RESOLVED').change();
            $('#resolution').val('DUPLICATE').change();
            if ($(this).attr('id') == 'mark-as-dup-btn') {
                if ($("#dup_id").is(":visible")) {
                    $('#dup_id').focus();
                }
            } else {
                if ($("#bottom-dup_id").is(":visible")) {
                    $('#bottom-dup_id').focus();
                    window.setTimeout(() => { $('#bottom-dup_id')[0].scrollIntoView() }, 0);
                }
            }
        });
    $('#dup_id, #bottom-dup_id')
        .change(function(event) {
            var that = $(this);
            var other = $(that.attr('id') == 'dup_id' ? '#bottom-dup_id' : '#dup_id');
            other.val(that.val());
        });

    // bug flag value <select>
    $('.bug-flag')
        .change(function(event) {
            var target = $(event.target);
            var id = target.prop('id').replace(/^flag(_type)?-(\d+)/, "#requestee$1-$2");
            if (target.val() == '?') {
                $(id + '-container').show().removeClass('bz_default_hidden');
                $(id).focus().select().prop('required', true);
            }
            else {
                $(id + '-container').hide().addClass('bz_default_hidden');
                $(id).prop('required', false);
            }
        });

    // tracking flags
    $('.tracking-flags select')
        .change(function(event) {
            tracking_flag_change(event.target);
        });

    // take button
    $('.take-btn')
        .click(function(event) {
            event.preventDefault();
            $('#field-status-view').hide();
            $('#field-status-edit').show();
            if (
                !!$('#bug_status option').filter(function() { return $(this).val() == 'ASSIGNED'; }).length
                && $('#bug_status').val() !== 'ASSIGNED'
            ) {
                $('#assigned-container').show();
            }
            var field = $(this).data('field');
            $('#field-' + field + '.edit-hide').hide();
            $('#field-' + field + '.edit-show').show();
            $('#' + field).val(BUGZILLA.user.login).focus().select();
            $('#top-save-btn').show();
            if ($('#set-default-assignee').is(':checked')) {
                $('#set-default-assignee').click();
            }
        });

    // mark as assigned
    $('#mark-as-assigned-btn')
        .click(function(event) {
            event.preventDefault();
            $('#bug_status').val('ASSIGNED').change().focus();
            $('#assigned-container').hide();
        });

    // reply button
    $('#changeform')
        .on('click', '.reply-btn', function(event) {
            event.preventDefault();
            var comment_id = $(event.target).data('id');
            var comment_no = $(event.target).data('no');
            var comment_author = $(event.target).data('reply-name');

            var prefix = "(In reply to " + comment_author + " from comment #" + comment_no + ")\n";
            var reply_text = "";

            var quoteMarkdown = async $comment => {
                const uid = $comment.data('comment-id');

                try {
                    const { comments } = await Bugzilla.API.get(`bug/comment/${uid}`, { include_fields: 'text' });
                    const quoted = comments[uid]['text'].replace(/\n/g, '\n> ');

                    reply_text = `${prefix}> ${quoted}\n\n`;
                    populateNewComment();
                } catch (ex) {}
            }

            var populateNewComment = function() {
                // quoting a private comment, check the 'private' cb
                $('#add-comment-private-cb').prop('checked',
                    $('#add-comment-private-cb:checked').length || $('#is-private-' + comment_id + ':checked').length);

                // remove embedded links to attachment details
                reply_text = reply_text.replace(/(attachment\s+\d+)(\s+\[[^\[\n]+\])+/gi, '$1');

                $.scrollTo($('#comment', '#changeform'), function() {
                    if ($('#comment', '#changeform').val() != reply_text) {
                        $('#comment', '#changeform').val($('#comment', '#changeform').val() + reply_text);
                    }

                    if (BUGZILLA.user.settings.autosize_comments) {
                        autosize.update($('#comment', '#changeform'));
                    }

                    $('#comment', '#changeform').trigger('input').focus();
                });
            }

            if (BUGZILLA.user.settings.quote_replies == 'quoted_reply') {
                var $comment = $('#ct-' + comment_no);
                if ($comment.is('.markdown-body')) {
                    quoteMarkdown($comment);
                } else {
                    reply_text = prefix + wrapReplyText($comment.text());
                    populateNewComment();
                }
            } else if (BUGZILLA.user.settings.quote_replies == 'simply_reply') {
                reply_text = prefix;
                populateNewComment();
            }
        });

    if (BUGZILLA.user.settings.autosize_comments) {
        $('#comment', '#changeform').addClass('autosized-comment');
        autosize($('#comment', '#changeform'));
    } else if (BUGZILLA.user.settings.zoom_textareas) {
        // add comment --> enlarge on focus
        $('#comment', '#changeform').focus(function(event) {
            $(event.target).attr('rows', 15);
        });
    }

    // add comment --> private
    $('#add-comment-private-cb')
        .click(function(event) {
            if ($(event.target).prop('checked')) {
                $('#comment', '#changeform').addClass('private-comment');
            }
            else {
                $('#comment', '#changeform').removeClass('private-comment');
            }
        });

    // show "save changes" button if there are any immediately editable elements
    if ($('.module select:visible').length || $('.module input:visible').length) {
        $('#top-save-btn').show();
    }

    // status/resolve as buttons
    $('.resolution-btn')
        .click(function(event) {
            event.preventDefault();
            $('#field-status-view').hide();
            $('#field-status-edit').show();
            $('#field-status-edit .name').show();
            $('#bug_status').val('RESOLVED').change();
            $('#bottom-resolution').val($(event.target).text()).change();
            $('#top-save-btn').show();
            $('#resolve-as').hide();
            $('#close-as-invalid-btn').hide();
            $('#bottom-status').show();
            if ($('#bottom-dup_id').is(":visible")) {
                $('#bottom-dup_id').focus();
                window.setTimeout(() => { $('#bottom-dup_id')[0].scrollIntoView() }, 0);
            }
        });
    $('.status-btn')
        .click(function(event) {
            event.preventDefault();
            $('#field-status-view').hide();
            $('#field-status-edit').show();
            $('#bug_status').val($(event.target).data('status')).change();
            $('#top-save-btn').show();
            $('#resolve-as').hide();
            $('#close-as-invalid-btn').hide();
            $('#bottom-status').show();
            if ($('#bottom-dup_id').is(":visible")) {
                $('#bottom-dup_id').focus();
                window.setTimeout(() => { $('#bottom-dup_id')[0].scrollIntoView() }, 0);
            }
        });

    // vote button
    // ideally this should function like CC and xhr it, but that would require
    // a rewrite of the voting extension
    $('#vote-btn')
        .click(function(event) {
            event.preventDefault();
            window.location.href = `${BUGZILLA.config.basepath}page.cgi?` +
                                   `id=voting/user.html&bug_id=${BUGZILLA.bug_id}#vote_${BUGZILLA.bug_id}`;
        });

    // user-story
    $('#user-story-edit-btn')
        .click(function(event) {
            event.preventDefault();
            $('#user-story').hide();
            $('#user-story-edit-btn').hide();
            $('#top-save-btn').show();
            $('#cf_user_story').show();
            // don't focus the user-story field when restoring edit mode after navigation
            if ($('#editing').val() === '')
                $('#cf_user_story').focus().select();
        });
    $('#user-story-reply-btn')
        .click(function(event) {
            event.preventDefault();
            var text = "(Commenting on User Story)\n" + wrapReplyText($('#user-story-reply-btn').data('user-story'));
            var current = $('#comment', '#changeform').val();
            if (current != text) {
                $('#comment', '#changeform').val(current + text);
                $('#comment', '#changeform').focus();
                $.scrollTo($('#bottom-save-btn'));
            }
        });

    // cab review 'gate'
    $('#cab-review-gate-close')
        .click(function(event) {
            event.preventDefault();
            $('#cab-review-gate').hide();
            $('#cab-review-edit').show();
        });

    // custom textarea fields
    $('.edit-textarea-btn')
        .click(function(event) {
            event.preventDefault();
            var id = $(event.target).attr('id').replace(/-edit$/, '');
            $(event.target).hide();
            $('#' + id + '-view').hide();
            $('#' + id).show().focus().select();
        });

    // timetracking
    $('#work_time').change(function() {
        // subtracts time spent from remaining time
        // prevent negative values if work_time > fRemainingTime
        var new_time = Math.max(BUGZILLA.remaining_time - $('#work_time').val(), 0.0);
        // get up to 2 decimal places
        $('#remaining_time').val(Math.round((new_time * 100)/100).toFixed(1));
    });
    $('#remaining_time').change(function() {
        // if the remaining time is changed manually, update BUGZILLA.remaining_time
        BUGZILLA.remaining_time = $('#remaining_time').val();
    });

    // "reset to default" checkboxes
    $('#product, #component')
        .change(function(event) {
            $('.set-default-container').show();
            $('#set-default-assignee').prop('checked', $('#assigned_to').val() == BUGZILLA.default_assignee).change();
            $('#set-default-qa-contact').prop('checked', $('#qa_contact').val() == BUGZILLA.default_qa_contact).change();

            // Show the People module only when the product/component is changed manually
            if (!event.isTrigger) {
                slide_module($('#module-people'), 'show');
            }
        });
    $('.set-default')
        .change(function(event) {
            var cb = $(event.target);
            var input = $('#' + cb.data('for'));
            input.attr('disabled', cb.prop('checked'));
        })
        .change();

    // hotkeys
    $(window)
        .keydown(function(event) {
            if (!(event.ctrlKey || event.metaKey))
                return;
            switch(String.fromCharCode(event.which).toLowerCase()) {
                // ctrl+e or meta+e = enter edit mode
                case 'e':
                    if (event.shiftKey)
                        return;
                    // don't conflict with text input shortcut
                    if (document.activeElement.nodeName == 'INPUT' || document.activeElement.nodeName == 'TEXTAREA')
                        return;
                    if ($('#cancel-btn:visible').length === 0) {
                        event.preventDefault();
                        $('#mode-btn').click();
                    }
                    break;
            }
        });

    // add cc button
    $('#add-cc-btn')
        .click(function(event) {
            event.preventDefault();
            $('#add-cc-btn').hide();
            $('#add-cc-container').show();
            $('#top-save-btn').show();
            $('#add-cc').focus();
        });

    // 'mark as triaged' button
    function getKeywords(value) {
        if (value == undefined) value = document.getElementById('keywords')?.value || '';
        return value
            .split(',')
            .map((v) => v.trim())
            .filter((v) => v !== '');
    }

    function setKeywords(keywords) {
        document.getElementById('keywords').value = keywords.join(', ');
        $('#keywords').blur();
    }

    // Track if this bug initially has the triaged keyword.  This allows the
    // severity to be cleared without requiring the triaged keyword to be
    // removed, because we know the bug has been triaged at least once.
    // We use BUGZILLA.bug_keywords instead of the keywords form element as
    // we need the value from the database, not one that might have been
    // restored by the browser
    const initiallyTriaged = getKeywords(BUGZILLA.bug_keywords).includes('triaged');

    function hasGoodSeverity() {
        if (initiallyTriaged) return true;

        // check the severity is S{digit}
        const $severity = document.querySelector('#bug_severity');
        const severity = $severity ? $severity.value : BUGZILLA.bug_severity;
        return /^S\d+$/.test(severity);
    }

    $('#mark-as-triaged-btn')
        .click(function(event) {
            event.preventDefault();
            let keywords = getKeywords();
            if (!keywords.includes('triaged')) {
                keywords.push('triaged');
                setKeywords(keywords);
            }
        });
    $('#keywords, #bug_severity')
        .blur(function() {
            if (!BUGZILLA.user.can_triage) return;
            const has_triaged = getKeywords().includes('triaged');
            // disable "mark as triaged" button if the triaged keyword is present
            $('#mark-as-triaged-btn').prop('disabled', has_triaged);
            // hide/show 'untriaged' status badge in summary module
            $('.bug-status-label[data-status="untriaged"]').toggle(!has_triaged);
            // draw attention to the severity field if required
            if ($("#bug_severity").length) {
                if (has_triaged && !hasGoodSeverity()) {
                    $('#bug_severity').addClass('attention');
                } else {
                    $('#bug_severity').removeClass('attention');
                }
            }
        });
    $('#keywords').blur();

    // Add user to cc list if they mark the bug as security sensitive
    $('.restrict_sensitive')
        .change(function(event) {
            $('#add-self-cc:not(:checked)').attr('checked', true);
        });

    // product change --> load components, versions, milestones, groups
    $('#product').data('default', $('#product').val());
    $('#component, #version, #target_milestone').each(function() {
        $(this).data('default', $(this).val());
    });
    $('#product')
        .change(async event => {
            $('#product-throbber').show();
            $('#component, #version, #target_milestone').attr('disabled', true);

            slide_module($('#module-tracking'), 'show');

            $.each($('input[name=groups]'), function() {
                if (this.checked) {
                    slide_module($('#module-security'), 'show');
                    return false;
                }
            });

            try {
                const product = $('#product').val();
                const data = await Bugzilla.API.get(`bug_modal/new_product/${BUGZILLA.bug_id}`, { product });

                $('#io-error').empty().hide();
                $('#product-throbber').hide();
                $('#component, #version, #target_milestone').attr('disabled', false);
                var is_default = $('#product').val() == $('#product').data('default');

                // populate selects
                $.each(data, function(key, value) {
                    if (key == 'groups') return;
                    var el = $('#' + key);
                    if (!el) return;
                    el.empty();
                    var selected = el.data('preselect');
                    $(value).each(function(i, v) {
                        el.append($('<option>', { value: v.name, text: v.name }));
                        if (typeof selected === 'undefined' && v.selected)
                            selected = v.name;
                    });
                    el.val(selected);
                    el.prop('required', true);
                    if (is_default) {
                        el.removeClass('attention');
                        el.val(el.data('default'));
                    }
                    else {
                        el.addClass('attention');
                    }
                });

                // update groups
                var dirtyGroups = [];
                var any_groups_checked = 0;
                $('#module-security').find('input[name=groups]').each(function() {
                    var that = $(this);
                    var defaultChecked = !!that.attr('checked');
                    if (defaultChecked !== that.is(':checked')) {
                        dirtyGroups.push({ name: that.val(), value: that.is(':checked') });
                    }
                    if (that.is(':checked')) {
                        any_groups_checked = 1;
                    }
                });
                $('#module-security .module-content')
                    .html(data.groups)
                    .addClass('attention');
                $.each(dirtyGroups, function() {
                    $('#module-security').find('input[value=' + this.name + ']').prop('checked', this.value);
                });
                // clear any default groups if user was making bug public
                // unless the group is mandatory for the new product
                if (!any_groups_checked) {
                    $('#module-security').find('input[name=groups]').each(function() {
                        var that = $(this);
                        if (!that.data('mandatory')) {
                            that.prop('checked', false);
                        }
                    });
                }
            } catch ({ message }) {
                $('#io-error').html(message).show('fast');
                $('#product-throbber').hide();
                $('#component, #version, #target_milestone').attr('disabled', false);
            }
        });

    // product/component search
    $('#product-search')
        .click(function(event) {
            event.preventDefault();
            $('#product').hide();
            $('#product-search').hide();
            $('#product-search-cancel').show();
            $('.pcs-form').show();
            $('#pcs').val('').focus();
        });
    $('#product-search-cancel')
        .click(function(event) {
            event.preventDefault();
            $('#product-search-error').hide();
            $('.pcs-form').hide();
            $('#product').show();
            $('#product-search-cancel').hide();
            $('#product-search').show();
        });
    $('#pcs')
        .devbridgeAutocomplete('setOptions', {
            onSelect: function(suggestion) {
                $('#product-search-error').hide();
                $('.pcs-form').hide();
                $('#product-search-cancel').hide();
                $('#product-search').show();
                if ($('#product').val() != suggestion.data.product) {
                    $('#component').data('preselect', suggestion.data.component);
                    $('#product').val(suggestion.data.product).change();
                }
                else {
                    $('#component').val(suggestion.data.component);
                }
                $('#product').show();
            }
        });
    $(document)
        .on('pcs:search', function(event) {
            $('#product-search-error').hide();
        })
        .on('pcs:results', function(event) {
            $('#product-search-error').hide();
        })
        .on('pcs:no_results', function(event) {
            $('#product-search-error')
                .prop('title', 'No components found')
                .show();
        })
        .on('pcs:too_many_results', function(event, el) {
            $('#product-search-error')
                .prop('title', 'Results limited to ' + el.data('max_results') + ' components')
                .show();
        })
        .on('pcs:error', function(event, message) {
            $('#product-search-error')
                .prop('title', message)
                .show();
        });

    // dirty field tracking
    $('#changeform select')
        .change(function() {
            var that = $(this);
            var dirty = $('#' + that.attr('id') + '-dirty');
            if (!dirty) return;
            if (that.attr('multiple')) {
                var preselected = that.data('preselected');
                var selected = that.val();
                var isDirty = preselected.length != selected.length;
                if (!isDirty) {
                    for (var i = 0, l = preselected.length; i < l; i++) {
                        if (selected[i] != preselected[i]) {
                            isDirty = true;
                            break;
                        }
                    }
                }
                dirty.val(isDirty ? '1' : '');
            }
            else {
                dirty.val(that.val() === that.data('preselected')[0] ? '' : '1');
            }
        });

    // Save comments in progress
    $('#comment', '#changeform')
        .on('input', function(event) {
            saveBugComment(event.target.value);
        });

    const { bug_id: bugId } = BUGZILLA;
    const attachmentInputIds = ['att-file', 'att-data', 'att-textarea', 'att-description'];
    const comment = document.querySelector('#comment', '#add-comment');

    if (comment.classList.contains('attach-long-paste')) {
      // Convert long paste into an attachment
      comment.addEventListener('paste', async event => {
        const text = event.clipboardData.getData('text');
        const lines = text.split(/(?:\r\n|\r|\n)/).length;

        if (lines < 50) {
          return;
        }

        const extract = text.replace(/(?:\r\n|\r|\n)/, ' ').trim().substr(0, 20);
        const message = `You’re pasting ${lines} lines of text starting with “${extract}”.`;

        if (isNewBug && attachmentInputIds.some(id => !!document.getElementById(id).value)) {
          // We can’t attach because there are already attachments being added
          const confirmed = window.confirm(
            `${message} However, there is already a file being attached to this bug, so the pasted text can’t be ` +
            `uploaded as an attachment. Click OK and attach it as a file after submitting the bug, or click Cancel ` +
            `to paste it anyway.`
          );

          if (confirmed) {
            event.preventDefault();
          }

          return;
        }

        const summary = (window.prompt(
          `${message} Enter the summary below to upload it as an attachment, or click Cancel to paste it anyway.`
        ) || '').trim();

        if (!summary) {
          return;
        }

        event.preventDefault();

        if (isNewBug) {
          // Expand the attachment module
          document.querySelector('#attach-new-file').click();
          // Fill in the attachment fields in the new bug form
          document.querySelector('#att-textarea').value = text;
          document.querySelector('#att-description').value = summary;

          return;
        }

        try {
          await Bugzilla.API.post(`bug/${bugId}/attachment`, {
            // https://developer.mozilla.org/en-US/docs/Web/API/WindowBase64/Base64_encoding_and_decoding
            data: btoa(encodeURIComponent(text).replace(/%([0-9A-F]{2})/g, (m, p1) => String.fromCharCode(`0x${p1}`))),
            file_name: 'pasted.txt',
            summary,
            content_type: 'text/plain',
          });

          // Reload the page once upload is complete
          location.replace(`${BUGZILLA.config.basepath}show_bug.cgi?id=${bugId}`);
        } catch ({ message }) {
          window.alert(`Couldn’t upload the text as an attachment. Please try again later. Error: ${message}`);
        }
      });
    }

    restoreEditMode();
    restoreSavedBugComment();
    initDependencyTree();
});

function confirmUnsafeURL(url) {
    return confirm(
        'This is considered an unsafe URL and could possibly be harmful.\n' +
        'The full URL is:\n\n' + url + '\n\nContinue?');
}

async function show_new_changes_indicator() {
    const url = `bug_user_last_visit/${BUGZILLA.bug_id}`;

    try {
        // Get the last visited timestamp
        const data = await Bugzilla.API.get(url);

        // Save the current timestamp
        Bugzilla.API.post(url);

        if (!data[0] || !data[0].last_visit_ts) {
            return;
        }

        const last_visit_ts = new Date(data[0].last_visit_ts);
        const new_changes = [...document.querySelectorAll('main .change-set')].filter($change => {
            // Exclude hidden CC changes and the user's own changes
            return $change.clientHeight > 0 &&
                Number($change.querySelector('.email').getAttribute('data-user-id')) !== BUGZILLA.user.id &&
                new Date($change.querySelector('[data-time]').getAttribute('data-time') * 1000) > last_visit_ts;
        });

        if (new_changes.length === 0) {
            return;
        }

        const now = new Date();
        const date_locale = document.querySelector('html').lang;
        const date_options = {
            year: 'numeric',
            month: 'long',
            day: 'numeric',
            hour: 'numeric',
            minute: 'numeric',
            hour12: false,
            timeZone: BUGZILLA.user.timezone,
            timeZoneName: 'short',
        };

        if (last_visit_ts.getFullYear() === now.getFullYear()) {
            delete date_options.year;

            if (last_visit_ts.getMonth() === now.getMonth() && last_visit_ts.getDate() === now.getDate()) {
                delete date_options.month;
                delete date_options.day;
            }
        }

        const $link = document.createElement('div');
        const $separator = document.createElement('div');
        const comments_count = new_changes.filter($change => !!$change.querySelector('.comment')).length;
        const changes_count = new_changes.length - comments_count;
        const date_attr = last_visit_ts.toISOString();
        const date_label = last_visit_ts.toLocaleString(date_locale, date_options);

        // Insert a link
        $link.className = 'new-changes-link';
        $link.innerHTML =
            (c => c === 0 ? '' : (c === 1 ? `${c} new comment` : `${c} new comments`))(comments_count) +
            (comments_count > 0 && changes_count > 0 ? ', ' : '') +
            (c => c === 0 ? '' : (c === 1 ? `${c} new change` : `${c} new changes`))(changes_count) +
            ` since <time datetime="${date_attr}">${date_label}</time>`;
        $link.addEventListener('click', () => {
            $link.remove();
            $.scrollTo($separator);
        }, { once: true });
        document.querySelector('#bugzilla-body').insertAdjacentElement('beforebegin', $link);

        // Insert a separator
        $separator.className = 'new-changes-separator';
        $separator.innerHTML = '<span>New</span>';
        new_changes[0].insertAdjacentElement('beforebegin', $separator);

        // Remove the link once the separator goes into the viewport
        if ('IntersectionObserver' in window) {
            const observer = new IntersectionObserver(entries => entries.forEach(entry => {
                if (entry.intersectionRatio > 0) {
                    observer.unobserve($separator);
                    $link.addEventListener('transitionend', () => $link.remove(), { once: true });
                    $link.hidden = true;
                }
            }));

            observer.observe($separator);
        }
    } catch (ex) {}
}

// fix URL after bug creation/update
if (history && history.replaceState) {
    var href = document.location.href;
    if (!href.match(/(?:show|enter)_bug\.cgi/)) {
        history.replaceState(null, BUGZILLA.bug_title, `${BUGZILLA.config.basepath}show_bug.cgi?id=${BUGZILLA.bug_id}`);
        document.title = BUGZILLA.bug_title;
    }
    if (href.match(/show_bug\.cgi\?.*list_id=/)) {
        href = href.replace(/[\?&]+list_id=(\d+|cookie)/, '');
        history.replaceState(null, BUGZILLA.bug_title, href);
    }
}

// lightbox

function lb_show(el) {
    $(window).trigger('close');
    $(document).bind('keyup.lb', function(event) {
        if (event.keyCode == 27) {
            lb_close(event);
        }
    });
    $('html').addClass('no-scroll');
    var overlay = $('<div>')
        .prop('id', 'lb_overlay')
        .css({ opacity: 0 })
        .appendTo('body');
    var overlay2 = $('<div>')
        .prop('id', 'lb_overlay2')
        .css({ top: $(window).scrollTop() + $('#header').height() })
        .appendTo('body');
    var text_container = $('<div>')
        .prop('id', 'lb_text_container')
        .appendTo(overlay2);
    var title = $('<div>')
        .prop('id', 'lb_text')
        .appendTo(text_container);
    var img = $('<img>')
        .prop('id', 'lb_img')
        .prop('src', el.href)
        .prop('alt', 'Loading...')
        .css({ opacity: 0 })
        .appendTo(overlay2)
        .click(function(event) {
            event.stopPropagation();
            window.location.href = el.href;
        });
    var close_btn = $('<button>')
        .prop('id', 'lb_close_btn')
        .prop('type', 'button')
        .addClass('minor')
        .text('Close')
        .appendTo(text_container);
    title.text(el.title);
    overlay.add(overlay2).click(lb_close);
    img.add(overlay).animate({ opacity: 1 }, 200);
}

function lb_close(event) {
    event.preventDefault();
    $(document).unbind('keyup.lb');
    $('#lb_overlay, #lb_overlay2, #lb_close_btn, #lb_img, #lb_text').remove();
    $('html').removeClass('no-scroll');
}

$(function() {
    $("button.button-link").on("click", function (event) {
        event.preventDefault();
        window.location = $(this).data("href");
    });
});

// extensions

(function($) {
    $.extend({
        // Case insensitive $.inArray (http://api.jquery.com/jquery.inarray/)
        // $.inArrayIn(value, array [, fromIndex])
        //  value (type: String)
        //    The value to search for
        //  array (type: Array)
        //    An array through which to search.
        //  fromIndex (type: Number)
        //    The index of the array at which to begin the search.
        //    The default is 0, which will search the whole array.
        inArrayIn: function(elem, arr, i) {
            // not looking for a string anyways, use default method
            if (typeof elem !== 'string') {
                return $.inArray.apply(this, arguments);
            }
            // confirm array is populated
            if (arr) {
                var len = arr.length;
                i = i ? (i < 0 ? Math.max(0, len + i) : i) : 0;
                elem = elem.toLowerCase();
                for (; i < len; i++) {
                    if (i in arr && arr[i].toLowerCase() == elem) {
                        return i;
                    }
                }
            }
            // stick with inArray/indexOf and return -1 on no match
            return -1;
        },

        // Bring an element into view, leaving space for the outline. If passed
        // a string, it will be treated as an id - the page will scroll and the
        // URL will be added to the browser's history. If passed an element, no
        // entry will be added to the history.
        scrollTo: function(target, complete) {
            let $target;

            if (typeof target === 'string') {
                $target = document.getElementById(target);
                window.location.hash = $target;
            } else if (typeof target.get === 'function') {
                // Use native DOM element instead of jQuery
                $target = target.get(0);
            } else {
                $target = target;
            }

            if ($target) {
                scroll_element_into_view($target, complete);
            }
        }

    });
})(jQuery);
