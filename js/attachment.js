/* The contents of this file are subject to the Mozilla Public
 * License Version 1.1 (the "License"); you may not use this file
 * except in compliance with the License. You may obtain a copy of
 * the License at http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS
 * IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
 * implied. See the License for the specific language governing
 * rights and limitations under the License.
 *
 * The Original Code is the Bugzilla Bug Tracking System.
 *
 * The Initial Developer of the Original Code is Netscape Communications
 * Corporation. Portions created by Netscape are
 * Copyright (C) 1998 Netscape Communications Corporation. All
 * Rights Reserved.
 *
 * Contributor(s): Myk Melez <myk@mozilla.org>
 *                 Joel Peshkin <bugreport@peshkin.net>
 *                 Erik Stambaugh <erik@dasbistro.com>
 *                 Marc Schumann <wurblzap@gmail.com>
 *                 Guy Pyrzak <guy.pyrzak@gmail.com>
 *                 Kohei Yoshino <kohei.yoshino@gmail.com>
 */

function updateCommentPrivacy(checkbox) {
    var text_elem = document.getElementById('comment');
    if (checkbox.checked) {
        text_elem.className='bz_private';
    } else {
        text_elem.className='';
    }
}

/* Functions used when viewing patches in Diff mode. */

function collapse_all() {
  var elem = document.checkboxform.firstChild;
  while (elem != null) {
    if (elem.firstChild != null) {
      var tbody = elem.firstChild.nextSibling;
      if (tbody.className == 'file') {
        tbody.className = 'file_collapse';
        twisty = get_twisty_from_tbody(tbody);
        twisty.firstChild.nodeValue = '(+)';
        twisty.nextSibling.checked = false;
      }
    }
    elem = elem.nextSibling;
  }
  return false;
}

function expand_all() {
  var elem = document.checkboxform.firstChild;
  while (elem != null) {
    if (elem.firstChild != null) {
      var tbody = elem.firstChild.nextSibling;
      if (tbody.className == 'file_collapse') {
        tbody.className = 'file';
        twisty = get_twisty_from_tbody(tbody);
        twisty.firstChild.nodeValue = '(-)';
        twisty.nextSibling.checked = true;
      }
    }
    elem = elem.nextSibling;
  }
  return false;
}

var current_restore_elem;

function restore_all() {
  current_restore_elem = null;
  incremental_restore();
}

function incremental_restore() {
  if (!document.checkboxform.restore_indicator.checked) {
    return;
  }
  var next_restore_elem;
  if (current_restore_elem) {
    next_restore_elem = current_restore_elem.nextSibling;
  } else {
    next_restore_elem = document.checkboxform.firstChild;
  }
  while (next_restore_elem != null) {
    current_restore_elem = next_restore_elem;
    if (current_restore_elem.firstChild != null) {
      restore_elem(current_restore_elem.firstChild.nextSibling);
    }
    next_restore_elem = current_restore_elem.nextSibling;
  }
}

function restore_elem(elem, alertme) {
  if (elem.className == 'file_collapse') {
    twisty = get_twisty_from_tbody(elem);
    if (twisty.nextSibling.checked) {
      elem.className = 'file';
      twisty.firstChild.nodeValue = '(-)';
    }
  } else if (elem.className == 'file') {
    twisty = get_twisty_from_tbody(elem);
    if (!twisty.nextSibling.checked) {
      elem.className = 'file_collapse';
      twisty.firstChild.nodeValue = '(+)';
    }
  }
}

function twisty_click(twisty) {
  tbody = get_tbody_from_twisty(twisty);
  if (tbody.className == 'file') {
    tbody.className = 'file_collapse';
    twisty.firstChild.nodeValue = '(+)';
    twisty.nextSibling.checked = false;
  } else {
    tbody.className = 'file';
    twisty.firstChild.nodeValue = '(-)';
    twisty.nextSibling.checked = true;
  }
  return false;
}

function get_tbody_from_twisty(twisty) {
  return twisty.parentNode.parentNode.parentNode.nextSibling;
}
function get_twisty_from_tbody(tbody) {
  return tbody.previousSibling.firstChild.nextSibling.firstChild.firstChild;
}

var prev_mode = 'raw';
var current_mode = 'raw';
var has_edited = 0;
var has_viewed_as_diff = 0;
function editAsComment(patchviewerinstalled)
{
    switchToMode('edit', patchviewerinstalled);
    has_edited = 1;
}
function undoEditAsComment(patchviewerinstalled)
{
    switchToMode(prev_mode, patchviewerinstalled);
}
function redoEditAsComment(patchviewerinstalled)
{
    switchToMode('edit', patchviewerinstalled);
}

function viewDiff(attachment_id, patchviewerinstalled)
{
    switchToMode('diff', patchviewerinstalled);

    // If we have not viewed as diff before, set the view diff frame URL
    if (!has_viewed_as_diff) {
      var viewDiffFrame = document.getElementById('viewDiffFrame');
      viewDiffFrame.src = `${BUGZILLA.config.basepath}attachment.cgi?id=${attachment_id}&action=diff&headers=0`;
      has_viewed_as_diff = 1;
    }
}

function viewRaw(patchviewerinstalled)
{
    switchToMode('raw', patchviewerinstalled);
}

function switchToMode(mode, patchviewerinstalled)
{
    if (mode == current_mode) {
      alert('switched to same mode!  This should not happen.');
      return;
    }

    // Switch out of current mode
    if (current_mode == 'edit') {
      hideElementById('editFrame');
      hideElementById('undoEditButton');
      document.querySelector('input[name="markdown_off"]').value = 0;
    } else if (current_mode == 'raw') {
      hideElementById('viewFrame');
      if (patchviewerinstalled)
          hideElementById('viewDiffButton');
      hideElementById(has_edited ? 'redoEditButton' : 'editButton');
      hideElementById('smallCommentFrame');
    } else if (current_mode == 'diff') {
      if (patchviewerinstalled)
          hideElementById('viewDiffFrame');
      hideElementById('viewRawButton');
      hideElementById(has_edited ? 'redoEditButton' : 'editButton');
      hideElementById('smallCommentFrame');
    }

    // Switch into new mode
    if (mode == 'edit') {
      showElementById('editFrame');
      showElementById('undoEditButton');
      document.querySelector('input[name="markdown_off"]').value = 1;
    } else if (mode == 'raw') {
      showElementById('viewFrame');
      if (patchviewerinstalled)
          showElementById('viewDiffButton');

      showElementById(has_edited ? 'redoEditButton' : 'editButton');
      showElementById('smallCommentFrame');
    } else if (mode == 'diff') {
      if (patchviewerinstalled)
        showElementById('viewDiffFrame');

      showElementById('viewRawButton');
      showElementById(has_edited ? 'redoEditButton' : 'editButton');
      showElementById('smallCommentFrame');
    }

    prev_mode = current_mode;
    current_mode = mode;
}

function hideElementById(id)
{
  document.getElementById(id)?.classList.add('bz_default_hidden');
}

function showElementById(id)
{
  document.getElementById(id)?.classList.remove('bz_default_hidden');
}

function normalizeComments()
{
  // Remove the unused comment field from the document so its contents
  // do not get transmitted back to the server.

  var small = document.getElementById('smallCommentFrame');
  var big = document.getElementById('editFrame');
  if (small?.matches('.bz_default_hidden')) {
    small.parentNode.removeChild(small);
  }
  if (big?.matches('.bz_default_hidden')) {
    big.parentNode.removeChild(big);
  }
}

function toggle_attachment_details_visibility ( )
{
    // show hide classes
    var container = document.getElementById('attachment_info');
    if (container.matches('.read')) {
      container.classList.replace('read', 'edit');
    } else {
      container.classList.replace('edit', 'read');
    }
}

/* Used in bug/create.html.tmpl to show/hide the attachment field. */

function handleWantsAttachment(wants_attachment) {
    if (wants_attachment) {
        hideElementById('attachment_false');
        showElementById('attachment_true');
    }
    else {
        showElementById('attachment_false');
        hideElementById('attachment_true');
        bzAttachmentForm.resetFields();
    }

    bzAttachmentForm.updateRequirements(wants_attachment);
}

/**
 * Expose an `AttachmentForm` instance on global.
 */
var bzAttachmentForm;

/**
 * Reference or define the Bugzilla app namespace.
 * @namespace
 */
var Bugzilla = Bugzilla || {};

/**
 * Implement the attachment selector functionality that can be used standalone or on the New Bug
 * page. This supports multiple input methods:
 * - Drag & drop: the user drags a file or text and drops it on the drop target. The drop target is
 *   highlighted when a file is dragged over it.
 * - Browse: the user clicks the Browse button and selects a file with the file picker dialog.
 * - Enter text: the user clicks the Enter Text button and enters text in the textarea.
 * - Paste: the user clicks the Paste button and pastes an image or text from the clipboard. This is
 *   supported only in browsers with the Async Clipboard API. In other browsers, the Paste button is
 *   hidden.
 * - Capture: the user clicks the Take a Screenshot button and captures a screen, window or browser
 *   tab. The capture is attached as a PNG image.
 */
Bugzilla.AttachmentSelector = class AttachmentSelector {
  /**
   * Initialize a new `AttachmentSelector` instance.
   * @param {object} params An object of parameters.
   * @param {HTMLElement} params.$placeholder An element to be enhanced with the attachment selector
   * functionality.
   * @param {Record<string, Function>} [params.eventHandlers] An object of event handlers to be
   * called when the user performs certain actions.
   */
  constructor({ $placeholder, eventHandlers = {} }) {
    this.$placeholder = $placeholder;
    this.eventHandlers = eventHandlers;

    this.#renderUI();
    this.#cacheElements();
    this.#setupEventListeners();
    this.#setupFileReaders();
    this.#initializeView();
    this.#checkBrowserSupport();
  }

  /**
   * Render the attachment selector UI template, detecting device type to conditionally show
   * drag-and-drop hint.
   */
  #renderUI() {
    // Assume a fine pointer (e.g., a mouse) means a desktop device, and a coarse pointer means a
    // mobile device. Don’t show the “Drag & drop” hint on mobile because it’s not a common input
    // method on that platform.
    const isDesktop = window.matchMedia('(pointer: fine)').matches;

    this.$placeholder.innerHTML = `
      <div id="att-selector">
        <div id="att-dropbox">
          <div class="actions">
            <span class="icon" aria-hidden="true"></span>
            ${isDesktop ? `<span>Drag &amp; drop a file here, or</span>` : ''}
           <span class="button-group">
              <button type="button" id="att-browse-button">Browse File</button>
              <button type="button" id="att-paste-button">Paste Text or Image</button>
              <button type="button" id="att-enter-button">Enter Text</button>
              <button type="button" id="att-capture-button">Take Screenshot</button>
            </span>
          </div>
          <input hidden id="att-file" type="file">
          <div id="att-item">
            <div hidden id="att-editor">
              <textarea id="att-textarea" name="attach_text" cols="80" rows="8"
                  aria-label="Attachment Content" aria-invalid="false"
                  aria-errormessage="att-error-message"
                  aria-description="Paste text, link or image to be added as an attachment"></textarea>
              <span id="att-text-remove-button" class="att-remove-button" tabindex="0" role="button"
                  aria-label="Remove attachment">
                <span class="icon" aria-hidden="true"></span>
              </span>
            </div>
            <div hidden id="att-preview">
              <input id="att-filename" type="hidden" name="filename">
              <textarea hidden id="att-data" name="data_base64" aria-hidden="true"
                  aria-invalid="false" aria-errormessage="att-data-error"></textarea>
              <figure role="img" aria-labelledby="att-preview-name" itemscope
                  itemtype="http://schema.org/MediaObject">
                <meta itemprop="encodingFormat">
                <pre itemprop="text"></pre>
                <img src="" alt="" itemprop="image">
                <figcaption class="att-preview-name" itemprop="name"></figcaption>
                <span class="icon" aria-hidden="true"></span>
              </figure>
              <span id="att-file-remove-button" class="att-remove-button" tabindex="0" role="button"
                  aria-label="Remove attachment">
                <span class="icon" aria-hidden="true"></span>
              </span>
            </div>
          </div>
        </div>
        <div id="att-error-message" class="warning" aria-live="assertive"></div>
      </div>
    `;
  }

  /**
   * Cache references to DOM elements for quick access.
   */
  #cacheElements() {
    this.$file = this.$placeholder.querySelector('#att-file');
    this.$data = this.$placeholder.querySelector('#att-data');
    this.$filename = this.$placeholder.querySelector('#att-filename');
    this.$dropbox = this.$placeholder.querySelector('#att-dropbox');
    this.$selectorActions = this.$placeholder.querySelector('#att-selector .actions');
    this.$browseButton = this.$placeholder.querySelector('#att-browse-button');
    this.$enterButton = this.$placeholder.querySelector('#att-enter-button');
    this.$pasteButton = this.$placeholder.querySelector('#att-paste-button');
    this.$captureButton = this.$placeholder.querySelector('#att-capture-button');
    this.$editor = this.$placeholder.querySelector('#att-editor');
    this.$textarea = this.$editor.querySelector('#att-textarea');
    this.$preview = this.$placeholder.querySelector('#att-preview');
    this.$previewName = this.$preview.querySelector('[itemprop="name"]');
    this.$previewType = this.$preview.querySelector('[itemprop="encodingFormat"]');
    this.$previewText = this.$preview.querySelector('[itemprop="text"]');
    this.$previewImage = this.$preview.querySelector('[itemprop="image"]');
    this.$textRemoveButton = this.$placeholder.querySelector('#att-text-remove-button');
    this.$fileRemoveButton = this.$placeholder.querySelector('#att-file-remove-button');
    this.$errorMessage = this.$placeholder.querySelector('#att-error-message');
  }

  /**
   * Register all event listeners for form submission, file input, drag-and-drop, buttons, and text
   * input.
   */
  #setupEventListeners() {
    this.$placeholder.closest('form').addEventListener('submit', (event) => this.validate(event));
    this.$placeholder.closest('form').querySelector('[type="submit"]')
      ?.addEventListener('click', (event) => this.validate(event));
    this.$file.addEventListener('change', () => this.fileOnChange());
    this.$dropbox.addEventListener('dragover', (event) => this.dropboxOnDragOver(event));
    this.$dropbox.addEventListener('dragleave', () => this.dropboxOnDragLeave());
    this.$dropbox.addEventListener('dragend', () => this.dropboxOnDragEnd());
    this.$dropbox.addEventListener('drop', (event) => this.dropboxOnDrop(event));
    this.$browseButton.addEventListener('click', () => this.$file.click());
    this.$enterButton.addEventListener('click', () => this.enterButtonOnClick());
    this.$pasteButton.addEventListener('click', () => this.pasteButtonOnClick());
    this.$captureButton.addEventListener('click', () => this.captureButtonOnClick());
    this.$textarea.addEventListener('input', () => this.textareaOnInput());
    this.$textRemoveButton.addEventListener('click', () => this.removeButtonOnClick());
    this.$fileRemoveButton.addEventListener('click', () => this.removeButtonOnClick());
  }

  /**
   * Initialize FileReader instances for reading file data and text content.
   */
  #setupFileReaders() {
    this.dataReader = new FileReader();
    this.textReader = new FileReader();
    this.dataReader.addEventListener('load', () => this.dataReaderOnLoad());
    this.textReader.addEventListener('load', () => this.textReaderOnLoad());
  }

  /**
   * Initialize the UI state and prepare the form for use.
   */
  #initializeView() {
    this.enableKeyboardAccess();
    this.resetFields();
  }

  /**
   * Hide action buttons if the required browser APIs are not supported.
   */
  #checkBrowserSupport() {
    // Hide the Paste button if the Clipboard API is not available
    this.$pasteButton.hidden = typeof navigator.clipboard?.read !== 'function';
    // Hide the Capture button if the Screen Capture API is not available
    this.$captureButton.hidden = typeof navigator.mediaDevices?.getDisplayMedia !== 'function';
  }

  /**
   * Whether the attachment is required.
   * @type {boolean}
   */
  get required() {
    return this.$placeholder.dataset.required === 'true';
  }

  /**
   * Show or hide the header with the action buttons.
   * @param {boolean} value `true` to show the header, `false` to hide it.
   */
  set actionsDisplayed(value) {
    this.$selectorActions.hidden = !value;
  }

  /**
   * Show or hide the editor.
   * @param {boolean} value `true` to show the editor, `false` to hide it.
   */
  set editorDisplayed(value) {
    this.$editor.hidden = !value;
  }

  /**
   * Show or hide the preview.
   * @param {boolean} value `true` to show the preview, `false` to hide it.
   */
  set previewDisplayed(value) {
    this.$preview.hidden = !value;
  }

  /**
   * Dispatch a custom event to the registered event handlers.
   * @param {string} name The name of the event.
   * @param {Record<string, any>} [detail] Additional data to pass to the event handler.
   */
  dispatchEvent(name, detail = {}) {
    this.eventHandlers[name]?.(detail);
  }

  /**
   * Enable keyboard access on the buttons. Treat the Enter keypress as a click.
   */
  enableKeyboardAccess() {
    document.querySelectorAll('#att-selector [role="button"]').forEach(($button) => {
      $button.addEventListener('keypress', (event) => {
        if (!event.isComposing && event.key === 'Enter') {
          event.target.click();
        }
      });
    });
  }

  /**
   * Reset all the input fields to the initial state, and remove the preview and message.
   */
  resetFields() {
    this.$file.value = '';
    this.$data.value = '';
    this.$filename.value = '';

    this.clearPreview();
    this.clearError();
    this.updateText();
  }

  /**
   * Process a file for upload regardless of how it was provided (file picker, drag-and-drop, paste
   * or screen capture). Read the file content, update the filename field, and show the preview.
   * @param {File} file A file to be read.
   */
  processFile(file) {
    // Detect patches that should have the `text/plain` MIME type
    const isPatch =
      !!file.name.match(/\.(?:diff|patch)$/) || !!file.type.match(/^text\/x-(?:diff|patch)$/);
    // Detect Markdown files that should have `text/plain` instead of `text/markdown` due to Firefox
    // Bug 1421032
    const isMarkdown = !!file.name.match(/\.(?:md|mkdn?|mdown|markdown)$/);
    // Detect common source files that may have no MIME type or `application/*` MIME type
    const isSource = !!file.name.match(
      /\.(?:cpp|es|h|js|json|rs|rst|sh|toml|ts|tsx|xml|yaml|yml)$/,
    );
    // Detect any plaintext file
    const isText = file.type.startsWith('text/') || isPatch || isMarkdown || isSource;
    // Reassign the MIME type: use `text/plain` for most text files and `application/octet-stream`
    // as a fallback
    const type =
      isPatch || isMarkdown || (isSource && !file.type)
        ? 'text/plain'
        : file.type || 'application/octet-stream';

    if (this.checkFileSize(file.size)) {
      this.dataReader.readAsDataURL(file);
      this.$file.value = '';
      this.$filename.value = file.name.replace(/\s/g, '-');
    } else {
      this.$file.value = '';
      this.$data.value = '';
      this.$filename.value = '';
    }

    this.showPreview(file, isText);
    this.updateText();
    this.dispatchEvent('AttachmentProcessed', { file, type, isPatch });
  }

  /**
   * Check the current file size and show an error message if it exceeds the application-defined
   * limit.
   * @param {number} size A file size in bytes.
   * @returns {boolean} `true` if the file is less than the maximum allowed size, `false` otherwise.
   */
  checkFileSize(size) {
    const fileSize = size / 1024; // Convert to KB
    const maxSize = BUGZILLA.param.maxattachmentsize; // Defined in KB
    const invalid = fileSize > maxSize;
    const message = invalid
      ? `This file (<strong>${(fileSize / 1024).toFixed(1)} MB</strong>) is larger than the ` +
        `maximum allowed size (<strong>${(maxSize / 1024).toFixed(1)} MB</strong>). Please ` +
        `consider uploading it to an online file storage and sharing the link in a ` +
        `${BUGZILLA.string.bug} comment instead.`
      : '';
    const messageShort = invalid ? 'File too large' : '';

    this.$errorMessage.hidden = !invalid;
    this.$errorMessage.innerHTML = message;
    this.$dropbox.classList.toggle('invalid', invalid);

    return !invalid;
  }

  /**
   * Called whenever a file’s data URL is read by `FileReader`. Embed the Base64-encoded content for
   * upload.
   */
  dataReaderOnLoad() {
    this.$data.value = this.dataReader.result.split(',')[1];
  }

  /**
   * Called whenever a file’s text content is read by `FileReader`. Show the preview of the first 10
   * lines.
   */
  textReaderOnLoad() {
    this.$previewText.textContent = this.textReader.result.split(/\r\n|\r|\n/, 10).join('\n');
  }

  /**
   * Called whenever a file is selected by the user by using the file picker. Prepare for upload.
   */
  fileOnChange() {
    this.processFile(this.$file.files[0]);
  }

  /**
   * Called whenever a file is being dragged on the drop target. Allow the `copy` drop effect, and
   * set a class name on the drop target for styling.
   * @param {DragEvent} event A `dragover` event.
   */
  dropboxOnDragOver(event) {
    event.preventDefault();
    event.dataTransfer.dropEffect = event.dataTransfer.effectAllowed = 'copy';

    if (!this.$dropbox.classList.contains('dragover')) {
      this.$dropbox.classList.add('dragover');
    }
  }

  /**
   * Called whenever a dragged file leaves the drop target. Reset the styling.
   */
  dropboxOnDragLeave() {
    this.$dropbox.classList.remove('dragover');
  }

  /**
   * Called whenever a drag operation is being ended. Reset the styling.
   */
  dropboxOnDragEnd() {
    this.$dropbox.classList.remove('dragover');
  }

  /**
   * Called whenever a file or text is dropped on the drop target. If it’s a file, read the content.
   * If it’s plaintext, fill in the textarea.
   * @param {DragEvent} event A `drop` event.
   */
  dropboxOnDrop(event) {
    event.preventDefault();

    const files = event.dataTransfer.files;
    const text = event.dataTransfer.getData('text');

    if (files.length > 0) {
      this.processFile(files[0]);
      this.editorDisplayed = false;
      this.previewDisplayed = true;
    } else if (text) {
      this.clearPreview();
      this.clearError();
      this.updateText(text);
      this.actionsDisplayed = false;
      this.editorDisplayed = true;
      this.previewDisplayed = false;
    }

    this.$dropbox.classList.remove('dragover');
  }

  /**
   * Insert text to the textarea, and show it if it’s not empty.
   * @param {string} [text] Text to be inserted.
   */
  updateText(text = '') {
    this.$textarea.value = text;
    this.textareaOnInput();

    if (text.trim()) {
      this.$textarea.hidden = false;
      this.$dropbox.classList.remove('invalid');
      this.$errorMessage.hidden = true;
    }
  }

  /**
   * Called whenever the Enter Text button is clicked. Show the textarea for text input.
   */
  enterButtonOnClick() {
    this.actionsDisplayed = false;
    this.editorDisplayed = true;
    this.$textarea.focus();
  }

  /**
   * Called whenever the Paste button is clicked. Read the clipboard content and process it. This
   * supports pasting of regular images, links and text.
   */
  async pasteButtonOnClick() {
    try {
      const items = [...(await navigator.clipboard.read())];
      let pasted = false;

      // Process only the first item until multiple items are supported
      items.length = 1;

      for (const item of items) {
        if (item.types.includes('image/png')) {
          const blob = await item.getType('image/png');
          const file = new File([blob], 'pasted-image.png', { type: 'image/png' });

          this.processFile(file);
          this.editorDisplayed = false;
          this.previewDisplayed = true;
          pasted = true;
        } else if (item.types.includes('text/plain')) {
          const blob = await item.getType('text/plain');
          const text = await blob.text();

          this.updateText(text);
          this.editorDisplayed = true;
          this.previewDisplayed = false;
          pasted = true;
        }
      }

      if (pasted) {
        this.actionsDisplayed = false;
        this.dispatchEvent('AttachmentPasted', { items });
      } else {
        alert('No image or text data found in the clipboard.');
      }
    } catch (error) {
      alert(error.message);
    }
  }

  /**
   * Called whenever the Take a Screenshot button is clicked. Capture a screen, window or browser
   * tab if the Screen Capture API is supported, then attach it as a PNG image.
   * @see https://developer.mozilla.org/en-US/docs/Web/API/Screen_Capture_API
   */
  async captureButtonOnClick() {
    const $video = document.createElement('video');
    const $canvas = document.createElement('canvas');

    try {
      const stream = await navigator.mediaDevices.getDisplayMedia({
        video: { displaySurface: 'window' },
      });

      // Render a captured screenshot on `<video>`
      $video.srcObject = stream;

      await $video.play();

      const width = ($canvas.width = $video.videoWidth);
      const height = ($canvas.height = $video.videoHeight);

      // Draw a video frame on `<canvas>`
      $canvas.getContext('2d').drawImage($video, 0, 0, width, height);

      // Clean up `<video>`
      $video.pause();
      $video.srcObject.getTracks().forEach((track) => track.stop());
      $video.srcObject = null;

      // Convert to PNG
      const blob = await new Promise((resolve) => $canvas.toBlob((blob) => resolve(blob)));
      const [date, time] = new Date().toISOString().match(/^(.+)T(.+)\./).slice(1);
      const file = new File([blob], `Screenshot on ${date} at ${time}.png`, { type: 'image/png' });

      this.processFile(file);
      this.dispatchEvent('AttachmentCaptured', { file });
    } catch {
      alert('Unable to capture a screenshot.');
    }
  }

  /**
   * Called whenever the content of the textarea is updated. Dispatches the `AttachmentTextUpdated`
   * event with the current text content, and whether it's detected as a patch or GitHub PR link.
   */
  textareaOnInput() {
    const text = this.$textarea.value.trim();
    const hasText = !!text;
    const isPatch = !!text.match(/^(?:diff|---)\s/);
    const isGhpr = !!text.match(/^https:\/\/github\.com\/[\w\-]+\/[\w\-]+\/pull\/\d+\/?$/);

    if (hasText) {
      this.$file.value = '';
      this.$data.value = '';
    }

    this.dispatchEvent('AttachmentTextUpdated', { text, hasText, isPatch, isGhpr });
  }

  /**
   * Show the preview of a user-selected file. Display a thumbnail if it’s a regular image (PNG,
   * GIF, JPEG, etc.) or small plaintext file. Don’t show the preview of SVG image because it can be
   * a crash test.
   * @param {File} file A file to be previewed.
   * @param {boolean} [isText] `true` if the file is a plaintext file, `false` otherwise.
   */
  showPreview(file, isText = false) {
    this.$previewName.textContent = file.name;
    this.$previewType.content = file.type;
    this.$previewText.textContent = '';
    this.$previewImage.src = file.type.match(/^image\/(?!vnd|svg)/)
      ? URL.createObjectURL(file)
      : '';
    this.actionsDisplayed = false;
    this.previewDisplayed = true;

    if (isText && file.size < 500000) {
      this.textReader.readAsText(file);
    }
  }

  /**
   * Remove the preview.
   */
  clearPreview() {
    URL.revokeObjectURL(this.$previewImage.src);

    this.$previewName.textContent = this.$previewType.content = '';
    this.$previewText.textContent = this.$previewImage.src = '';
    this.previewDisplayed = false;
  }

  /**
   * Called whenever the Remove button is clicked by the user. Reset all the fields and show the
   * action buttons.
   */
  removeButtonOnClick() {
    this.resetFields();

    this.actionsDisplayed = true;
    this.editorDisplayed = false;
    this.previewDisplayed = false;
  }

  /**
   * Remove the error message if any.
   */
  clearError() {
    this.checkFileSize(0);
  }

  /**
   * Update the required state of the form.
   * @param {boolean} [required] `true` if an attachment is required, `false` otherwise.
   */
  updateRequirements(required = true) {
    if (!required) {
      this.$dropbox.classList.remove('invalid');
      this.$errorMessage.hidden = true;
    }
  }

  /**
   * Update the validation state of the form. Show an error message if the attachment is required
   * but not provided, and highlight the drop target. This is called on form submission to prevent
   * the form from being submitted with invalid input.
   * @param {MouseEvent | SubmitEvent} event A `submit` event from the form or a `click` event from
   * the submit button.
   * @returns {boolean} `true` if the form is valid and can be submitted, `false` otherwise.
   */
  validate(event) {
    const invalid =
      this.required &&
      !this.$data.value.trim() &&
      !this.$file.length &&
      !this.$textarea.value.trim();

    this.$errorMessage.textContent = invalid ? 'You must provide an attachment.' : '';
    this.$errorMessage.hidden = !invalid;
    this.$dropbox.classList.toggle('invalid', invalid);

    if (invalid) {
      event.preventDefault();
    }

    return !invalid;
  }
};

/**
 * Implement the attachment form functionality on the New Bug and New Attachment pages. This
 * includes the attachment selector implemented in `AttachmentSelector`, as well as other related
 * fields such as Description, Content Type, Patch checkbox, etc. that are updated based on the user
 * input and the selected file.
 */
Bugzilla.AttachmentForm = class AttachmentForm {
  /**
   * Initialize a new `AttachmentForm` instance.
   */
  constructor() {
    this.#cacheFormElements();
    this.#setupFormValidation();
    this.#setupFieldEventListeners();
    this.#initializeAttachmentSelector();
    this.updateRequirements(this.required);
  }

  /**
   * Cache references to all DOM elements used by this form.
   */
  #cacheFormElements() {
    this.$placeholder = document.querySelector('#att-placeholder');
    this.$description = document.querySelector('#att-description');
    this.$descError = document.querySelector('#att-desc-error');
    this.$isPatch = document.querySelector('#att-ispatch');
    this.$hidePreview = document.querySelector('#att-hide-preview');
    this.$typeOuter = document.querySelector('#att-type-outer');
    this.$typeList = document.querySelector('#att-type-list');
    this.$typeManual = document.querySelector('#att-type-manual');
    this.$typeSelect = document.querySelector('#att-type-select');
    this.$typeInput = document.querySelector('#att-type-input');
    this.$isPrivate = document.querySelector('#isprivate');
    this.$takeBug = document.querySelector('#takebug');
  }

  /**
   * Set up form submission validation handlers.
   */
  #setupFormValidation() {
    const $form = this.$placeholder.closest('form');
    const handler = (event) => this.validate(event);

    // Make sure to validate the form on both the `submit` event from the form and the `click` event
    // from the submit button, since the implementation varies by page
    $form?.addEventListener('submit', handler);
    $form?.querySelector('[type="submit"]')?.addEventListener('click', handler);
  }

  /**
   * Set up event listeners for individual form fields.
   */
  #setupFieldEventListeners() {
    this.$description.addEventListener('input', () => this.descriptionOnInput());
    this.$isPatch.addEventListener('change', () => this.isPatchOnChange());
    this.$hidePreview.addEventListener('change', () => this.hidePreviewOnChange());
    this.$typeSelect.addEventListener('change', () => this.typeSelectOnChange());
    this.$typeInput.addEventListener('change', () => this.typeInputOnChange());
  }

  /**
   * Initialize the attachment selector with event handlers.
   */
  #initializeAttachmentSelector() {
    this.selector = new Bugzilla.AttachmentSelector({
      $placeholder: this.$placeholder,
      eventHandlers: {
        AttachmentProcessed: (event) => this.onAttachmentProcessed(event),
        AttachmentCaptured: (event) => this.onAttachmentCaptured(event),
        AttachmentTextUpdated: (event) => this.onAttachmentTextUpdated(event),
        AttachmentPasted: (event) => this.onAttachmentPasted(event),
      },
    });
  }

  /**
   * Whether an attachment is required. This is defined by the presence of the `data-required`
   * attribute on the placeholder element.
   * @type {boolean}
   */
  get required() {
    return this.$placeholder.dataset.required === 'true';
  }

  /**
   * Get the description of the attachment.
   * @type {string}
   */
  get description() {
    return this.$description.value.trim();
  }

  /**
   * Set the description of the attachment.
   * @param {string} value A new description for the attachment.
   */
  set description(value) {
    this.$description.value = value;
    this.updateValidation();
  }

  /**
   * Called whenever a file is processed by `AttachmentSelector`. Update the Description, Content
   * Type, Patch checkbox, etc. based on the file properties and content.
   * @param {object} params An object with the following properties:
   * @param {File} params.file A processed `File` object.
   * @param {string} params.type A MIME type to be selected in the Content Type field.
   * @param {boolean} params.isPatch `true` if the file is detected as a patch, `false` otherwise.
   */
  onAttachmentProcessed({ file, type, isPatch }) {
    if (!this.descriptionOverridden) {
      this.description = file.name;
    }

    this.$description.select();
    this.$description.focus();

    this.updateContentType(type);
    this.updateIsPatch(isPatch);
  }

  /**
   * Called whenever an attachment is captured. Update the Patch checkbox to be unchecked and
   * disabled since we cannot reliably detect the content of captured data.
   * @param {object} params An object with the following properties:
   * @param {File} params.file A captured `File` object.
   */
  onAttachmentCaptured({ file }) {
    this.updateIsPatch(false, true);
  }

  /**
   * Called whenever the attachment text is updated. Update the Content Type, Patch checkbox, etc.
   * based on the new content.
   * @param {object} params An object with the following properties:
   * @param {string} params.text The new text content.
   * @param {boolean} params.hasText `true` if the textarea has non-empty content, `false`
   * otherwise.
   * @param {boolean} params.isPatch `true` if the content is detected as a patch, `false`
   * otherwise.
   * @param {boolean} params.isGhpr `true` if the content is detected as a GitHub Pull Request link,
   * `false` otherwise.
   */
  onAttachmentTextUpdated({ text, hasText, isPatch, isGhpr }) {
    if (hasText) {
      this.updateContentType('text/plain');
    }

    if (!this.descriptionOverridden) {
      this.description = isPatch ? 'patch' : isGhpr ? 'GitHub Pull Request' : '';
    }

    this.$description.setAttribute('aria-required', hasText);
    this.$typeInput.value = isGhpr ? 'text/x-github-pull-request' : '';
    this.updateIsPatch(isPatch);
  }

  /**
   * Called whenever an attachment is pasted. Update the Patch checkbox to be unchecked and disabled
   * since we cannot reliably detect the content of pasted data.
   * @param {object} params An object with the following properties:
   * @param {ClipboardItem[]} params.items An array of `ClipboardItem` objects representing the
   * pasted data.
   */
  onAttachmentPasted({ items }) {
    this.updateIsPatch(false, true);
  }

  /**
   * Reset all the input fields to the initial state, and remove the preview and message.
   */
  resetFields() {
    this.description = '';
    this.descriptionOverridden = false;
    this.$typeInput.value = '';
    this.$typeList.checked = this.$typeSelect.options[0].selected = true;
    this.resetOptionalFields();
    this.updateIsPatch();
    this.selector.resetFields();
  }

  /**
   * Reset optional form fields (isPrivate, takeBug) if they exist.
   */
  resetOptionalFields() {
    if (this.$isPrivate) {
      this.$isPrivate.checked = this.$isPrivate.disabled = false;
    }

    if (this.$takeBug) {
      this.$takeBug.checked = this.$takeBug.disabled = false;
    }
  }

  /**
   * Called whenever the Description is updated. Update the Patch checkbox when needed.
   */
  descriptionOnInput() {
    const isPatch = !!this.description.match(/^patch\b/i);

    if (isPatch !== this.$isPatch.checked) {
      this.updateIsPatch(isPatch);
    }

    this.descriptionOverridden = !!this.description;
    this.updateValidation();
  }

  /**
   * Clear the validation error on the Description field if the description is non-empty.
   */
  updateValidation() {
    if (this.description) {
      this.$description.setAttribute('aria-invalid', 'false');
      this.$descError.hidden = true;
    }
  }

  /**
   * Select a Content Type from the list or fill in the “enter manually” field if the option is not
   * available.
   * @param {string} type A detected MIME type.
   */
  updateContentType(type) {
    if ([...this.$typeSelect.options].find(($option) => $option.value === type)) {
      this.$typeList.checked = true;
      this.$typeSelect.value = type;
      this.$typeInput.value = '';
    } else {
      this.$typeManual.checked = true;
      this.$typeInput.value = type;
    }
  }

  /**
   * Update the Patch checkbox state.
   * @param {boolean} [checked] The `checked` property of the checkbox.
   * @param {boolean} [disabled] The `disabled` property of the checkbox.
   */
  updateIsPatch(checked = false, disabled = false) {
    this.$isPatch.checked = checked;
    this.$isPatch.disabled = disabled;
    this.isPatchOnChange();
  }

  /**
   * Enable or disable all content type input fields.
   * @param {boolean} disabled - Whether to disable the fields.
   */
  setTypeFieldsDisabled(disabled) {
    this.$typeOuter.querySelectorAll('[name]').forEach(($input) => ($input.disabled = disabled));
  }

  /**
   * Select the appropriate content type selection mode (dropdown list or manual input).
   * @param {string} mode - Either 'list' or 'manual'.
   */
  selectContentTypeMode(mode) {
    if (mode === 'manual') {
      this.$typeManual.checked = true;
    } else {
      this.$typeList.checked = true;
      this.$typeSelect.options[0].selected = true;
    }
  }

  /**
   * Called whenever the Patch checkbox is checked or unchecked. Disable or enable the Content Type
   * fields accordingly.
   */
  isPatchOnChange() {
    const isPatch = this.$isPatch.checked;
    const isGhpr = this.$typeInput.value === 'text/x-github-pull-request';

    this.setTypeFieldsDisabled(isPatch);

    if (isPatch) {
      this.updateContentType('text/plain');
    }

    // Reassign the bug to the user if the attachment is a patch or GitHub Pull Request
    if (this.$takeBug && this.$takeBug.clientHeight > 0 && this.$takeBug.dataset.takeIfPatch) {
      this.$takeBug.checked = isPatch || isGhpr;
    }
  }

  /**
   * Called whenever the “hide preview” checkbox is checked or unchecked. Change the Content Type to
   * binary if checked so the file will always be downloaded.
   */
  hidePreviewOnChange() {
    const hidePreview = this.$hidePreview.checked;

    this.setTypeFieldsDisabled(hidePreview);

    if (hidePreview) {
      this.originalType = this.$typeInput.value || this.$typeSelect.value;
      this.updateContentType('application/octet-stream');
    } else if (this.originalType) {
      this.updateContentType(this.originalType);
    }
  }

  /**
   * Called whenever an option is selected from the Content Type list. Select the “select from list”
   * radio button.
   */
  typeSelectOnChange() {
    this.selectContentTypeMode('list');
  }

  /**
   * Called whenever the used manually specified the Content Type. Select the “select from list” or
   * “enter manually” radio button depending on the value.
   */
  typeInputOnChange() {
    const mode = this.$typeInput.value ? 'manual' : 'list';

    this.selectContentTypeMode(mode);
  }

  /**
   * Update the required state of the form.
   * @param {boolean} [required] `true` if an attachment is required, `false` otherwise.
   */
  updateRequirements(required = true) {
    this.$placeholder.dataset.required = required;
    this.$description.setAttribute('aria-required', required);

    if (!required) {
      this.$description.setAttribute('aria-invalid', 'false');
      this.$descError.hidden = true;
    }

    this.selector.updateRequirements(required);
  }

  /**
   * Validate the form on submission. Show an error message if the attachment is required but not
   * provided, and prevent the form from being submitted.
   * @param {MouseEvent | SubmitEvent} event A `submit` event from the form or a `click` event from
   * the submit button.
   * @returns {boolean} `true` if the form is valid and can be submitted, `false` otherwise.
   */
  validate(event) {
    const invalid = this.required && !this.description;

    this.$description.setAttribute('aria-invalid', invalid);
    this.$descError.hidden = !invalid;

    if (invalid) {
      event.preventDefault();
    }

    return !invalid;
  }
};

window.addEventListener(
  'DOMContentLoaded',
  () => {
    // Automatically initialize the attachment form if the attachment entry table is present on the
    // page. This includes the New Bug and New Attachment pages.
    if (document.querySelector('table.attachment_entry')) {
      bzAttachmentForm = new Bugzilla.AttachmentForm();
    }
  },
  { once: true },
);
