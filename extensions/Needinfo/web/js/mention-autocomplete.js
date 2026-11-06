/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * This Source Code Form is "Incompatible With Secondary Licenses", as
 * defined by the Mozilla Public License, v. 2.0. */

/* global Bugzilla, BUGZILLA */

/**
 * Reference or define the Bugzilla app namespace.
 * @namespace
 */
var Bugzilla = Bugzilla || {}; // eslint-disable-line no-var

/**
 * GitHub-style `@nickname` autocompletion in comment text areas. Typing `@` and a couple of
 * characters lists accounts with a matching nickname. Picking one inserts `@nickname `.
 *
 * Mentions are resolved by nickname only (see `_extract_mentions` and `_users_for_mentions` in
 * extensions/Needinfo/Extension.pm), so only accounts with a nickname set are suggested. That is
 * what `/rest/user/suggest` returns for a `@`-prefixed `match`, so no dedicated endpoint is needed.
 *
 * The extension's `global/header-start` hook only loads this script on pages where a mention takes
 * effect when saved. It doesn't touch the text editor itself: listeners are delegated from the
 * document, and the `keydown` one runs in the capture phase so that Enter, Tab, Escape and the
 * arrow keys reach the open list before the editor's own shortcuts (e.g. list continuation on
 * Enter) see them.
 */
Bugzilla.MentionAutocomplete = class MentionAutocomplete {
  /**
   * Minimum number of characters after `@` before searching. `/rest/user/suggest` ignores matches
   * shorter than 3 characters, the `@` included.
   */
  static MIN_CHARS = 2;

  /** Debounce delay in milliseconds, the same as the user field autocomplete in js/field.js. */
  static DELAY = 250;

  /** Maximum number of suggestions shown. */
  static MAX_RESULTS = 8;

  /**
   * The `@nickname` being typed right before the caret. Mirrors `_extract_mentions`: the `@` must
   * not follow a word character, `@`, `.`, `/` or `-`, so email addresses and paths don't trigger
   * it, and the nickname uses the same character set.
   */
  static TRIGGER = /(?<![\p{Alphabetic}\p{M}\p{Nd}\p{Pc}@./-])@([\p{Alphabetic}\p{Nd}|._-]*)$/u;

  /** A nickname that `_extract_mentions` would parse back unchanged (it strips trailing `.|`). */
  static VALID_NICK = /^[\p{Alphabetic}\p{Nd}|._-]*[\p{Alphabetic}\p{Nd}_-]$/u;

  /**
   * A fenced code block, mirroring the one `_extract_mentions` removes: it closes on a line
   * starting with the same marker, both fence lines are included whole, and a fence that never
   * closes runs to the end of the text.
   */
  static FENCED_BLOCK = /^[ \t]*(`{3,}|~{3,})[\s\S]*?(?:^[ \t]*\1[^\n]*$|(?![\s\S]))/gm;

  /**
   * Initialize a new `MentionAutocomplete` instance, serving every comment `<textarea>` on the page.
   */
  constructor() {
    /** @type {HTMLTextAreaElement | null} The `<textarea>` the list is shown for. */
    this.$textarea = null;
    /** @type {number} Position of the `@` of the nickname being completed. */
    this.start = -1;
    /** @type {{ start: number, $textarea: HTMLTextAreaElement } | null} Mention Escape closed. */
    this.dismissed = null;
    /** @type {{ nick: string, real_name: string, gravatar?: string }[]} */
    this.suggestions = [];
    /** @type {number} Index of the highlighted suggestion. */
    this.index = -1;
    /** @type {number} */
    this.timer = 0;
    /** @type {number} Incremented to discard responses to outdated requests. */
    this.requestId = 0;
    /** @type {Map<string, Promise<any[]>>} Suggestions by lowercased query. */
    this.cache = new Map();
    /** @type {HTMLUListElement | null} Created on first use, as `<body>` may not exist yet. */
    this.$list = null;

    document.addEventListener('input', (event) => {
      if (!(/** @type {InputEvent} */ (event).isComposing) && this.isTarget(event.target)) {
        this.update(/** @type {HTMLTextAreaElement} */ (event.target));
      }
    });

    // Moving the caret by clicking or with keys that don't edit the text
    document.addEventListener('click', (event) => {
      if (this.isTarget(event.target)) {
        this.update(/** @type {HTMLTextAreaElement} */ (event.target));
      }
    });

    document.addEventListener('keyup', (event) => {
      if (
        ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key) &&
        this.isTarget(event.target)
      ) {
        this.update(/** @type {HTMLTextAreaElement} */ (event.target));
      }
    });

    document.addEventListener('keydown', (event) => this.onKeyDown(event), true);

    document.addEventListener('focusout', (event) => {
      if (event.target === this.$textarea) {
        this.close();
      }
    });

    window.addEventListener('resize', () => this.close());
  }

  /**
   * Whether the list is shown.
   * @type {boolean}
   */
  get isOpen() {
    return !!this.$list && !this.$list.hidden;
  }

  /**
   * Whether the given element is a comment `<textarea>` that should get suggestions.
   * @param {EventTarget | null} $element Element.
   * @returns {boolean} Result.
   */
  isTarget($element) {
    return $element instanceof HTMLTextAreaElement && $element.name === 'comment';
  }

  /**
   * Find the `@nickname` being typed at the caret.
   * @param {HTMLTextAreaElement} $textarea Comment `<textarea>`.
   * @returns {{ query: string, start: number } | null} The partial nickname and the position of its
   * `@`, or `null` if the caret isn't at the end of a mention.
   */
  findMention($textarea) {
    const { value, selectionStart, selectionEnd } = $textarea;

    if (selectionStart !== selectionEnd) {
      return null;
    }

    const match = value.slice(0, selectionStart).match(MentionAutocomplete.TRIGGER);

    // Don't complete in the middle of a word
    if (!match || /^[\p{Alphabetic}\p{Nd}|._-]/u.test(value.slice(selectionStart))) {
      return null;
    }

    const start = selectionStart - match[1].length - 1;

    return MentionAutocomplete.isIgnored(value, start) ? null : { query: match[1], start };
  }

  /**
   * Whether a mention at the given position is ignored by `_extract_mentions` because it's on a
   * quoted line, in a fenced code block or in a code span.
   * @param {string} text Comment text.
   * @param {number} position Position of the `@`.
   * @returns {boolean} Result.
   */
  static isIgnored(text, position) {
    if (/^[ \t]*>/.test(/** @type {string} */ (text.slice(0, position).split('\n').at(-1)))) {
      return true;
    }

    // Like `_extract_mentions`, drop fenced blocks before looking for code spans. Blank them
    // instead of removing them to keep offsets. A blanked block still separates paragraphs.
    let inFence = false;
    const masked = text.replace(MentionAutocomplete.FENCED_BLOCK, (block, _marker, offset) => {
      inFence ||= position >= offset && position < offset + block.length;

      return block.replace(/[^\n]/g, ' ');
    });

    if (inFence) {
      return true;
    }

    // A code span opens and closes on backtick runs of the same length within a paragraph.
    const before = masked.slice(0, position);
    const paragraphStart = [...before.matchAll(/\n[ \t]*\n/g)].at(-1)?.index ?? 0;
    const paragraphEnd = masked.slice(position).search(/\n[ \t]*\n/);
    const paragraph = masked.slice(
      paragraphStart,
      paragraphEnd < 0 ? undefined : position + paragraphEnd,
    );
    const runs = [...paragraph.matchAll(/`+/g)].map((m) => ({
      at: paragraphStart + /** @type {number} */ (m.index),
      length: m[0].length,
    }));

    for (let i = 0; i < runs.length; i++) {
      const j = runs.findIndex((run, k) => k > i && run.length === runs[i].length);

      if (j > -1) {
        if (position > runs[i].at && position < runs[j].at) {
          return true;
        }

        i = j;
      }
    }

    return false;
  }

  /**
   * Show, update or hide the list for the text at the caret.
   * @param {HTMLTextAreaElement} $textarea Comment `<textarea>`.
   */
  update($textarea) {
    const mention = this.findMention($textarea);

    if (!mention) {
      this.dismissed = null;
      this.close();

      return;
    }

    const { query, start } = mention;

    if (
      query.length < MentionAutocomplete.MIN_CHARS ||
      (this.dismissed?.$textarea === $textarea && this.dismissed.start === start)
    ) {
      this.close();

      return;
    }

    // Don't leave suggestions for an older query selectable while the new one is fetched: keep
    // only those still matching what's typed, so the list doesn't flicker on every keystroke
    if (this.isOpen && this.$textarea === $textarea && this.start === start) {
      const prefix = query.toLowerCase();
      const matching = this.suggestions.filter(({ nick }) =>
        nick.toLowerCase().startsWith(prefix),
      );

      if (matching.length) {
        this.show(matching);
      } else {
        this.close();
      }
    } else {
      this.close();
    }

    this.$textarea = $textarea;
    this.start = start;

    window.clearTimeout(this.timer);

    const requestId = ++this.requestId;

    this.timer = window.setTimeout(async () => {
      const users = await this.fetch(query);
      // The caret may have moved without an `input` event, e.g. with ArrowUp/ArrowDown
      const current = this.findMention($textarea);

      if (
        requestId === this.requestId &&
        document.activeElement === $textarea &&
        current?.start === start &&
        current.query === query
      ) {
        this.show(users);
      }
    }, MentionAutocomplete.DELAY);
  }

  /**
   * Fetch the accounts whose nickname starts with the given text.
   * @param {string} query Partial nickname.
   * @returns {Promise<{ nick: string, real_name: string, gravatar?: string }[]>} Accounts.
   */
  fetch(query) {
    const key = query.toLowerCase();

    if (!this.cache.has(key)) {
      // Set by the `global/header-start` hook. Accounts that can't see the bug are left out, as
      // `_mentioned_users` drops them on save
      const bugId = BUGZILLA.mention_autocomplete?.bug_id;
      const request = Bugzilla.API.get('user/suggest', {
        match: `@${query}`,
        ...(bugId ? { bug_id: bugId } : {}),
        include_fields: 'name,real_name,nick,gravatar',
      })
        .then(({ users }) => {
          // An account can't mention itself, and a nickname shared by more than one account is
          // ambiguous and isn't resolved at all (see `_users_for_mentions`)
          const counts = new Map();

          users.forEach(({ nick }) => {
            counts.set(nick.toLowerCase(), (counts.get(nick.toLowerCase()) ?? 0) + 1);
          });

          return users.filter(
            ({ name, nick }) =>
              name !== BUGZILLA.user.login &&
              counts.get(nick.toLowerCase()) === 1 &&
              MentionAutocomplete.VALID_NICK.test(nick),
          );
        })
        .catch(() => {
          this.cache.delete(key);

          return [];
        });

      this.cache.set(key, request);
    }

    return /** @type {Promise<any[]>} */ (this.cache.get(key));
  }

  /**
   * Create the list element.
   * @returns {HTMLUListElement} List.
   */
  createList() {
    const $list = document.createElement('ul');

    $list.id = 'mention-autocomplete';
    $list.className = 'mention-autocomplete autocomplete-suggestions';
    $list.setAttribute('role', 'listbox');
    $list.setAttribute('aria-label', BUGZILLA.string.MentionAutocomplete?.label ?? '');
    $list.hidden = true;

    // Keep the focus in the `<textarea>`
    $list.addEventListener('mousedown', (event) => event.preventDefault());

    $list.addEventListener('click', (event) => {
      const $option = /** @type {HTMLElement} */ (event.target).closest('[role="option"]');

      if ($option) {
        this.select(Number(/** @type {HTMLElement} */ ($option).dataset.index));
      }
    });

    document.body.appendChild($list);

    return $list;
  }

  /**
   * Show the given suggestions below the caret.
   * @param {{ nick: string, real_name: string, gravatar?: string }[]} users Accounts.
   */
  show(users) {
    if (!users.length || !this.$textarea) {
      this.close();

      return;
    }

    this.$list ??= this.createList();
    this.suggestions = users.slice(0, MentionAutocomplete.MAX_RESULTS);
    this.$list.innerHTML = this.suggestions
      .map(({ nick, real_name, gravatar }, index) => {
        const image = gravatar
          ? `<img itemprop="image" alt="" src="${gravatar.htmlEncode()}">`
          : '';

        return (
          `<li id="mention-autocomplete-${index}" class="autocomplete-suggestion" role="option" ` +
          `aria-selected="false" data-index="${index}">` +
          `<div itemscope itemtype="http://schema.org/Person">${image} ` +
          `<span itemprop="name">${(real_name || nick).htmlEncode()}</span> ` +
          `<span class="minor" itemprop="alternateName">@${nick.htmlEncode()}</span></div></li>`
        );
      })
      .join('');

    this.$list.hidden = false;
    this.$textarea.setAttribute('aria-autocomplete', 'list');
    this.$textarea.setAttribute('aria-controls', this.$list.id);
    // Position first: highlighting scrolls the option into view, which would scroll the page to
    // wherever the list was appended
    this.position();
    this.highlight(0);
  }

  /**
   * Place the list below the `@` of the nickname being completed.
   */
  position() {
    const $textarea = /** @type {HTMLTextAreaElement} */ (this.$textarea);
    const $list = /** @type {HTMLUListElement} */ (this.$list);
    const rect = $textarea.getBoundingClientRect();
    const caret = MentionAutocomplete.getCaretOffset($textarea, this.start);
    const left = Math.min(
      rect.left + Math.max(0, Math.min(caret.left, rect.width)),
      document.documentElement.clientWidth - $list.offsetWidth - 8,
    );
    const top = rect.top + Math.max(0, Math.min(caret.top + caret.height, rect.height));

    $list.style.left = `${Math.max(0, left) + window.scrollX}px`;
    $list.style.top = `${top + window.scrollY}px`;
  }

  /**
   * Get the position of a character in a `<textarea>`, relative to the element's border box, by
   * laying out a copy of its text in a hidden element with the same styles.
   * @param {HTMLTextAreaElement} $textarea `<textarea>`.
   * @param {number} position Character position.
   * @returns {{ top: number, left: number, height: number }} Offset and line height.
   */
  static getCaretOffset($textarea, position) {
    const style = window.getComputedStyle($textarea);
    const $mirror = document.createElement('div');
    const $marker = document.createElement('span');

    [
      'boxSizing',
      'width',
      'height',
      'overflowX',
      'overflowY',
      'borderTopWidth',
      'borderRightWidth',
      'borderBottomWidth',
      'borderLeftWidth',
      'borderStyle',
      'paddingTop',
      'paddingRight',
      'paddingBottom',
      'paddingLeft',
      'fontFamily',
      'fontSize',
      'fontStyle',
      'fontVariant',
      'fontWeight',
      'fontStretch',
      'lineHeight',
      'letterSpacing',
      'wordSpacing',
      'tabSize',
      'textIndent',
      'textTransform',
    ].forEach((prop) => {
      $mirror.style[prop] = style[prop];
    });

    Object.assign($mirror.style, {
      position: 'absolute',
      top: '0',
      left: '-9999px',
      visibility: 'hidden',
      whiteSpace: 'pre-wrap',
      overflowWrap: 'break-word',
    });

    $mirror.textContent = $textarea.value.slice(0, position);
    $marker.textContent = '@';
    $mirror.appendChild($marker);
    document.body.appendChild($mirror);

    const offset = {
      top: $marker.offsetTop + parseFloat(style.borderTopWidth) - $textarea.scrollTop,
      left: $marker.offsetLeft + parseFloat(style.borderLeftWidth) - $textarea.scrollLeft,
      height: $marker.offsetHeight,
    };

    $mirror.remove();

    return offset;
  }

  /**
   * Highlight a suggestion.
   * @param {number} index Index of the suggestion, wrapping around at either end.
   */
  highlight(index) {
    const $list = /** @type {HTMLUListElement} */ (this.$list);
    const count = this.suggestions.length;

    this.index = (index + count) % count;

    $list.querySelectorAll('[role="option"]').forEach(($option, i) => {
      $option.classList.toggle('autocomplete-selected', i === this.index);
      $option.setAttribute('aria-selected', String(i === this.index));
    });

    $list.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' });
    this.$textarea?.setAttribute('aria-activedescendant', `mention-autocomplete-${this.index}`);
  }

  /**
   * Replace the nickname being typed with the selected one, followed by a space.
   * @param {number} index Index of the suggestion.
   */
  select(index) {
    const user = this.suggestions[index];
    const $textarea = this.$textarea;

    // Make sure the caret still ends the mention, so no other text gets replaced
    if (!user || !$textarea || this.findMention($textarea)?.start !== this.start) {
      this.close();

      return;
    }

    const end = $textarea.selectionStart;
    const spaceFollows = /^\s/.test($textarea.value.slice(end));
    const text = spaceFollows ? `@${user.nick}` : `@${user.nick} `;

    this.close();
    $textarea.focus();
    $textarea.setSelectionRange(this.start, end);

    // Like `TextEditor.updateText()`, use `execCommand` to keep the undo stack. It also fires the
    // `input` event that resizes the `<textarea>`.
    if (!document.execCommand('insertText', false, text)) {
      $textarea.setRangeText(text, this.start, end, 'end');
      $textarea.dispatchEvent(new InputEvent('input', { bubbles: true }));
    }

    if (spaceFollows) {
      const caret = $textarea.selectionStart + 1;

      $textarea.setSelectionRange(caret, caret);
    }

    // Inserting the text fired `input` with the caret still after the nickname, which scheduled
    // another search
    this.close();
  }

  /**
   * Hide the list and cancel any pending search.
   */
  close() {
    window.clearTimeout(this.timer);
    this.requestId++;

    if (this.$list) {
      this.$list.hidden = true;
    }

    ['aria-autocomplete', 'aria-controls', 'aria-activedescendant'].forEach((attr) => {
      this.$textarea?.removeAttribute(attr);
    });

    this.suggestions = [];
    this.index = -1;
  }

  /**
   * Handle the keys that operate the list while it's shown.
   * @param {KeyboardEvent} event `keydown` event.
   */
  onKeyDown(event) {
    if (
      !this.isOpen ||
      event.target !== this.$textarea ||
      event.isComposing ||
      event.altKey ||
      event.ctrlKey ||
      event.metaKey ||
      event.shiftKey
    ) {
      return;
    }

    // The selection may have changed without an `update()`, e.g. with Ctrl+A or Shift+ArrowDown.
    // Leave the key to its default action then.
    const $textarea = /** @type {HTMLTextAreaElement} */ (this.$textarea);

    if (this.findMention($textarea)?.start !== this.start) {
      this.close();

      return;
    }

    const action = {
      ArrowDown: () => this.highlight(this.index + 1),
      ArrowUp: () => this.highlight(this.index - 1),
      Enter: () => this.select(this.index),
      Tab: () => this.select(this.index),
      Escape: () => {
        // Don't reopen until the caret leaves this mention
        this.dismissed = {
          $textarea: /** @type {HTMLTextAreaElement} */ (this.$textarea),
          start: this.start,
        };
        this.close();
      },
    }[event.key];

    if (action) {
      event.preventDefault();
      event.stopPropagation();
      action();
    }
  }
};

if (BUGZILLA.user?.login) {
  Bugzilla.mentionAutocomplete = new Bugzilla.MentionAutocomplete();
}
