/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * This Source Code Form is "Incompatible With Secondary Licenses", as
 * defined by the Mozilla Public License, v. 2.0. */

window.addEventListener('DOMContentLoaded', () => {
  /** @type {HTMLDialogElement} */
  const $overlay = document.querySelector('#att-overlay');

  // The overlay is available only on bugs with any attachment
  if (!$overlay) {
    return;
  }

  /** @type {HTMLFormElement} */
  const $form = $overlay.querySelector('form');
  /** @type {HTMLHeadingElement} */
  const $title = $overlay.querySelector('.header .title');
  /** @type {HTMLButtonElement} */
  const $prevButton = $overlay.querySelector('button[data-action="prev"]');
  /** @type {HTMLButtonElement} */
  const $nextButton = $overlay.querySelector('button[data-action="next"]');
  /** @type {HTMLButtonElement} */
  const $toggleDetailsButton = $overlay.querySelector('button[data-action="toggle-details"]');
  /** @type {HTMLButtonElement} */
  const $closeButton = $overlay.querySelector('button[data-action="close"]');
  /** @type {HTMLButtonElement} */
  const $rawButton = $overlay.querySelector('button[data-action="raw"]');
  /** @type {HTMLButtonElement | null} Available only when the patch viewer is used */
  const $diffButton = $overlay.querySelector('button[data-action="diff"]');
  /** @type {HTMLButtonElement | null} Available only when the Splinter extension is used */
  const $reviewButton = $overlay.querySelector('button[data-action="review"]');
  /** @type {HTMLButtonElement | null} Available only for admins */
  const $deleteButton = $overlay.querySelector('button[data-action="delete"]');
  /** @type {HTMLButtonElement | null} Available only for signed-in users */
  const $saveButton = $overlay.querySelector('input[type="submit"]');
  /** @type {HTMLElement | null} Available only for signed-in users */
  const $status = $overlay.querySelector('.status');
  /** @type {HTMLElement} */
  const $preview = $overlay.querySelector('.preview');
  /** @type {HTMLElement} */
  const $subColumn = $overlay.querySelector('.sub-column');
  /** @type {HTMLElement | null} Available only for signed-in users */
  const $commentPane = $overlay.querySelector('.comment-pane');
  /** @type {HTMLAnchorElement} */
  const $creator = $overlay.querySelector('.creator .email');
  /** @type {HTMLElement | null} Available only for signed-in users */
  const $creatorName = $creator.querySelector('.fn');
  /** @type {HTMLElement} */
  const $createdDate = $form.querySelector('.created-date');
  /** @type {HTMLElement} */
  const $updatedDate = $form.querySelector('.updated-date');
  /** @type {HTMLElement} */
  const $fileSize = $form.querySelector('.file-size');

  const {
    bug_id: bugId,
    config: { basepath },
  } = /** @type {any} */ (BUGZILLA);
  const tokens = $form.token
    ? Object.fromEntries(JSON.parse($form.token.dataset.tokens))
    : {};
  const cgiPath = `${basepath}attachment.cgi`;
  const previewDisabled = $preview.matches('.disabled');

  const textTypeMap = {
    'text/x-github-pull-request': 'GitHub Pull Request',
    'text/x-phabricator-request': 'Phabricator Request',
    'text/x-review-board-request': 'Review Board Request',
    'text/x-google-doc': 'Google Doc',
  };

  let bugAttachments = [];
  let bugAttachmentsIndex = 0;
  let attachmentId = 0;
  let currentAttachment = {};
  let initialFormData = {};

  /**
   * Initialize the {@link $overlay} to handle some events.
   */
  const initOverlay = () => {
    // Enable keyboard navigation using arrow keys
    $overlay.addEventListener('keydown', (event) => {
      const { target, key } = event;

      if (/** @type {HTMLElement} */ (target).matches('input, select, textarea:not(:read-only)')) {
        return;
      }

      if (key === 'ArrowLeft') {
        event.preventDefault();
        showPreviousAttachment();
      }

      if (key === 'ArrowRight') {
        event.preventDefault();
        showNextAttachment();
      }
    });

    // Prevent the dialog from being closed with the Escape key if there are any changes
    $overlay.addEventListener('cancel', (event) => {
      if (getChanges()) {
        event.preventDefault();
      }
    });

    $overlay.addEventListener('close', () => {
      document.body.style.removeProperty('overflow');
    });
  };

  /**
   * Initialize the action buttons on the header/footer.
   */
  const initActions = () => {
    $prevButton.addEventListener('click', () => {
      showPreviousAttachment();
    });

    $nextButton.addEventListener('click', () => {
      showNextAttachment();
    });

    $toggleDetailsButton.addEventListener('click', () => {
      toggleDetails();
    });

    $closeButton.addEventListener('click', () => {
      $overlay.close();
    });

    $rawButton.addEventListener('click', () => {
      window.location.href = `${currentAttachment.link}`;
    });

    $diffButton?.addEventListener('click', () => {
      window.location.href = `${currentAttachment.link}&action=diff`;
    });

    $reviewButton?.addEventListener('click', () => {
      window.location.href = `${$reviewButton.dataset.base}&bug=${bugId}&attachment=${attachmentId}`;
    });

    $deleteButton?.addEventListener('click', () => {
      window.location.href = `${currentAttachment.link}&action=delete`;
    });

    $saveButton?.addEventListener('click', async (event) => {
      event.preventDefault();

      if (!$form.checkValidity()) {
        const errorFields = /** @type {HTMLElement[]} */ ([...$form.querySelectorAll(':invalid')]);
        const message =
          errorFields.length === 1
            ? 'There is an error in the form. Please fix it before continuing.'
            : 'There are errors in the form. Please fix them before continuing.';

        window.alert(message);
        errorFields[0].focus();

        return;
      }

      // Use the FlagTypeComment extension (`ftc.js`) to handle submission if needed
      if ($overlay.querySelector('#approval-request-fieldset-wrapper section.approval-request')) {
        $form.requestSubmit();
      } else if (await saveChanges()) {
        // It’s hard to dynamically update the Edit Bug page using the API after saving attachment
        // changes, so just reload the page. Note that `location.reload()` may cause the form
        // resubmission warning dialog to appear if the user has just logged into the bug page. Use
        // an alternative method to avoid the problem.
        location.replace(`${basepath}show_bug.cgi?id=${bugId}`);
      }
    });
  };

  /**
   * Initialize attachment links on the Edit Bug page to show the {@link $overlay}, instead of
   * navigating to the legacy, separate attachment page.
   */
  const initAttachmentLinks = () => {
    document.body
      .querySelectorAll('a[href*="attachment.cgi?id="]')
      .forEach((/** @type {HTMLAnchorElement} */ $link) => {
        const {
          dataset: { overlay: mode },
          search,
        } = $link;
        const { id: idStr, action } = Object.fromEntries(new URLSearchParams(search));
        const id = Number(idStr);

        // The attachment overlay doesn’t work well if the linked attachment is on another bug. In
        // such cases, just link to the legacy attachment page.
        if (!Object.keys(tokens).includes(idStr)) {
          return;
        }

        // Also, if the attachment `action` param is not `edit` and the lightbox display mode is not
        // specified, open the link directly.
        if (action !== 'edit' && !mode) {
          return;
        }

        $link.addEventListener('click', async (event) => {
          event.preventDefault();

          if (event.ctrlKey || event.metaKey) {
            if ($link.dataset.details) {
              // Details link
              // Open the bug page, not the legacy attachment page, in a new tab with Ctrl/Cmd+click.
              // The `attachment_id` URL param works as an overlay trigger. (See below)
              window.open(`${basepath}show_bug.cgi?id=${bugId}&attachment_id=${id}`);
            } else {
              // Open the attachment directly
              window.open($link.href);
            }
          } else {
            showOverlay();
            loadAttachment(id, mode);
          }
        });

        // When an attachment link is opened in a new tab, retrieve the ID from the URL param, show
        // the overlay, and load the attachment immediately
        if (Number(new URLSearchParams(window.location.search).get('attachment_id')) === id) {
          showOverlay()
          loadAttachment(id);
          // Remove the URL param
          history.replaceState(null, '', `${basepath}show_bug.cgi?id=${bugId}`)
        }
      });
  };

  /**
   * Initialize the detail pane.
   */
  const initDetails = () => {
    if ($form.contenttypemethod) {
      [...$form.contenttypemethod].forEach(($radio) => {
        $radio.addEventListener('change', () => {
          onContentTypeSelectorChange();
        });
      });
    }

    $form.contenttypeselection?.addEventListener('change', () => {
      $form.contenttypeentry.value = $form.contenttypeselection.value;
    });
  };

  /**
   * Show the previous attachment on the bug if possible.
   */
  const showPreviousAttachment = () => {
    if (bugAttachmentsIndex > 0) {
      bugAttachmentsIndex -= 1;
      loadAttachment(bugAttachments[bugAttachmentsIndex].id);
    }
  };

  /**
   * Show the next attachment on the bug if possible.
   */
  const showNextAttachment = () => {
    if (bugAttachmentsIndex < bugAttachments.length - 1) {
      bugAttachmentsIndex += 1;
      loadAttachment(bugAttachments[bugAttachmentsIndex].id);
    }
  };

  /**
   * Show or hide the detail pane and and comment pane.
   * @param {boolean} [force] `true` to show, `false` to hide, rather than toggling the state.
   */
  const toggleDetails = (force = undefined) => {
    const hidden = force ?? !$subColumn.hidden;

    $subColumn.hidden = hidden;

    if ($commentPane) {
      $commentPane.hidden = hidden;
    }

    if ($saveButton) {
      $saveButton.disabled = hidden;
    }

    $toggleDetailsButton.textContent = hidden ? 'Show Details' : 'Hide Details';
  };

  /**
   * Load the data for all the attachments on the current bug.
   * @returns {Promise<object[]>} Attachments.
   * @see https://bugzilla.mozilla.org/docs/en/md/api/core/v1/attachment.md#get-attachment
   */
  const loadBugAttachments = async () => {
    const { bugs } = await Bugzilla.API.get(`bug/${bugId}/attachment`, {
      include_fields: ['_all'],
      exclude_fields: ['data'],
    });

    return bugs[bugId];
  };

  /**
   * Update the Content Type section when the selection method (radio buttons) is changed.
   */
  const onContentTypeSelectorChange = () => {
    const { value } = $form.contenttypemethod;

    $form.contenttypeselection.disabled = value !== 'list';
    // Don’t use `disabled` because the property removes the field from form data
    $form.contenttypeentry.readOnly = value !== 'manual';
    $form.ispatch.value = value === 'patch' ? 1 : 0;

    if (value === 'patch') {
      $form.contenttypeselection.value = 'text/plain';
      $form.contenttypeentry.value = 'text/plain';
    }

    if (value === 'binary') {
      $form.contenttypeselection.value = 'application/octet-stream';
      $form.contenttypeentry.value = 'application/octet-stream';
    }
  };

  /**
   * Open the Attachment overlay and prevent the background page from being scrolled.
   */
  const showOverlay = () => {
    $overlay.showModal();
    document.body.style.setProperty('overflow', 'hidden');
  };

  /**
   * Load the attachment data.
   * @param {number} id Attachment ID.
   * @param {string} [mode] Display mode. Only `lightbox` is supported.
   */
  const loadAttachment = async (id, mode) => {
    toggleDetails(mode === 'lightbox');

    if (!bugAttachments.length) {
      bugAttachments = await loadBugAttachments();
    }

    attachmentId = id;
    bugAttachmentsIndex = bugAttachments.findIndex((att) => att.id === id);

    const attachment = bugAttachments[bugAttachmentsIndex];
    const { size, content_type, last_change_time } = attachment;

    // Keep the snake_case property names from the API as is
    currentAttachment = {
      ...attachment,
      // Additional properties
      link: `${cgiPath}?id=${id}`,
      deleted: size === 0,
      is_binary: content_type === 'application/octet-stream',
      is_common_type: [...($form.contenttypeselection?.options ?? [])].some(
        (o) => o.value === content_type,
      ),
    };

    // Update hidden form values required to update the attachment
    if ($form.id) {
      /** @type {any} */ ($form.id).value = String(attachmentId);
      $form.delta_ts.value = last_change_time.replace('T', ' ').replace('Z', '');
      $form.token.value = tokens[attachmentId];
    }

    updateActions();
    updateDetails();
    updatePreview();
    updateComment();
  };

  /**
   * Update the title and action buttons on the header/footer.
   */
  const updateActions = () => {
    const { summary, deleted, is_patch, is_obsolete, is_private } = currentAttachment;

    const title = [
      is_private ? '[private]' : '',
      is_obsolete ? '[obsolete]' : '',
      deleted ? '[deleted]' : '',
      is_patch ? '[patch]' : '',
      summary,
    ]
      .filter(Boolean)
      .join(' ');

    $title.textContent = `Attachment ${attachmentId}: ${title}`;
    $title.classList.toggle('bz_private', is_private);

    $prevButton.disabled = bugAttachmentsIndex === 0;
    $nextButton.disabled = bugAttachmentsIndex === bugAttachments.length - 1;

    if ($diffButton) {
      $diffButton.disabled = deleted || !is_patch;
    }

    if ($reviewButton) {
      $reviewButton.disabled = deleted || !is_patch;
    }

    if ($deleteButton) {
      $deleteButton.disabled = deleted;
    }
  };

  /**
   * Update the detail pane.
   */
  const updateDetails = () => {
    const {
      summary,
      file_name,
      content_type,
      is_obsolete,
      is_private,
      is_patch,
      is_binary,
      is_common_type,
      size,
      flags,
      creation_time,
      last_change_time,
      creator_detail: { email: creatorEmail, real_name: creatorName, id: creatorId },
    } = currentAttachment;

    $creator.href = `mailto:${creatorEmail}`;
    $creator.title = `${creatorName} <${creatorEmail}>`;
    $creator.dataset.userName = creatorName;
    $creator.dataset.userEmail = creatorEmail;
    $creator.dataset.userId = creatorId;

    if ($creatorName) {
      $creatorName.textContent = creatorName;
    }

    const createdDate = new Date(creation_time);
    const updatedDate = new Date(last_change_time);

    $createdDate.textContent = timeAgo(createdDate);
    $createdDate.title = formatDate(createdDate);
    $createdDate.dataset.time = String(createdDate.valueOf() / 1000);
    $updatedDate.textContent = timeAgo(updatedDate);
    $updatedDate.title = formatDate(updatedDate);
    $updatedDate.dataset.time = String(updatedDate.valueOf() / 1000);
    $fileSize.textContent = size === 0 ? '0 bytes (deleted)' : formatFileSize(size);
    $form.description.value = summary;
    $form.filename.value = file_name;

    if ($form.contenttypemethod) {
      $form.contenttypemethod.value = is_patch
        ? 'patch'
        : is_binary
        ? 'binary'
        : is_common_type
        ? 'list'
        : 'manual';

      onContentTypeSelectorChange();
    }

    if ($form.contenttypeselection) {
      $form.contenttypeselection.value = is_common_type ? content_type : '';
    }

    $form.contenttypeentry.value = content_type;

    if ($form.ispatch) {
      $form.ispatch.value = is_patch;
    }

    if ($form.isobsolete) {
      $form.isobsolete.checked = is_obsolete;
    }

    // Insider only
    if ($form.isprivate) {
      $form.isprivate.checked = is_private;
    }

    updateFlags();

    // Cache the form data for later use
    initialFormData = Object.fromEntries(new FormData($form).entries());
  };

  /**
   * Update the flag list in the detail pane.
   */
  const updateFlags = () => {
    const { flags } = currentAttachment;
    const foundTypeIds = [];
    let separatorFound = false;

    // Reset all the rows first
    $form.querySelectorAll('.flag-table tbody').forEach((/** @type {HTMLElement} */ $row) => {
      const typeId = Number($row.dataset.typeId);
      const flagId = Number($row.dataset.flagId);

      if ($row.matches('.separator')) {
        separatorFound = true;
      }

      if (foundTypeIds.includes(typeId) || separatorFound) {
        $row.remove();
        return;
      }

      resetFlagRow($row, typeId, flagId);
      foundTypeIds.push(typeId);
    });

    // Then populate the flags for the current attachment
    $form.querySelectorAll('.flag-table tbody').forEach((/** @type {HTMLElement} */ $row) => {
      const typeId = Number($row.dataset.typeId);
      const typeFlags = flags.filter((flag) => flag.type_id === typeId);

      // Clone multi-requestable flags
      if ($row.matches('[data-type-multi="1"]') && typeFlags.length > 0) {
        typeFlags.forEach((flag) => {
          const $_row = /** @type {HTMLElement} */ ($row.cloneNode(true));

          $row.insertAdjacentElement('beforebegin', $_row);
          updateFlagRow($_row, flag, { cloned: true });
        });

        updateFlagRow($row, undefined, { additional: true });
      } else {
        updateFlagRow($row, typeFlags[0]);
      }
    });
  };

  /**
   * Reset a flag row.
   * @param {HTMLElement} $row `<tbody>` element.
   * @param {number} typeId Flag type ID.
   * @param {number} flagId Flag ID.
   */
  const resetFlagRow = ($row, typeId, flagId) => {
    const $setter = $row.querySelector('td.setter');
    const $status = /** @type {HTMLSelectElement} */ ($row.querySelector('td.value select'));
    const $requestee = /** @type {HTMLInputElement} */ ($row.querySelector('td.requestee input'));

    $row.dataset.flagId = '';
    $row.classList.add('bz_flag_type');
    $row.querySelectorAll('[id]').forEach((element) => {
      element.id = element.id
        .replace(`flag-${flagId}`, `flag_type-${typeId}`)
        .replace(`requestee-${flagId}`, `requestee_type-${typeId}`);
    });
    $row.querySelectorAll('[name]').forEach((/** @type {HTMLInputElement} */ element) => {
      element.name = element.name
        .replace(`flag-${flagId}`, `flag_type-${typeId}`)
        .replace(`requestee-${flagId}`, `requestee_type-${typeId}`);
    });
    $setter.textContent = '';
    $status.value = 'X';

    if ($requestee) {
      $requestee.value = '';
      $requestee.parentElement.classList.add('bz_default_hidden');
    }
  };

  /**
   * Update a flag row.
   * @param {HTMLElement} $row `<tbody>` element.
   * @param {object} flag Flag object from the API.
   * @param {object} [options] Options.
   * @param {boolean} [options.cloned] Whether the row is cloned. We need to reactivate user
   * autocomplete for the requestee field because the event listener is not cloned.
   * @param {boolean} [options.additional] Whether to show an `addl.` label in the setter column.
   * This only applies if the flag is multi-requestable, and there is one or more existing
   * requestees.
   */
  const updateFlagRow = ($row, flag, { cloned = false, additional = false } = {}) => {
    const $setter = $row.querySelector('td.setter');
    const $status = /** @type {HTMLSelectElement} */ ($row.querySelector('td.value select'));
    const $requestee = /** @type {HTMLInputElement} */ ($row.querySelector('td.requestee input'));

    if (flag && !additional) {
      $row.dataset.flagId = flag.id;
      $row.classList.remove('bz_flag_type');
      $row.querySelectorAll('[id]').forEach((element) => {
        element.id = element.id
          .replace(`flag_type-${flag.type_id}`, `flag-${flag.id}`)
          .replace(`requestee_type-${flag.type_id}`, `requestee-${flag.id}`);
      });
      $row.querySelectorAll('[name]').forEach((/** @type {HTMLInputElement} */ element) => {
        element.name = element.name
          .replace(`flag_type-${flag.type_id}`, `flag-${flag.id}`)
          .replace(`requestee_type-${flag.type_id}`, `requestee-${flag.id}`);
      });
    }

    $setter.textContent = flag?.setter
      ? `${flag.setter.split('@')?.[0]}:`
      : additional
      ? 'addl.'
      : '';
    $status.value = flag?.status || 'X';

    if ($requestee) {
      $requestee.value = flag?.requestee || '';
      $requestee.parentElement.classList.toggle('bz_default_hidden', !flag || !flag.requestee);

      if (cloned) {
        Bugzilla.Field.activateUserAutocomplete($requestee);
      }
    }
  };

  /**
   * Show fallback text and download link.
   * @param {string} [text] Text to be displayed. If omitted, no text is replaced in the preview.
   */
  const showPreviewFallback = (text) => {
    const { link, file_name } = currentAttachment;

    if (text) {
      $preview.innerHTML = `<div><p>${text}</p><p><a>Download</a></p></div>`;
    }

    const $downloadLink = $preview.querySelector('a');

    if ($downloadLink) {
      $downloadLink.href = link;
      $downloadLink.download = file_name;
    }
  };

  /**
   * Update the preview pane.
   */
  const updatePreview = async () => {
    const { link, deleted, file_name, content_type, data } = currentAttachment;

    if (deleted) {
      $preview.innerHTML = '<p>The content of this attachment has been deleted.</p>';

      return;
    }

    if (previewDisabled) {
      // The preview already shows a message: “The attachment is not viewable in your browser due to
      // security restrictions” with an anchor
      showPreviewFallback();

      return;
    }

    if (content_type in textTypeMap) {
      $preview.innerHTML = `<p><a href="${link}">View ${textTypeMap[content_type]}</a></p>`;

      return;
    }

    $preview.innerHTML = '<p>Loading…</p>';

    if (content_type.startsWith('text/')) {
      let _data = data;

      if (!_data) {
        const { attachments } = await Bugzilla.API.get(`bug/attachment/${attachmentId}`, {
          include_fields: ['data'],
        });

        _data = attachments[attachmentId].data;
        bugAttachments[bugAttachmentsIndex].data = _data;
      }

      const $textarea = document.createElement('textarea');

      $textarea.readOnly = true;
      $preview.innerHTML = '';
      $preview.appendChild($textarea).value = decodeBase64(_data);

      return;
    }

    if (content_type.startsWith('image/')) {
      const $image = new Image();

      $image.addEventListener('load', () => {
        $preview.innerHTML = '';
        $preview.appendChild($image);
      });

      $image.addEventListener('error', () => {
        $preview.innerHTML = '<p>Failed to load the image.</p>';
      });

      $image.src = link;
      $image.alt = '';

      return;
    }

    showPreviewFallback('No preview available for this type of attachment.');
  };

  /**
   * Update the comment pane.
   */
  const updateComment = () => {
    if ($commentPane) {
      $form.comment.value = '';
      $form.needinfo.checked = false;
      $form.needinfo_role.value = 'other';
      $form.needinfo_from.value = '';
    }
  };

  /**
   * Get the changes made on the form by comparing the initial values and current values.
   * @returns {{ [key: string]: { removed: any, added: any } } | null} Changes.
   */
  const getChanges = () => {
    if (!Object.keys(initialFormData).length) {
      return null;
    }

    const currentFormData = Object.fromEntries(new FormData($form).entries());
    const ignoredKeys = ['contenttypemethod', 'contenttypeselection'];
    /** @type {{ [key: string]: { removed: any, added: any } }} */
    const changes = {};

    Object.entries(initialFormData).forEach(([key, initialValue]) => {
      if (!ignoredKeys.includes(key) && initialValue !== currentFormData[key]) {
        changes[key] = { removed: initialValue, added: currentFormData[key] };
      }
    });

    Object.entries(currentFormData).forEach(([key, currentValue]) => {
      if (!ignoredKeys.includes(key) && initialFormData[key] !== currentValue) {
        changes[key] = { removed: initialFormData[key], added: currentValue };
      }
    });

    if (!Object.keys(changes).length) {
      return null;
    }

    return changes;
  };

  /**
   * Save any changes to the current attachment. Submit the form data via XHR instead of the API,
   * otherwise users may not be notified of the changes via email. This happened when `ftc.js` of
   * the FlagTypeComment extension was developed.
   * @returns {Promise<boolean>} Whether the changes have been saved.
   */
  const saveChanges = async () => {
    // Just close the dialog if no changes have been made
    if (!getChanges()) {
      $overlay.close();

      return false;
    }

    $status.textContent = 'Saving changes…';
    $saveButton.disabled = true;

    const request = new XMLHttpRequest();
    const data = new FormData($form);

    // Always use the `contenttypeentry` field for the content type
    data.set('contenttypemethod', 'manual');

    try {
      await new Promise((resolve, reject) => {
        request.open('POST', cgiPath);
        request.addEventListener('load', () => resolve());
        request.addEventListener('error', () => reject());
        request.send(data);
      });

      return true;
    } catch {
      $status.textContent = 'Couldn’t save the changes';
      $saveButton.disabled = false;
    }

    return false;
  };

  initOverlay();
  initActions();
  initDetails();
  initAttachmentLinks();
});
