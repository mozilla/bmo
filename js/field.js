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
 * The Initial Developer of the Original Code is Everything Solved, Inc.
 * Portions created by Everything Solved are Copyright (C) 2007 Everything
 * Solved, Inc. All Rights Reserved.
 *
 * Contributor(s): Max Kanat-Alexander <mkanat@bugzilla.org>
 *                 Guy Pyrzak <guy.pyrzak@gmail.com>
 *                 Reed Loden <reed@reedloden.com>
 */

/**
 * Reference or define the Bugzilla app namespace.
 * @namespace
 */
var Bugzilla = Bugzilla || {}; // eslint-disable-line no-var

/**
 * Reference or define the Field namespace.
 * @namespace
 */
Bugzilla.Field = Bugzilla.Field || {};

/* This library assumes that the needed YUI libraries have been loaded
   already. */

var bz_no_validate_enter_bug = false;
function validateEnterBug(theform) {
    // This is for the "bookmarkable templates" button.
    if (bz_no_validate_enter_bug) {
        // Set it back to false for people who hit the "back" button
        bz_no_validate_enter_bug = false;
        return true;
    }

    var component = theform.component;
    var short_desc = theform.short_desc;
    var version = theform.version;
    var bug_status = theform.bug_status;
    var bug_type = theform.bug_type;
    var description = theform.comment;
    var attach_data = theform.data;
    var attach_desc = theform.description;

    const $bug_type_group = document.querySelector('#bug_type');

    theform.querySelectorAll('.validation_error_text').forEach(($error) => {
        $error.remove();
    });
    theform.querySelectorAll('.validation_error_field').forEach(($field) => {
        $field.classList.remove('validation_error_field');
    });

    var focus_me;

    // These are checked in the reverse order that they appear on the page,
    // so that the one closest to the top of the form will be focused.
    if (attach_data.value && attach_desc.value.trim() == '') {
        _errorFor(attach_desc, 'attach_desc');
        focus_me = attach_desc;
    }
    var check_description = status_comment_required[bug_status.value];
    if (check_description && description.value.trim() == '') {
        _errorFor(description, 'description');
        focus_me = description;
    }
    if (short_desc.value.trim() == '') {
        _errorFor(short_desc);
        focus_me = short_desc;
    }
    if (version.selectedIndex < 0) {
        _errorFor(version);
        focus_me = version;
    }
    if (component.selectedIndex < 0) {
        _errorFor(component);
        focus_me = component;
    }
    if ($bug_type_group.matches('[aria-required="true"]') && !bug_type.value) {
        _errorFor($bug_type_group);
        focus_me = bug_type[0];
    }

    if (focus_me) {
        focus_me.focus();
        return false;
    }

    return true;
}

function _errorFor(field, name) {
    if (!name) name = field.id;
    var string_name = name + '_required';
    var error_text = BUGZILLA.string[string_name];
    var new_node = document.createElement('div');
    new_node.classList.add('validation_error_text');
    new_node.innerHTML = error_text;
    field.insertAdjacentElement('afterend', new_node);
    field.classList.add('validation_error_field');
}

function setupEditLink(id) {
    var link_container = 'container_showhide_' + id;
    var input_container = 'container_' + id;
    var link = 'showhide_' + id;
    hideEditableField(link_container, input_container, link);
}

/* Hide input/select fields and show the text with (edit) next to it */
function hideEditableField( container, input, action, field_id, original_value, new_value, hide_input ) {
    document.getElementById(container).classList.remove('bz_default_hidden');
    document.getElementById(input).classList.add('bz_default_hidden');
    document.getElementById(action).addEventListener('click', (event) => {
        showEditableField(event, [container, input, field_id, new_value]);
    });
    if(field_id != ""){
        window.addEventListener('load', (event) => {
            checkForChangedFieldValues(event, [container, input, field_id, original_value, hide_input]);
        });
    }
}

/* showEditableField (e, ContainerInputArray)
 * Function hides the (edit) link and the text and displays the input/select field
 *
 * var e: the event
 * var ContainerInputArray: An array containing the (edit) and text area and the input being displayed
 * var ContainerInputArray[0]: the container that will be hidden usually shows the (edit) or (take) text
 * var ContainerInputArray[1]: the input area and label that will be displayed
 * var ContainerInputArray[2]: the input/select field id for which the new value must be set
 * var ContainerInputArray[3]: the new value to set the input/select field to when (take) is clicked
 */
function showEditableField (e, ContainerInputArray) {
    var inputs = new Array();
    var inputArea = document.getElementById(ContainerInputArray[1]);
    if ( ! inputArea ){
        e.preventDefault();
        return;
    }
    document.getElementById(ContainerInputArray[0]).classList.add('bz_default_hidden');
    inputArea.classList.remove('bz_default_hidden');
    if ( inputArea.tagName.toLowerCase() == "input" ) {
        inputs.push(inputArea);
    } else if (ContainerInputArray[2]) {
        inputs.push(document.getElementById(ContainerInputArray[2]));
    } else {
        inputs = inputArea.getElementsByTagName('input');
        if ( inputs.length == 0 )
            inputs = inputArea.getElementsByTagName('textarea');
    }
    if ( inputs.length > 0 ) {
        // Change the first field's value to ContainerInputArray[2]
        // if present before focusing.
        var type = inputs[0].tagName.toLowerCase();
        if (ContainerInputArray[3]) {
            if ( type == "input" ) {
                inputs[0].value = ContainerInputArray[3];
            } else {
                for (var i = 0; inputs[0].length; i++) {
                    if ( inputs[0].options[i].value == ContainerInputArray[3] ) {
                        inputs[0].options[i].selected = true;
                        break;
                    }
                }
            }
        }
        // focus on the first field, this makes it easier to edit
        inputs[0].focus();
        if ( type == "input" || type == "textarea" ) {
            inputs[0].select();
        }
    }
    e.preventDefault();
}


/* checkForChangedFieldValues(e, array )
 * Function checks if after the autocomplete by the browser if the values match the originals.
 *   If they don't match then hide the text and show the input so users don't get confused.
 *
 * var e: the event
 * var ContainerInputArray: An array containing the (edit) and text area and the input being displayed
 * var ContainerInputArray[0]: the container that will be hidden usually shows the (edit) text
 * var ContainerInputArray[1]: the input area and label that will be displayed
 * var ContainerInputArray[2]: the field that is on the page, might get changed by browser autocomplete
 * var ContainerInputArray[3]: the original value from the page loading.
 *
 */
function checkForChangedFieldValues(e, ContainerInputArray ) {
    var el = document.getElementById(ContainerInputArray[2]);
    var unhide = false;
    if ( el ) {
        if ( !ContainerInputArray[4]
             && (el.value != ContainerInputArray[3]
                 || (el.value == "" && el.id != "alias" && el.id != "qa_contact" && el.id != "bug_mentors")) )
        {

            unhide = true;
        }
        else {
            var set_default = document.getElementById("set_default_" +
                                                      ContainerInputArray[2]);
            if ( set_default ) {
                if(set_default.checked){
                    unhide = true;
                }
            }
        }
    }
    if(unhide){
        document.getElementById(ContainerInputArray[0]).classList.add('bz_default_hidden');
        document.getElementById(ContainerInputArray[1]).classList.remove('bz_default_hidden');
    }

}

function hideAliasAndSummary(short_desc_value, alias_value) {
    // check the short desc field
    hideEditableField( 'summary_alias_container','summary_alias_input',
                       'editme_action','short_desc', short_desc_value);
    // check that the alias hasn't changed
    var bz_alias_check_array = new Array('summary_alias_container',
                                     'summary_alias_input', 'alias', alias_value);
    window.addEventListener('load', (event) => {
        checkForChangedFieldValues(event, bz_alias_check_array);
    });
}

function showPeopleOnChange( field_id_list ) {
    field_id_list.forEach((id) => {
        document.getElementById(id).addEventListener('change', (event) => {
            showEditableField(event, ['bz_qa_contact_edit_container', 'bz_qa_contact_input']);
            showEditableField(event, ['bz_assignee_edit_container', 'bz_assignee_input']);
        });
    });
}

function assignToDefaultOnChange(field_id_list, default_assignee, default_qa_contact) {
    showPeopleOnChange(field_id_list);
    field_id_list.forEach((id) => {
        document.getElementById(id).addEventListener('change', (evt) => {
            if (document.getElementById('assigned_to').value == default_assignee) {
                setDefaultCheckbox(evt, 'set_default_assignee');
            }
            if (document.getElementById('qa_contact')
                && document.getElementById('qa_contact').value == default_qa_contact)
            {
                setDefaultCheckbox(evt, 'set_default_qa_contact');
            }
        });
    });
}

function initDefaultCheckbox(field_id){
    document.getElementById(`set_default_${field_id}`).addEventListener('change', (event) => {
        boldOnChange(event, `set_default_${field_id}`);
    });
    window.addEventListener('load', (event) => {
        checkForChangedFieldValues(
            event,
            [`bz_${field_id}_edit_container`, `bz_${field_id}_input`, `set_default_${field_id}`, '1']
        );
        boldOnChange(event, `set_default_${field_id}`);
    });
}

function showHideStatusItems(e, dupArrayInfo) {
    var el = document.getElementById('bug_status');
    // finish doing stuff based on the selection.
    if ( el ) {
        showDuplicateItem(el);

        // Make sure that fields whose visibility or values are controlled
        // by "resolution" behave properly when resolution is hidden.
        var resolution = document.getElementById('resolution');
        if (resolution && resolution.options[0].value != '') {
            resolution.bz_lastSelected = resolution.selectedIndex;
            var emptyOption = new Option('', '');
            resolution.insertBefore(emptyOption, resolution.options[0]);
            emptyOption.selected = true;
        }

        document.getElementById('resolution_settings').classList.add('bz_default_hidden');
        document.getElementById('duplicate_display')?.classList.add('bz_default_hidden');

        if ( (el.value == dupArrayInfo[1] && dupArrayInfo[0] == "is_duplicate")
             || bz_isValueInArray(close_status_array, el.value) )
        {
            document.getElementById('resolution_settings').classList.remove('bz_default_hidden');

            // Remove the blank option we inserted.
            if (resolution && resolution.options[0].value == '') {
                resolution.removeChild(resolution.options[0]);
                resolution.selectedIndex = resolution.bz_lastSelected;
            }
        }

        if (resolution) {
            bz_fireEvent(resolution, 'change');
        }
    }
}

function showDuplicateItem(e) {
    var resolution = document.getElementById('resolution');
    var bug_status = document.getElementById('bug_status');
    var dup_id = document.getElementById('dup_id');
    if (resolution) {
        if (resolution.value == 'DUPLICATE' && bz_isValueInArray( close_status_array, bug_status.value) ) {
            // hide resolution show duplicate
            document.getElementById('duplicate_settings').classList.remove('bz_default_hidden');
            document.getElementById('dup_id_discoverable').classList.add('bz_default_hidden');
            // check to make sure the field is visible or IE throws errors
            if( !dup_id.matches('.bz_default_hidden') ){
                dup_id.focus();
                dup_id.select();
            }
        }
        else {
            document.getElementById('duplicate_settings').classList.add('bz_default_hidden');
            document.getElementById('dup_id_discoverable').classList.remove('bz_default_hidden');
            dup_id.blur();
        }
    }
}

function setResolutionToDuplicate(e, duplicate_or_move_bug_status) {
    var status = document.getElementById('bug_status');
    var resolution = document.getElementById('resolution');
    document.getElementById('dup_id_discoverable').classList.add('bz_default_hidden');
    status.value = duplicate_or_move_bug_status;
    bz_fireEvent(status, 'change');
    resolution.value = "DUPLICATE";
    bz_fireEvent(resolution, 'change');
    e.preventDefault();
}

function setDefaultCheckbox(e, field_id) {
    var el = document.getElementById(field_id);
    var elLabel = document.getElementById(field_id + "_label");
    if( el && elLabel ) {
        el.checked = "true";
        elLabel.style.setProperty('font-weight', 'bold');
    }
}

function boldOnChange(e, field_id){
    var el = document.getElementById(field_id);
    var elLabel = document.getElementById(field_id + "_label");
    if( el && elLabel ) {
        elLabel.style.setProperty('font-weight', el.checked ? 'bold' : 'normal');
    }
}

function updateCommentTagControl(checkbox, field) {
    field.classList.toggle('bz_private', checkbox.checked);
}

/**
 * Reset the value of the classification field and fire an event change
 * on it.  Called when the product changes, in case the classification
 * field (which is hidden) controls the visibility of any other fields.
 */
function setClassification() {
    var classification = document.getElementById('classification');
    var product = document.getElementById('product');
    var selected_product = product.value;
    var select_classification = all_classifications[selected_product];
    classification.value = select_classification;
    bz_fireEvent(classification, 'change');
}

/**
 * Says that a field should only be displayed when another field has
 * a certain value. May only be called after the controller has already
 * been added to the DOM.
 */
function showFieldWhen(controlled_id, controller_id, values) {
    var controller = document.getElementById(controller_id);
    // Note that we don't get an object for "controlled" here, because it
    // might not yet exist in the DOM. We just pass along its id.
    controller.addEventListener('change', (event) => {
        handleVisControllerValueChange(event, [controlled_id, controller, values]);
    });
}

/**
 * Called by showFieldWhen when a field's visibility controller
 * changes values.
 */
function handleVisControllerValueChange(e, args) {
    var controlled_id = args[0];
    var controller = args[1];
    var values = args[2];

    var label_container =
        document.getElementById('field_label_' + controlled_id);
    var field_container =
        document.getElementById('field_container_' + controlled_id);
    var selected = false;
    for (var i = 0; i < values.length; i++) {
        if (bz_valueSelected(controller, values[i])) {
            selected = true;
            break;
        }
    }

    label_container.classList.toggle('bz_hidden_field', !selected);
    field_container.classList.toggle('bz_hidden_field', !selected);
}

function showValueWhen(controlled_field_id, controlled_value_ids,
                       controller_field_id, controller_value_id)
{
    var controller_field = document.getElementById(controller_field_id);
    // Note that we don't get an object for the controlled field here,
    // because it might not yet exist in the DOM. We just pass along its id.
    controller_field.addEventListener('change', (event) => {
        handleValControllerChange(
            event,
            [controlled_field_id, controlled_value_ids, controller_field, controller_value_id]
        );
    });
}

function handleValControllerChange(e, args) {
    var controlled_field = document.getElementById(args[0]);
    var controlled_value_ids = args[1];
    var controller_field = args[2];
    var controller_value_id = args[3];

    var controller_item = document.getElementById(
        _value_id(controller_field.id, controller_value_id));

    for (var i = 0; i < controlled_value_ids.length; i++) {
        var item = getPossiblyHiddenOption(controlled_field,
                                           controlled_value_ids[i]);
        if (item.disabled && controller_item && controller_item.selected) {
            item.classList.remove('bz_hidden_option');
            item.disabled = false;
        }
        else if (!item.disabled && controller_item && !controller_item.selected) {
            item.classList.add('bz_hidden_option');
            if (item.selected) {
                item.selected = false;
                bz_fireEvent(controlled_field, 'change');
            }
            item.disabled = true;
        }
    }
}

// A convenience function to generate the "id" tag of an <option>
// based on the numeric id that Bugzilla uses for that value.
function _value_id(field_name, id) {
    return 'v' + id + '_' + field_name;
}

/**
 * Autocompletion
 */

$(function() {
    function searchComplete() {
        var that = $(this);
        that.data('counter', that.data('counter') - 1);
        if (that.data('counter') === 0)
            that.removeClass('autocomplete-running');
        // devbridge-autocomplete 2.x calls onSearchComplete before rendering
        // suggestions, so defer the hide until after they have been shown
        var input = this;
        setTimeout(function() {
            if (document.activeElement !== input)
                that.devbridgeAutocomplete('hide');
        }, 0);
    }

    var options_user = {
        forceFixPosition: true,
        orientation: 'auto',
        paramName: 'match',
        deferRequestBy: 250,
        minChars: 2,
        noCache: true,
        tabDisabled: true,
        autoSelectFirst: true,
        preserveInput: true,
        triggerSelectOnValidInput: false,
        lookup: (query, done) => {
            // Note: `async` doesn't work for this `lookup` function, so use a `Promise` chain instead
            Bugzilla.API.get('user/suggest', { match: query })
                .then(({ users }) => users.map(({ name, real_name, requests, gravatar }) => ({
                    value: name,
                    data: { email: name, real_name, requests, gravatar },
                })))
                .catch(() => [])
                .then(suggestions => done({ suggestions }));
        },
        formatResult: function(suggestion) {
            const $input = this;
            const { email, real_name, requests, gravatar } = suggestion.data;
            const request_type = $input.getAttribute('data-request-type');
            const { blocked, pending } = requests ? (requests[request_type] || {}) : {};
            const image = gravatar ? `<img itemprop="image" alt="" src="${gravatar}">` : '';
            const description = blocked ? '<span class="icon" aria-hidden="true"></span> Requests blocked' :
                pending ? `${pending} pending ${request_type}${pending === 1 ? '' : 's'}` : '';

            return `<div itemscope itemtype="http://schema.org/Person">${image} ` +
                `<span itemprop="name">${real_name.htmlEncode()}</span> ` +
                `<span class="minor" itemprop="email">${email.htmlEncode()}</span> ` +
                `<span class="minor${blocked ? ' blocked' : ''}" itemprop="description">${description}</span></div>`;
        },
        onSelect: function (suggestion) {
            const $input = this;
            const { real_name, requests } = suggestion.data;
            const is_multiple = !!$input.getAttribute('data-multiple');
            const request_type = $input.getAttribute('data-request-type');
            const { blocked } = requests ? (requests[request_type] || {}) : {};

            if (blocked) {
                window.alert(`${real_name} is not accepting ${request_type} requests at this time. ` +
                    'If you’re in a hurry, ask someone else for help.');
            } else if (is_multiple) {
                const _values = $input.value.split(',').map(value => value.trim());

                _values.pop();
                _values.push(suggestion.value);
                $input.value = _values.join(', ') + ', ';
            } else {
                $input.value = suggestion.value;
            }

            $input.focus();
        },
        onSearchStart: function(params) {
            var that = $(this);

            // adding spaces shouldn't initiate a new search
            var query;
            if (that.data('multiple')) {
                var parts = that.val().split(/,\s*/);
                query = parts[parts.length - 1];
            }
            else {
                query = params.match;
            }
            if (query !== $.trim(query))
                return false;

            that.addClass('autocomplete-running');
            that.data('counter', that.data('counter') + 1);
            return true;
        },
        onSearchComplete: searchComplete,
        onSearchError: searchComplete
    };

    /**
     * Activate user autocomplete on the given input field.
     * @param {HTMLInputElement} $input `<input class="bz_autocomplete_user">`.
     */
    Bugzilla.Field.activateUserAutocomplete = ($input) => {
        const is_multiple = !!$input.getAttribute('data-multiple');
        const options = { ...options_user, appendTo: $input.closest('dialog, #main-inner') };

        options.delimiter = is_multiple ? /,\s*/ : undefined;
        // Override `this` in the relevant functions
        options.formatResult = options.formatResult.bind($input);
        options.onSelect = options.onSelect.bind($input);

        $input.dataset.counter = 0;
        $input.classList.add('bz_autocomplete');
        $($input).devbridgeAutocomplete(options);
    };

    // init user autocomplete fields
    $('.bz_autocomplete_user')
        .each(function() {
            Bugzilla.Field.activateUserAutocomplete(this);
        });

    // init autocomplete fields with array of values
    $('.bz_autocomplete_values')
        .each(function() {
            var that = $(this);
            that.devbridgeAutocomplete({
                appendTo: $('#main-inner'),
                forceFixPosition: true,
                lookup: function(query, done) {
                    var values = BUGZILLA.autocomplete_values[that.data('values')];
                    query = query.toLowerCase();
                    var activeValues = document.querySelector('#keywords').value.split(',');
                    activeValues.forEach((o,i,a) => a[i] = a[i].trim());
                    var matchStart =
                        $.grep(values, function(value) {
                            if(!(activeValues.includes(value)))
                                return value.toLowerCase().substr(0, query.length) === query;
                        });
                    var matchSub =
                        $.grep(values, function(value) {
                            if(!(activeValues.includes(value)))
                                return value.toLowerCase().indexOf(query) !== -1 &&
                                    $.inArray(value, matchStart) === -1;
                        });
                    var suggestions =
                        $.map($.merge(matchStart, matchSub), function(suggestion) {
                            return { value: suggestion };
                        });
                    done({ suggestions: suggestions });
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
            });
            that.addClass('bz_autocomplete');
        });

    // init autocomplete fields with a single value
    $('.bz_autocomplete_single_value')
        .each(function() {
            var that = $(this);
            that.devbridgeAutocomplete({
                appendTo: $('#main-inner'),
                forceFixPosition: true,
                lookup: function(query, done) {
                    var values = BUGZILLA.autocomplete_values[that.data('values')];
                    query = query.toLowerCase();
                    var activeValue = document.querySelector('#' + that.data('identifier')).value;
                    var matchStart =
                        $.grep(values, function(value) {
                            if(activeValue != value)
                                return value.toLowerCase().substr(0, query.length) === query;
                        });
                    var matchSub =
                        $.grep(values, function(value) {
                            if(activeValue != value)
                                return value.toLowerCase().indexOf(query) !== -1 &&
                                    $.inArray(value, matchStart) === -1;
                        });
                    var suggestions =
                        $.map($.merge(matchStart, matchSub), function(suggestion) {
                            return { value: suggestion };
                        });
                    done({ suggestions: suggestions });
                },
                tabDisabled: true,
                minChars: 0,
                autoSelectFirst: false,
                triggerSelectOnValidInput: false,
                formatResult: function(suggestion) {
                    // disable <b> wrapping of matched substring
                    return suggestion.value.htmlEncode();
                },
                onSearchStart: function() {
                    var that = $(this);
                    // adding spaces shouldn't initiate a new search
                    var parts = that.val().split(/,\s*/);
                    var query = parts[parts.length - 1];
                    return query === $.trim(query);
                },
                onSelect: function() {
                    this.focus();
                }
            });
            that.addClass('bz_autocomplete');
        });
});

/**
 * Force the browser to honour the selected option when a page is refreshed,
 * but only if the user hasn't explicitly selected a different option.
 */
function initDirtyFieldTracking() {
    var selects = document.getElementById('changeform').getElementsByTagName('select');
    for (var i = 0, l = selects.length; i < l; i++) {
        var el = selects[i];
        var el_dirty = document.getElementById(el.name + '_dirty');
        if (!el_dirty) continue;
        if (!el_dirty.value) {
            var preSelected = bz_preselectedOptions(el);
            if (!el.multiple) {
                preSelected.selected = true;
            } else {
                el.selectedIndex = -1;
                for (var j = 0, m = preSelected.length; j < m; j++) {
                    preSelected[j].selected = true;
                }
            }
        }
        el.addEventListener('change', e => {
            var el = e.target || e.srcElement;
            var preSelected = bz_preselectedOptions(el);
            var currentSelected = bz_selectedOptions(el);
            var isDirty = false;
            if (!el.multiple) {
                isDirty = preSelected.index != currentSelected.index;
            } else {
                if (preSelected.length != currentSelected.length) {
                    isDirty = true;
                } else {
                    for (var i = 0, l = preSelected.length; i < l; i++) {
                        if (currentSelected[i].index != preSelected[i].index) {
                            isDirty = true;
                            break;
                        }
                    }
                }
            }
            document.getElementById(el.name + '_dirty').value = isDirty ? '1' : '';
        });
    }
}
