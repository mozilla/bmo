/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * This Source Code Form is "Incompatible With Secondary Licenses", as
 * defined by the Mozilla Public License, v. 2.0. */

/* global Bugzilla, Prism */

/**
 * Reference or define the Bugzilla app namespace.
 * @namespace
 */
var Bugzilla = Bugzilla || {}; // eslint-disable-line no-var

/**
 * Implement a text editor with Markdown support and preview functionality.
 */
Bugzilla.TextEditor = class TextEditor {
  /**
   * Partial regular expression matching any characters, including line breaks.
   */
  anyChars = '[\\s\\S]*';

  /**
   * Initialize a new `TextEditor` instance.
   * @param {object} [options] Options for the instance.
   * @param {HTMLTextAreaElement} [options.$textarea] Existing plain `<textarea>` to be replaced
   * with the text editor. If omitted, a new `<textarea>` is created within the editor.
   * @param {boolean} [options.useMarkdown] Whether to use the Markdown features.
   * @param {string} [options.initialText] Initial text content used to check if the text is edited.
   * @param {string} [options.containerLabel] The `aria-label` attribute on the container element.
   */
  constructor({
    $textarea = undefined,
    useMarkdown = true,
    initialText = '',
    containerLabel = '',
  } = {}) {
    /** @type {string} */
    this.id = `text-editor-${Bugzilla.String.generateHash()}`;
    /** @type {Record<string, any>} */
    this.str = BUGZILLA.string.TextEditor;
    /** @type {boolean} */
    this.useMarkdown = useMarkdown;
    /** @type {string} */
    this.initialText = initialText;
    /** @type {string} */
    this.containerLabel = containerLabel ?? this.str.text_editor;

    /** @type {HTMLElement} */
    this.$container = this.createContainer();
    /** @type {HTMLElement} */
    this.$tabList = this.$container.querySelector('[role="tablist"]');
    /** @type {HTMLButtonElement} */
    this.$editTab = this.$container.querySelector('[role="tab"][data-command="edit"]');
    /** @type {HTMLElement} */
    this.$editTabPanel = this.$container.querySelector('[role="tabpanel"][data-id="edit"]');
    /** @type {HTMLButtonElement} */
    this.$previewTab = this.$container.querySelector('[role="tab"][data-command="preview"]');
    /** @type {HTMLElement} */
    this.$previewTabPanel = this.$container.querySelector('[role="tabpanel"][data-id="preview"]');
    /** @type {HTMLElement} */
    this.$toolbar = this.$container.querySelector('[role="toolbar"]');
    /** @type {HTMLTextAreaElement} */
    this.$textarea =
      $textarea ?? this.$editTabPanel.appendChild(document.createElement('textarea'));
    /** @type {HTMLElement} */
    this.$preview = this.$container.querySelector('.comment-text');

    new Bugzilla.Tabs(this.$tabList);

    this.$tabList.addEventListener('Select', (/** @type {CustomEvent} */ event) => {
      this.tabListOnSelect(event);
    });

    this.$textarea.addEventListener('input', (/** @type {InputEvent} */ event) => {
      this.textareaOnInput(event);
    });

    this.$textarea.addEventListener('paste', (/** @type {ClipboardEvent} */ event) => {
      this.textareaOnPaste(event);
    });

    this.togglePreviewTab();

    if (this.useMarkdown) {
      this.$toolbar.addEventListener('click', (event) => {
        if (/** @type {HTMLElement} */ (event.target).matches('button')) {
          this.buttonOnClick(event);
        }
      });

      Bugzilla.Event.activateKeyShortcuts(this.$textarea, {
        Enter: { handler: (event) => this.handleEnterKeyDown(event), preventDefault: false },
        'Accel+B': { handler: () => this.execCommand('bold') },
        'Accel+I': { handler: () => this.execCommand('italic') },
        'Accel+E': { handler: () => this.execCommand('code') },
        'Accel+K': { handler: () => this.execCommand('link') },
        'Accel+Shift+.': { handler: () => this.execCommand('quote') },
        'Accel+Shift+7': { handler: () => this.execCommand('numbered-list') },
        'Accel+Shift+8': { handler: () => this.execCommand('bulleted-list') },
      });
    }
  }

  /**
   * Create a container element.
   * @returns {HTMLElement} Created element.
   */
  createContainer() {
    const $placeholder = document.createElement('div');
    /** @param {string} key */
    const _ = (key) => this.str[key].htmlEncode();
    /** @param {string} shortcut */
    const ks = (shortcut) => Bugzilla.Event.formatKeyShortcut(shortcut);
    /** @type {{ text: string, href: string }[]} */
    const footerLinks = [];

    if (this.useMarkdown && this.str.markdown_link) {
      footerLinks.push(this.str.markdown_link);
    }

    if (this.str.etiquette_link) {
      footerLinks.push(this.str.etiquette_link);
    }

    if (this.str.guidelines_link) {
      footerLinks.push(this.str.guidelines_link);
    }

    $placeholder.innerHTML = `
      <section role="group" id="${this.id}" class="text-editor"
          aria-label="${this.containerLabel.htmlEncode()}">
        <header>
          <div role="tablist">
            <button type="button" role="tab" tabindex="0" data-command="edit" aria-selected="true"
                aria-controls="${this.id}-tabpanel-edit">
              ${_('edit')}
            </button>
            <button type="button" role="tab" tabindex="-1" data-command="preview"
                aria-disabled="true" aria-controls="${this.id}-tabpanel-preview">
              ${_('preview')}
            </button>
          </div>
          ${
            this.useMarkdown
              ? `
                <div role="toolbar" class="markdown-toolbar" aria-label="${_('toolbar_label')}">
                  <div role="group">
                    <button type="button" tabindex="0" class="ghost iconic"
                        title="${_('command_bold')} (${ks('Accel+B')})" data-command="bold">
                      <span class="icon" aria-hidden="true"></span>
                    </button>
                    <button type="button" tabindex="0" class="ghost iconic"
                        title="${_('command_italic')} (${ks('Accel+I')})" data-command="italic">
                      <span class="icon" aria-hidden="true"></span>
                    </button>
                    <button type="button" tabindex="0" class="ghost iconic"
                        title="${_('command_code')} (${ks('Accel+E')})" data-command="code">
                      <span class="icon" aria-hidden="true"></span>
                    </button>
                    <button type="button" tabindex="0" class="ghost iconic"
                        title="${_('command_link')} (${ks('Accel+K')})" data-command="link">
                      <span class="icon" aria-hidden="true"></span>
                    </button>
                  </div>
                  <div role="group">
                    <button type="button" tabindex="0" class="ghost iconic"
                        title="${_('command_heading')}" data-command="heading">
                      <span class="icon" aria-hidden="true"></span>
                    </button>
                    <button type="button" tabindex="0" class="ghost iconic"
                        title="${_('command_quote')} (${ks('Accel+Shift+.')})" data-command="quote">
                      <span class="icon" aria-hidden="true"></span>
                    </button>
                  </div>
                  <div role="group">
                    <button type="button" tabindex="0" class="ghost iconic"
                        title="${_('command_numbered_list')} (${ks('Accel+Shift+7')})"
                        data-command="numbered-list">
                      <span class="icon" aria-hidden="true"></span>
                    </button>
                    <button type="button" tabindex="0" class="ghost iconic"
                        title="${_('command_bulleted_list')} (${ks('Accel+Shift+8')})"
                        data-command="bulleted-list">
                      <span class="icon" aria-hidden="true"></span>
                    </button>
                  </div>
                </div>
              `
              : ''
          }
        </header>
        <div role="tabpanel" id="${this.id}-tabpanel-edit" data-id="edit"></div>
        <div role="tabpanel" id="${this.id}-tabpanel-preview" data-id="preview" hidden>
          <div class="comment-text ${this.useMarkdown ? 'markdown-body' : ''}"></div>
        </div>
        <footer class="comment-tips" hidden>
          ${footerLinks
            .map(({ href, text }) => `<a href="${href}" target="_blank">${text}</a>`)
            .join(' · ')}
        </footer>
      </section>
    `;

    return /** @type {HTMLElement} */ ($placeholder.firstElementChild);
  }

  /**
   * Check if the text is edited. Ignore leading/trailing white space(s) and additional empty
   * line(s) while comparing the changes.
   * @type {boolean}
   */
  get edited() {
    const text = this.$textarea.value.trim();
    const hasText = !!text;

    if (this.initialText) {
      return hasText && text !== this.initialText.trim();
    }

    return hasText;
  }

  /**
   * List of the toolbar button elements.
   * @type {HTMLButtonElement[]}
   */
  get toolbarButtons() {
    return this.$toolbar ? [...this.$toolbar.querySelectorAll('button')] : [];
  }

  /**
   * Disable or enable the toolbar buttons.
   */
  toggleToolbarButtons() {
    this.toolbarButtons.forEach(($button) => {
      $button.disabled = !$button.disabled;
    });
  }

  /**
   * Enable or disable the Preview tab depending on the content, usually when it's empty.
   */
  togglePreviewTab() {
    this.$previewTab.setAttribute('aria-disabled', String(!this.edited));
  }

  /**
   * Called whenever a tab is selected. Trigger a relevant action.
   * @param {CustomEvent} event `Select` custom event.
   */
  tabListOnSelect(event) {
    const { originalEvent, $newTab } = event.detail;

    if ($newTab.matches('[data-command="edit"]')) {
      this.toggleToolbarButtons();

      if (originalEvent.type === 'click') {
        this.$textarea.focus();
      }
    }

    if ($newTab.matches('[data-command="preview"]')) {
      this.toggleToolbarButtons();
      this.preview();
    }
  }

  /**
   * Called whenever a toolbar button is pressed. Trigger a command specified on the button.
   * @param {MouseEvent | KeyboardEvent} event `click` or `keydown` event.
   */
  buttonOnClick(event) {
    this.execCommand(/** @type {HTMLButtonElement} */ (event.target).dataset.command);
  }

  /**
   * Called whenever the `<textarea>` is edited. Disable the Preview tab if needed.
   * @param {InputEvent} event `input` event.
   */
  textareaOnInput(event) {
    if (event.isComposing) {
      return;
    }

    this.togglePreviewTab();
  }

  /**
   * Called whenever content is pasted to the `<textarea>`. If the pasted content is a URL and there
   * is a selection, insert a Markdown link with the URL and the selected text as the label.
   * @param {ClipboardEvent} event `paste` event.
   */
  textareaOnPaste(event) {
    const data = event.clipboardData?.getData('text');

    if (Bugzilla.String.isURL(data)) {
      const { start, end, beforeText, selectedText, afterText } = this.getSelection();

      // Check if the URL can be inserted as a Markdown link without breaking existing markup; if
      // the selected text is already a valid URL or part of a Markdown link, the pasted URL will be
      // inserted as plain text instead to avoid breaking the existing link.
      if (
        selectedText &&
        !Bugzilla.String.isURL(selectedText) &&
        !beforeText.endsWith('](') &&
        !afterText.startsWith(')')
      ) {
        event.preventDefault();

        this.updateText(`${beforeText}[${selectedText}](${data})${afterText}`, {
          start: start + 1,
          end: end + 1,
        });
      }
    }
  }

  /**
   * Get information related to the selected text in the `<textarea>`.
   * @returns {{ start: number, end: number, beforeText: string, selectedText: string, afterText:
   * string, selectedLines: string[] }} Selection range and relevant information.
   */
  getSelection() {
    const { value: text, selectionStart: start, selectionEnd: end } = this.$textarea;
    const selectedText = text.substring(start, end);
    const selectedLines = selectedText ? selectedText.split(/\n/) : [];

    return {
      start,
      end,
      beforeText: text.substring(0, start),
      selectedText,
      afterText: text.substring(end),
      selectedLines,
    };
  }

  /**
   * Update the text in the `<textarea>`.
   * @param {string} text Updated text content.
   * @param {object} [selection] Selection position.
   * @param {number} [selection.start] New selection start position.
   * @param {number} [selection.end] New selection end position.
   */
  updateText(text, { start, end } = {}) {
    this.$textarea.focus();
    this.$textarea.select();

    // Update the text while enabling undo/redo; don’t use `this.$textarea.value` as it breaks the
    // undo stack; the `execCommand` is duplicated, but there is no alternative
    document.execCommand('insertText', false, text);

    if (start !== undefined) {
      this.$textarea.setSelectionRange(start, end ?? start);
    }

    // Fire an event to resize the `<textarea>` if needed
    this.$textarea.dispatchEvent(new InputEvent('input'));
  }

  /**
   * Insert a Markdown link to the `<textarea>`, or remove an existing link.
   */
  insertLink() {
    const { start, end, beforeText, selectedText, afterText } = this.getSelection();
    const beforeMatch = beforeText.match(new RegExp(`^(${this.anyChars})\\[$`));
    const afterMatch = afterText.match(new RegExp(`^\\]\\(url\\)(${this.anyChars})$`));

    if (beforeMatch && afterMatch) {
      // Remove markup outside of the selection
      this.updateText(`${beforeMatch[1]}${selectedText}${afterMatch[1]}`, {
        start: start - 1,
        end: end - 1,
      });
    } else if (!selectedText || Bugzilla.String.isURL(selectedText)) {
      // Convert any URL to a markup, and let the user enter the label
      this.updateText(`${beforeText}[](${selectedText ?? 'url'})${afterText}`, {
        start: start + 1,
      });
    } else {
      // Convert any label to a markup, and let the user enter the URL
      this.updateText(`${beforeText}[${selectedText}](url)${afterText}`, {
        start: end + 3,
        end: end + 6,
      });
    }
  }

  /**
   * Insert an inline Markdown markup to the `<textarea>`, or remove an existing markup.
   * @param {string} marker Character(s) to be added before and after any selected text, e.g. "**"
   * for bold text.
   */
  insertInlineMarkup(marker) {
    const { start, end, beforeText, selectedText, afterText } = this.getSelection();
    const escapedMarker = Bugzilla.String.escapeRegExp(marker);
    const beforeMatch = beforeText.match(new RegExp(`^(${this.anyChars})${escapedMarker}$`));
    const afterMatch = afterText.match(new RegExp(`^${escapedMarker}(${this.anyChars})$`));
    const insideMatch = selectedText.match(
      new RegExp(`^${escapedMarker}(${this.anyChars})${escapedMarker}$`),
    );

    if (beforeMatch && afterMatch) {
      // Remove markers outside of the selection
      this.updateText(`${beforeMatch[1]}${selectedText}${afterMatch[1]}`, {
        start: start - marker.length,
        end: end - marker.length,
      });
    } else if (insideMatch) {
      // Remove markers inside of the selection
      this.updateText(`${beforeText}${insideMatch[1]}${afterText}`, {
        start,
        end: end - marker.length * 2,
      });
    } else {
      // Add markers
      this.updateText(`${beforeText}${marker}${selectedText}${marker}${afterText}`, {
        start: start + marker.length,
        end: end + marker.length,
      });
    }
  }

  /**
   * Insert a block Markdown markup to the `<textarea>`, or remove an existing markup.
   * @param {string} marker Character(s) to be added at the beginning of each line, e.g. "-" for a
   * bulleted list.
   */
  insertBlockMarkup(marker) {
    const { start, beforeText, selectedText, afterText, selectedLines } = this.getSelection();
    const lineRegex = /^(#+|>|-|\*|\d+\.)\s+(.*)/;

    if (selectedText) {
      const lineMarkerRegex = new RegExp(
        `^${marker === '1.' ? '\\d+\\.' : Bugzilla.String.escapeRegExp(marker)}\\ (.*)`,
      );
      const beforeTextArray = beforeText.split(/\n/);
      const afterTextArray = afterText.split(/\n/);
      const beforeSelection = beforeTextArray.pop();
      const afterSelection = afterTextArray.shift();
      const _beforeText = beforeTextArray.length ? `${beforeTextArray.join('\n')}\n` : '';
      const _afterText = afterTextArray.length ? `\n${afterTextArray.join('\n')}` : '';

      if (beforeSelection) {
        selectedLines[0] = `${beforeSelection}${selectedLines[0]}`;
      }

      if (afterSelection) {
        const lastIndex = selectedLines.length - 1;

        selectedLines[lastIndex] = `${selectedLines[lastIndex]}${afterSelection}`;
      }

      if (selectedLines.every((chars) => chars.match(lineMarkerRegex))) {
        // Remove a marker from each line
        const text = selectedLines.map((chars) => chars.match(lineMarkerRegex)[1]).join('\n');
        const _start = start - [...beforeSelection].length;

        this.updateText(`${_beforeText}${text}${_afterText}`, {
          start: _start,
          end: _start + [...text].length,
        });
      } else {
        // Add or replace a marker on each line
        const text = selectedLines
          .map(
            (chars, i) =>
              `${marker === '1.' ? `${i + 1}.` : marker} ${chars.match(lineRegex)?.[2] ?? chars}`,
          )
          .join('\n');
        const _start = start - [...beforeSelection].length;

        this.updateText(`${_beforeText}${text}${_afterText}`, {
          start: _start,
          end: _start + [...text].length,
        });
      }
    } else {
      const beforeLines = beforeText.split(/\n/);
      let charCount = 0;
      let _start = start;

      // Add a marker to the current line
      beforeLines.forEach((chars, i) => {
        charCount += [...chars].length + /* line break */ (i > 0 ? 1 : 0);

        if (charCount === start) {
          const [, _marker, _chars] = chars.match(lineRegex) ?? [];

          if (_marker) {
            if (_marker === marker) {
              // Removing
              beforeLines[i] = _chars;
              _start += -marker.length - /* space */ 1;
            } else {
              // Replacing
              beforeLines[i] = `${marker} ${_chars ?? chars}`;
              _start += -_marker.length + marker.length;
            }
          } else {
            // Adding
            beforeLines[i] = `${marker} ${_chars ?? chars}`;
            _start += marker.length + /* space */ 1;
          }
        }
      });

      this.updateText(`${beforeLines.join('\n')}${afterText}`, {
        start: _start,
      });
    }
  }

  /**
   * Insert a wrapped block Markdown markup to the `<textarea>`, or remove an existing markup.
   * @param {string} marker Character(s) to be added before and after any selected text, e.g. "```"
   * for a code fencing.
   */
  insertWrapMarkup(marker) {
    const { start, end, beforeText, selectedText, afterText } = this.getSelection();
    const escapedMark = Bugzilla.String.escapeRegExp(marker);
    const beforeMatch = beforeText.match(new RegExp(`^(${this.anyChars}\n)?(${escapedMark}\n)$`));
    const afterMatch = afterText.match(new RegExp(`^(\n?${escapedMark})(\n${this.anyChars})?$`));
    const insideMatch = selectedText.match(
      new RegExp(`^${escapedMark}\n(${this.anyChars})\n${escapedMark}$`),
    );

    if (beforeMatch && afterMatch) {
      // Remove markup outside of the selection
      this.updateText(`${beforeMatch[1] ?? ''}${selectedText}${afterMatch[2] ?? ''}`, {
        start: start - [...beforeMatch[2]].length,
        end: end - [...afterMatch[1]].length,
      });
    } else if (insideMatch) {
      // Remove markup inside of the selection
      this.updateText(`${beforeText}${insideMatch[1]}${afterText}`, {
        start,
        end: end - marker.length * 2 - 2,
      });
    } else {
      // Wrap the selection with the markup
      const _before = beforeText.replace(/\n{1,2}$/, '');
      const _after = afterText.replace(/^\n{1,2}/, '');
      const _selection = selectedText.replace(/\n$/, '');
      const _start = [..._before].length + /* line breaks */ (_before ? 2 : 0) + marker.length + 1;

      this.updateText(
        `${_before}${_before ? '\n\n' : ''}${marker}\n${_selection}\n${marker}${
          _after ? '\n\n' : ''
        }${_after}`,
        {
          start: _start,
          end: _start + [..._selection].length,
        },
      );
    }
  }

  /**
   * Handle Enter key press. If the current line contains a list marker, e.g. `1.`, add a new line
   * with a marker prepended.
   * @param {KeyboardEvent} event `keydown` event.
   */
  handleEnterKeyDown(event) {
    const { start, selectedText, beforeText, afterText } = this.getSelection();

    if (selectedText) {
      return;
    }

    const beforeLines = beforeText.split(/\n/);
    let charCount = 0;
    let newMarker = '';
    let markerFound = false;

    beforeLines.forEach((chars, i) => {
      charCount += [...chars].length + /* line break */ (i > 0 ? 1 : 0);

      if (charCount === start) {
        const [, _marker, _chars] = chars.match(/^(-|\*|\d+\.)\s+(.*)/) ?? [];

        if (_marker) {
          markerFound = true;

          if (_chars) {
            newMarker = _marker.match(/^\d+/) ? `${parseInt(_marker) + 1}.` : _marker;
          } else {
            beforeLines[i] = '';
          }
        }
      }
    });

    if (!markerFound) {
      return;
    }

    event.preventDefault();

    if (newMarker) {
      this.updateText(`${beforeLines.join('\n')}\n${newMarker} ${afterText}`, {
        start: start + 1 + newMarker.length + 1,
      });
    } else {
      this.updateText(`${beforeLines.join('\n')}${afterText}`, {
        start: start - [...beforeText.split(/\n/).pop()].length,
      });
    }
  }

  /**
   * Execute a command on the `<textarea>`.
   * @param {string} command Command name like `bold`.
   */
  execCommand(command) {
    const { selectedLines } = this.getSelection();

    /** @type {Function | undefined} */
    const action = {
      bold: () => this.insertInlineMarkup('**'),
      italic: () => this.insertInlineMarkup('_'),
      code: () =>
        selectedLines.length > 1 ? this.insertWrapMarkup('```') : this.insertInlineMarkup('`'),
      link: () => this.insertLink(),
      heading: () => this.insertBlockMarkup('###'),
      quote: () => this.insertBlockMarkup('>'),
      'bulleted-list': () => this.insertBlockMarkup('-'),
      'numbered-list': () => this.insertBlockMarkup('1.'),
    }[command];

    if (action) {
      action();
    }
  }

  /**
   * Switch the comment edit and preview tabs if possible.
   * @param {KeyboardEvent} event `keydown` event.
   */
  switchTabs(event) {
    event.preventDefault();

    if (this.edited) {
      if (this.$previewTabPanel.hidden) {
        this.$previewTab.click();
      } else {
        this.$editTab.click();
      }
    }

    this.toggleToolbarButtons();
  }

  /**
   * Get the params sent to the comment render API when previewing.
   * @returns {Record<string, any>} Params.
   */
  getPreviewParams() {
    return { text: this.$textarea.value };
  }

  /**
   * Called whenever the Preview tab is selected. Fetch and display the rendered text if it's
   * edited.
   */
  async preview() {
    const params = this.getPreviewParams();
    const paramsKey = JSON.stringify(params);

    if (paramsKey === this.lastPreviewedParams) {
      return;
    }

    // Copy the current height: the tabpanel should be visible to get the `scrollHeight` property
    this.$editTabPanel.hidden = false;
    this.$preview.style.setProperty('height', `${this.$textarea.scrollHeight}px`);
    this.$editTabPanel.hidden = true;

    this.$preview.focus();
    this.$preview.setAttribute('aria-busy', 'true');
    this.$preview.innerHTML = `<p role="status">${this.str.loading.htmlEncode()}</p>`;

    try {
      const { html, mentions } = await Bugzilla.API.post('bug/comment/render', params);

      // Use the HTML without `htmlEncode()` because the API-provided rendered text should be safe
      // to be injected as is; using `htmlEncode()` rather breaks the text
      this.$preview.innerHTML = html;

      // List who saving the comment will CC and needinfo, so a stray `@word` is noticed before
      // the comment is submitted
      if (mentions?.length) {
        const users = mentions
          .map(({ nick, name }) => (name ? `${name} (@${nick})` : `@${nick}`).htmlEncode())
          .join(', ');

        this.$preview.insertAdjacentHTML(
          'afterbegin',
          `<p class="mention-notice">${this.str.mention_notice.htmlEncode()} ${users}</p>`,
        );
      }

      // Highlight code if possible
      if (Prism) {
        Prism.highlightAllUnder(this.$preview);
      }

      this.$preview.setAttribute('aria-busy', 'false');
      this.lastPreviewedParams = paramsKey;
    } catch (ex) {
      this.$preview.innerHTML = `
        <p role="alert" class="error">${this.str.preview_error.htmlEncode()}</p>
      `;
      this.$preview.setAttribute('aria-busy', 'false');
    }
  }
};

/**
 * Implement an enhanced comment editor that replaces a plain `<textarea>` on the bug page.
 */
Bugzilla.CommentEditor = class CommentEditor extends Bugzilla.TextEditor {
  /**
   * Initialize a new `CommentEditor` instance.
   * @param {object} [options] Options for the instance.
   * @param {HTMLTextAreaElement} [options.$textarea] Comment `<textarea>` to be replaced with the
   * text editor.
   * @param {boolean} [options.useMarkdown] Whether to use the Markdown features.
   * @param {string} [options.initialText] Initial text content used to check if the text is edited.
   * @param {boolean} [options.showTips] Whether to show the tips below the `<textarea>`.
   */
  constructor({
    $textarea = undefined,
    useMarkdown = true,
    initialText = '',
    showTips = true,
  } = {}) {
    super({
      $textarea,
      useMarkdown,
      initialText,
      containerLabel: BUGZILLA.string.TextEditor.comment_editor,
    });

    this.$container.classList.add('comment-editor');
    /** @type {HTMLElement} */ (this.$container.querySelector('footer.comment-tips')).hidden =
      !showTips;

    if (this.$textarea.hasAttribute('aria-label')) {
      this.$editTab.textContent = this.$textarea.getAttribute('aria-label');
    }

    /** @type {HTMLButtonElement | undefined} */
    this.$saveButton = this.$textarea.form?.querySelector('[type="submit"]') ?? undefined;

    if (this.$saveButton) {
      Bugzilla.Event.activateKeyShortcuts(this.$textarea, {
        'Accel+Enter': { handler: () => this.submitForm() },
      });
    }
  }

  /**
   * Replace the existing `<textarea>` with the enhanced comment editor.
   */
  render() {
    this.$textarea.insertAdjacentElement('afterend', this.$container);
    this.$editTabPanel.appendChild(this.$textarea);
  }

  /**
   * Get the params sent to the comment render API when previewing. A new comment on an existing
   * bug is rendered against that bug, and also asks for the users its `@nickname` mentions will
   * CC and needinfo.
   * @returns {Record<string, any>} Params.
   */
  getPreviewParams() {
    const params = super.getPreviewParams();
    const form = this.$textarea.form;
    const bugId = BUGZILLA.bug_id ?? form?.elements.namedItem('bugid')?.value;

    if (bugId && this.$textarea.name === 'comment') {
      params.id = bugId;
      params.include_mentions = true;
      params.mention_is_private = !!(
        form?.elements.namedItem('comment_is_private')?.checked ||
        form?.elements.namedItem('isprivate')?.checked
      );
    }

    return params;
  }

  /**
   * Submit the bug form if the comment is entered. Trigger a `click` event instead of submitting
   * the form directly to make sure any event handler associated with the button will be called.
   */
  submitForm() {
    if (this.edited) {
      this.$saveButton?.click();
    }
  }
};

window.addEventListener(
  'DOMContentLoaded',
  () => {
    const useMarkdown = BUGZILLA.param.use_markdown;

    document
      .querySelectorAll('textarea[name="comment"]:not(.bz_default_hidden)')
      .forEach((/** @type {HTMLTextAreaElement} */ $textarea) => {
        new Bugzilla.CommentEditor({ $textarea, useMarkdown }).render();
      });
  },
  { once: true },
);
