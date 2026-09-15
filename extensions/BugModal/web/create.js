// @ts-check

window.addEventListener('DOMContentLoaded', () => {
  const $form = document.querySelector('#changeform');
  const $toggleAdvanced = document.querySelector('#toggle-advanced');
  const $componentDescription = document.querySelector('#component-description');
  const $defaultCcField = document.querySelector('#field-default-cc');
  const $defaultCcValue = document.querySelector('#field-value-default-cc');
  const $triageOwner = document.querySelector('#triage-owner');
  const $flagRows = document.querySelectorAll('#bug-flags tr, #attachment_flags .bz_flag_type');

  /** @type {string[]} */
  const componentDescriptions = JSON.parse($form.dataset.componentDescriptions);
  /** @type {string[]} */
  const descriptionTemplates = JSON.parse($form.dataset.descriptionTemplates);
  /** @type {string[]} */
  const defaultBugTypes = JSON.parse($form.dataset.defaultBugTypes);
  /** @type {string[]} */
  const defaultAssignees = JSON.parse($form.dataset.defaultAssignees);
  /** @type {string[]} */
  const defaultQaContacts = JSON.parse($form.dataset.defaultQaContacts);
  /** @type {string[]} */
  const defaultCcs = JSON.parse($form.dataset.defaultCcs);
  /** @type {string[]} */
  const triageOwners = JSON.parse($form.dataset.triageOwners);
  /** @type {number[][]} */
  const flags = JSON.parse($form.dataset.flags);
  /** @type {number[][]} */
  const keywords = JSON.parse($form.dataset.keywords);
  /** @type {object} */
  const statusCommentRequired = JSON.parse($form.dataset.statusCommentRequired);

  const params = new URLSearchParams(location.search);
  const useQaContact = !!defaultQaContacts.length;

  /** @type {string} */
  let lastSelectedAssignee;
  /** @type {string} */
  let lastSelectedQaContact;
  /** @type {boolean} */
  let bugTypeSpecified =
    params.has('bug_type') || params.has('cloned_bug_id') || params.has('regressed_by');

  // Change the description edit state if the comment text is already entered. This could happen if
  // the `comment` URL param is passed, the user has cloned other b[%%]ug, or the page is loaded
  // during session restore or from BFCache.
  /** @type {boolean} */
  let descriptionEdited = /\S/.test($form.comment.value);

  /**
   * Show or hide the advanced fields.
   * @param {boolean} showAdvanced Whether to show the advanced fields.
   * @param {boolean} [cache] Whether to cache the state.
   */
  const toggleAdvancedFields = (showAdvanced, cache = true) => {
    const advancedStateStr = showAdvanced ? 'show' : 'hide';

    $form.classList.toggle('show-advanced-fields', showAdvanced);
    $toggleAdvanced.textContent = $toggleAdvanced.dataset[advancedStateStr];

    if (cache) {
      Bugzilla.Storage.set('create-form.advanced', advancedStateStr);
    }
  };

  /**
   * Initialize the Enter Bug form.
   */
  const initForm = () => {
    const $makeTemplate = document.querySelector('#make-template');

    if ($toggleAdvanced) {
      // Check the local storage or the TUI cookie used on the legacy form to see if the user wants
      // to show advanced fields on the bug form.
      let showAdvanced =
        Bugzilla.Storage.get('create-form.advanced') === 'show'
          || /\bTUI=\S*?expert_fields=1\b/.test(document.cookie);

      if (showAdvanced) {
        toggleAdvancedFields(showAdvanced, false);
      }

      $toggleAdvanced.addEventListener('click', () => {
        showAdvanced = !showAdvanced;
        toggleAdvancedFields(showAdvanced);
      });
    }

    document.querySelectorAll('.edit-hide').forEach(($show) => {
      $show.style.display = 'none';
    });

    document.querySelectorAll('.edit-show').forEach(($show) => {
      $show.style.removeProperty('display');
    });

    // field.js
    $makeTemplate.addEventListener('click', () => {
      window.bz_no_validate_enter_bug = true;
    });

    // field.js
    window.status_comment_required = statusCommentRequired;

    // attachment.js
    bzAttachmentForm.updateRequirements(false);

    // bug_modal.js
    initKeywordsAutocomplete(keywords);
  };

  /**
   * Activate the Possible Duplicates table.
   */
  const initSummarySection = () => {
    Bugzilla.DupTable.init({
      container: '#possible_duplicates',
      columns: [
        {
          key: 'id',
          label: 'ID',
          formatter: Bugzilla.DupTable.formatBugLink,
          allowHTML: true,
        },
        {
          key: 'summary',
          label: 'Summary',
        },
        {
          key: 'status',
          label: 'Status/Resolution',
          formatter: Bugzilla.DupTable.formatStatus,
        },
        {
          key: 'update_token',
          label: 'Action',
          formatter: Bugzilla.DupTable.formatCcButton,
          allowHTML: true,
          sortable: false,
        },
      ],
      strings: {
        LOADING: 'Searching for possible duplicates...',
        EMPTY: 'No possible duplicates found.',
        TITLE: 'Possible Duplicates',
      },
      summary_field: 'short_desc',
      product_name: document.querySelector('input[name="product"]').value,
    });
  };

  /**
   * Update various values and labels on the form based on the select component, including Bug Type,
   * Assignee, QA Contact, Triage Owner, Default CC, Description and Flags.
   */
  const onComponentChange = () => {
    let index = -1;

    if ($form.component.type == 'select-one') {
      index = $form.component.selectedIndex;
    } else if ($form.component.type == 'hidden') {
      // Assume there is only one component in the list
      index = 0;
    }

    if (index === -1) {
      return;
    }

    const descriptionTemplate = descriptionTemplates[index];
    const defaultAssignee = defaultAssignees[index];
    const defaultQaContact = defaultQaContacts[index];
    const availableFlags = flags[index];

    if (!bugTypeSpecified) {
      $form.bug_type.value = defaultBugTypes[index];
    }

    // Fill the Description field with the product- or component-specific template if defined. Skip
    // if the Description is edited by the user.
    if (
      (!descriptionEdited && $form.comment.value !== descriptionTemplate) ||
      !$form.comment.value
    ) {
      $form.comment.value = descriptionTemplate;
    }

    if (
      $form.assigned_to &&
      [lastSelectedAssignee, defaultAssignee, ''].includes($form.assigned_to.value)
    ) {
      $form.assigned_to.value = lastSelectedAssignee = defaultAssignee;
    }

    if (
      useQaContact &&
      $form.qa_contact &&
      [lastSelectedQaContact, defaultQaContact, ''].includes($form.qa_contact.value)
    ) {
      $form.qa_contact.value = lastSelectedQaContact = defaultQaContact;
    }

    $defaultCcField.classList.toggle('bz_default_hidden', !defaultCcs[index]);
    $defaultCcValue.innerHTML = defaultCcs[index] || '<em>None</em>';
    $triageOwner.innerHTML = triageOwners[index] || '<em>None</em>';

    $componentDescription.innerHTML = componentDescriptions[index];
    $form.component.querySelector('[aria-describedby]')?.removeAttribute('aria-describedby');
    $form.component.options[index].setAttribute('aria-describedby', 'component-description');

    // We show or hide the available flags depending on the selected component.
    $flagRows.forEach(($row) => {
      // Each flag table row should have one flag form select element
      // We get the flag type id from the id attribute of the select.
      const $select = $row.querySelector('select');
      const canShow = availableFlags.includes(Number($select.id.split('-')[1]));
      const canSet = $select.options.length > 1;

      $select.disabled = $row.hidden = !(canShow && canSet);
    });
  };

  /**
   * Update the Platform and OS fields.
   * @param {object} platform Platform info.
   */
  const setPlatform = ({ platform, system }) => {
    $form.rep_platform.value = platform;
    $form.op_sys.value = system;
  };

  /**
   * Initialize the fields in the Categories section.
   */
  const initCategoriesSection = () => {
    if (!bugTypeSpecified) {
      $form.querySelector('#bug_type').addEventListener(
        'change',
        () => {
          bugTypeSpecified = true;
        },
        { once: true },
      );
    }

    if (!descriptionEdited) {
      $form.comment.addEventListener(
        'input',
        () => {
          descriptionEdited = true;
        },
        { once: true },
      );
    }

    // Select the first component if there is only one
    if ($form.component.options.length === 1) {
      $form.component.selectedIndex = 0;
    } else {
      $form.component.addEventListener('change', () => {
        onComponentChange();
      });
    }

    onComponentChange();

    document.querySelector('#use-my-platform').addEventListener('click', (event) => {
      setPlatform(event.target.dataset);
    });

    document.querySelector('#use-all-platforms').addEventListener('click', (event) => {
      setPlatform(event.target.dataset);
    });
  };

  /**
   * Initialize the fields in the Attachment section.
   */
  const initAttachmentSection = () => {
    const $attachNewFile = document.querySelector('#attach-new-file');
    const $attachFileContentOuter = document.querySelector('#attach-file-content-outer');
    const $attachNoFile = document.querySelector('#attach-no-file');
    const $attachFileActionOuter = document.querySelector('#attach-file-action-outer');

    const updatedRequiredFields = (required) => {
      bzAttachmentForm.updateRequirements(required);
    };

    $attachNewFile.addEventListener('click', () => {
      $attachFileActionOuter.hidden = true;
      $attachFileContentOuter.hidden = false;
      updatedRequiredFields(true);
    });

    $attachNoFile.addEventListener('click', () => {
      $attachFileActionOuter.hidden = false;
      $attachFileContentOuter.hidden = true;

      // Reset all the input values under Attachment
      $form.attach_text.value = '';
      $form.description.value = '';
      $form.ispatch.checked = false;
      $form.hide_preview.checked = false;
      $form.contenttypemethod.checked = true;
      $form.contenttypeselection.selectedIndex = 0;
      $form.contenttypeentry.value = '';
      document.querySelectorAll('#attachment_flags select').forEach(($select) => {
        $select.selectedIndex = 0;
      });
      updatedRequiredFields(false);
    });

    updatedRequiredFields(false);
  };

  initForm();
  initSummarySection();
  initCategoriesSection();
  initAttachmentSection();
});
