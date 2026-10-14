'use strict';
'require view';
'require form';
'require uci';
'require network';
'require poll';
'require dom';
'require rpc';
'require fs';

// Muted accents for the coverage groups: neighbouring groups must be telling
// apart at a glance, without turning the rule table into a colour chart.
const CoverageAccents = ['#cc8800', '#2b7de9', '#2f9e63', '#8b6fd6', '#1f9aa8'];

// LuCI skips inactive retained flags. Persist existing hidden weekday widgets
// through the normal form parse/validation/write path, not during mode changes.
const RetainedWeekdayFlag = form.Flag.extend({
	parse(section_id) {
		if (!this.getUIElement(section_id))
			return Promise.resolve();
		if (this.isActive(section_id))
			return this.super('parse', [section_id]);

		if (!this.isValid(section_id)) {
			const title = this.stripTags(this.title).trim();
			const error = this.getValidationError(section_id);
			return Promise.reject(new TypeError(
				_('Option "%s" contains an invalid input value.').format(title || this.option) + ' ' + error));
		}

		return Promise.resolve(this.write(section_id, this.formvalue(section_id)));
	}
});

// Value.renderWidget does not forward size to Textfield in stable LuCI.
const TimeValue = form.Value.extend({
	renderWidget(section_id, option_index, cfgvalue) {
		const node = this.super('renderWidget', [section_id, option_index, cfgvalue]);
		const input = node.querySelector('input');
		input.size = 5;
		input.style.minWidth = '6em';
		return node;
	}
});


return view.extend({
	readCalendarStatus() {
		// fs.read() normalizes both "file missing" (ubus code 4) and rpcd
		// denials (code 6) through generic error names, so call the ubus
		// procedure directly with reject:true to distinguish them: missing
		// files are normal before the service first runs and render as a
		// neutral hint, while a denial means the session lacks the app ACL.
		const callFileRead = rpc.declare({
			object: 'file',
			method: 'read',
			params: [ 'path' ],
			reject: true
		});
		return callFileRead('/var/run/accesscontrol-calendar.status')
			.then((data) => String(data?.data ?? '').trim())
			.catch((e) => /ubus code 6/.test(String(e?.message)) ? 'permission-error' : '');
	},

	load() {
		return Promise.all([
			uci.load('accesscontrol'),
			network.getHostHints(),
			this.readCalendarStatus()
		]);
	},

	renderCalendarStatus(status) {
		// '' means the status file does not exist yet: holiday mode was
		// selected but not saved/applied, or the service has not finished
		// its first evaluation. 'permission-error' means rpcd denied the
		// read, e.g. a stale session created before this app installed.
		const value = typeof status === 'string' ? status.trim() : '';
		if (value === '')
			return E('span', { style: 'color:#5c5c5c;font-weight:bold' },
				_('Holiday calendar status is not available yet. Save & Apply to start the holiday service; if it stays empty, check the system log.'));
		let text, color;
		if (value === 'ready') {
			text = _('Holiday calendar ready.');
			color = 'green';
		} else if (value === 'unavailable') {
			text = _('Holiday calendar unavailable. Using the rules\' selected weekdays until calendar data is ready.');
			color = 'orange';
		} else if (value === 'apply-error') {
			text = _('Holiday calendar rules could not be applied. Previous rules are retained while retrying.');
			color = 'red';
		} else if (value === 'permission-error') {
			text = _('Holiday calendar status could not be read. Refresh the page or log in again.');
			color = 'red';
		} else {
			text = _('Holiday calendar status could not be read.');
			color = 'orange';
		}
		return E('span', { style: `color:${color};font-weight:bold` }, text);
	},

	fieldValue(option, section_id, fallback) {
		return option.getUIElement(section_id)
			? option.formvalue(section_id)
			: (uci.get('accesscontrol', section_id, option.option) ?? fallback);
	},

	// A period is a circular interval of minutes.  The generated rules also
	// include the whole ending minute, so lengths are inclusive; equal start and
	// end times are that single minute, and a period ending one minute before its
	// start wraps around into the full day.
	coveragePeriod(fields) {
		const minutes = (value) => {
			const match = /^([01]?[0-9]|2[0-3]):([0-5][0-9])$/.exec(value || '');
			return match ? parseInt(match[1], 10) * 60 + parseInt(match[2], 10) : null;
		};
		const start = minutes(fields.start_time), end = minutes(fields.end_time);
		if (start === null || end === null)
			return null;
		const length = (end - start + 1 + 1440) % 1440;
		return { start, end, length: length === 0 ? 1440 : length };
	},

	coverageContains(outer, inner) {
		const offset = (inner.start - outer.start + 1440) % 1440;
		return offset + inner.length <= outer.length;
	},

	// Read every rule that can currently be evaluated, including unsaved widget
	// values, so the warning tracks the form as it is edited.
	readRules() {
		if (!this.ruleSection)
			return [];
		return this.ruleSection.cfgsections().map((section_id) => {
			const holiday = this.fieldValue(this.ruleHolidayOption, section_id, '0') === '1';
			const weekdays = {};
			let all = true;
			Object.keys(this.ruleWeekdayOptions || {}).forEach((day) => {
				const on = this.fieldValue(this.ruleWeekdayOptions[day], section_id, '1') === '1';
				weekdays[day] = on;
				all = all && on;
			});
			const fields = {
				section_id,
				enabled: this.fieldValue(this.ruleEnabledOption, section_id, '1') === '1',
				holiday,
				weekdays,
				everyweekday: all,
				macaddr: String(this.fieldValue(this.ruleMacaddrOption, section_id, '') || '').toLowerCase(),
				start_time: this.fieldValue(this.ruleStartOption, section_id, ''),
				end_time: this.fieldValue(this.ruleEndOption, section_id, '')
			};
			fields.period = this.coveragePeriod(fields);
			return fields;
		});
	},

	// A rule never adds blocking when another enabled rule for the same MAC
	// address, in the same mode, already covers its whole period.  Weekday
	// coverage is required as well because the selected weekdays are also the
	// fallback while the calendar data is unavailable.  A disabled rule cannot
	// block at all, so it is never reported and never covers.
	coveringRule(rule, rules) {
		return rules.find((other) =>
			rule.enabled && other !== rule && other.enabled && other.period && rule.period &&
			other.macaddr !== '' && other.macaddr === rule.macaddr &&
			other.holiday === rule.holiday &&
			this.coverageContains(other.period, rule.period) &&
			(other.everyweekday || Object.keys(rule.weekdays).every((day) => !rule.weekdays[day] || other.weekdays[day])));
	},

	// The rule table renders one <tr class="cbi-section-table-row"> per section, so
	// the note is an extra row right below the covered rule and shares that row's
	// accent colour, which is what visually ties the two together.  Notes are
	// tracked per view instance instead of being looked up in the document: the
	// first render runs while the table is still detached, so a document query
	// cannot see the notes inserted by that same render and would insert them
	// twice.
	updateCoverageWarnings() {
		if (!this.ruleSection || !this.ruleHolidayOption || !this.ruleMacaddrOption)
			return;
		const rules = this.readRules();
		const wanted = new Map();
		const notes = this.coverageNotes || (this.coverageNotes = new Map());
		// getUIElement() returns LuCI's widget wrapper, whose DOM node is the
		// `node` property; older LuCI returned the node itself.  Anchors and
		// highlights must follow the node, never the wrapper.
		const nodeOf = (section_id) => {
			const widget = this.ruleHolidayOption.getUIElement(section_id);
			return widget && (widget.node || widget);
		};
		const rowOf = (section_id) => {
			const node = nodeOf(section_id);
			const row = node && node.closest ? node.closest('tr') : null;
			return (row && row.parentNode) ? row : null;
		};
		// A group is marked by one colour bar along the left edge of the covered
		// rule row and of its note row, so the two read as a single block instead
		// of two outlined boxes with a doubled line in between.
		const bar = (row, color) => {
			if (row && row.children && row.children.length)
				row.children[0].style.boxShadow = 'inset 4px 0 0 0 ' + color;
		};
		const unbar = (row) => {
			if (row && row.children && row.children.length)
				row.children[0].style.boxShadow = '';
		};
		const noteText = (note) => (note.tagName === 'TR' && note.children.length) ? note.children[0] : note;
		const paintNote = (note, color) => {
			noteText(note).style.color = color;
			bar(note, color);
		};
		const locateCover = (ev) => {
			const note = ev && ev.currentTarget;
			const row = note && note.__coverageCover;
			if (!row)
				return;
			if (ev.preventDefault)
				ev.preventDefault();
			// The pointer reuses the group colour on the cells of the covering
			// row; the bars stay on a different property and place.
			const color = note.__coverageAccent || CoverageAccents[0];
			const cells = row.children || [];
			const paint = (value) => {
				for (let i = 0; i < cells.length; i++)
					cells[i].style.outline = value;
			};
			paint('2px solid ' + color);
			if (row.scrollIntoView)
				row.scrollIntoView({ block: 'center' });
			setTimeout(() => paint(''), 2500);
		};
		let group = 0;
		rules.forEach((rule) => {
			const node = nodeOf(rule.section_id);
			if (!node)
				return;
			const cover = this.coveringRule(rule, rules);
			if (!cover)
				return;
			const row = rowOf(rule.section_id);
			const cell = node.closest ? (node.closest('td') || node.parentNode) : node.parentNode;
			if (!row && !cell)
				return;
			wanted.set(rule.section_id, {
				cell,
				row,
				asRow: !!row,
				coverRow: rowOf(cover.section_id),
				accent: CoverageAccents[group++ % CoverageAccents.length],
				message: _('Rule %d (%s–%s) already covers this whole period, so this rule never adds blocking. Click here to highlight it.')
					.format(rules.indexOf(cover) + 1, cover.start_time, cover.end_time)
			});
		});

		notes.forEach((note, section_id) => {
			const want = wanted.get(section_id);
			const asRow = note.hasAttribute('data-coverage-row');
			const current = note.parentNode && want && want.asRow === asRow &&
				note.parentNode === (asRow ? want.row.parentNode : want.cell);
			if (!current) {
				if (note.parentNode)
					note.parentNode.removeChild(note);
				unbar(note.__coverageRow);
				notes.delete(section_id);
				return;
			}
			note.__coverageRow = want.row;
			note.__coverageCover = want.coverRow;
			if (note.__coverageAccent !== want.accent) {
				note.__coverageAccent = want.accent;
				paintNote(note, want.accent);
			}
			bar(want.row, want.accent);
			if (note.textContent !== want.message)
				note.textContent = want.message;
			wanted.delete(section_id);
		});

		wanted.forEach((want, section_id) => {
			let note;
			if (want.asRow) {
				note = E('tr', {
					'data-accesscontrol-coverage': section_id,
					'data-coverage-row': '1',
					style: 'display:table-row;cursor:pointer',
					click: locateCover
				}, E('td', {
					colspan: want.row.children.length || 1,
					style: 'display:table-cell'
				}, want.message));
				want.row.parentNode.insertBefore(note, want.row.nextSibling);
			} else {
				note = E('div', {
					'data-accesscontrol-coverage': section_id,
					class: 'cbi-value-description',
					style: 'display:block;cursor:pointer',
					click: locateCover
				}, want.message);
				want.cell.appendChild(note);
			}
			note.__coverageRow = want.row;
			note.__coverageCover = want.coverRow;
			note.__coverageAccent = want.accent;
			paintNote(note, want.accent);
			bar(want.row, want.accent);
			notes.set(section_id, note);
		});
	},

	updateCalendarVisibility() {
		const value = (option, section_id, fallback) => this.fieldValue(option, section_id, fallback);
		const active = value(this.globalEnabledOption, 'global', '0') === '1' &&
			this.ruleSection.cfgsections().some((section_id) =>
				value(this.ruleEnabledOption, section_id, '1') === '1' &&
				value(this.ruleHolidayOption, section_id, '0') === '1');
		this.calendarStatusNode.style.display = active ? '' : 'none';
	},

	handleServiceReload() {
		// Check service status by looking for our nftables chain and rules
		return Promise.all([
			L.resolveDefault(L.fs.exec_direct('nft', ['list', 'table', 'inet', 'fw4']).then((res) => ({ stdout: (res.match(/AccessControl/g) || []).length.toString() })), { stdout: '0' }),
			L.resolveDefault(L.fs.exec_direct('nft', ['list', 'chain', 'inet', 'fw4', 'accesscontrol']).then((res) => ({ stdout: res ? '1' : '0' })), { stdout: '0' }),
			this.readCalendarStatus()
		]).then((results) => {
			const ruleCount = parseInt(results[0].stdout) || 0;
			const chainExists = parseInt(results[1].stdout) || 0;

			const view = document.getElementById('service_status');
			if (view) {
				let statusText = '';
				if (ruleCount > 0 && chainExists > 0) {
					statusText = `<span style="color:green;font-weight:bold">${_('Running (nftables)')}</span>`;
				} else if (chainExists > 0) {
					statusText = `<span style="color:orange;font-weight:bold">${_('Chain exists (no rules)')}</span>`;
				} else {
					statusText = `<span style="color:red;font-weight:bold">${_('Not running')}</span>`;
				}
				view.innerHTML = statusText;
			}

			dom.content(this.calendarStatusNode, this.renderCalendarStatus(results[2]));
			this.updateCalendarVisibility();
			this.updateCoverageWarnings();
		});
	},

	render(data) {
		let m, s, o;
		const hosts = data[1]?.['hosts'] || {};
		this.calendarStatusNode = E('div', { id: 'calendar_status', style: 'margin-top:6px;display:none' },
			[this.renderCalendarStatus(data[2])]);

		m = new form.Map('accesscontrol', _('Internet Access Schedule Control'),
			E('div', {}, [
				E('div', {}, _('Control internet access for specific devices based on time schedules and MAC addresses.')),
				E('div', { id: 'service_status', style: 'margin-top:6px;' }, _('Checking...')),
				this.calendarStatusNode
			])
		);
		const renderContents = m.renderContents.bind(m);
		m.renderContents = () => renderContents().then((node) => {
			// Save, reset and rule removal also re-render this same map.
			this.updateCalendarVisibility();
			this.updateCoverageWarnings();
			return node;
		});

		// Global settings
		s = m.section(form.NamedSection, 'global', 'accesscontrol', _('Global Settings'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '0';
		o.rmempty = false;
		o.onchange = () => this.updateCalendarVisibility();
		this.globalEnabledOption = o;


		// Client rules section
		s = m.section(form.TableSection, 'rule', _('Access Control Rules'));
		s.addremove = true;
		s.anonymous = true;
		this.ruleSection = s;
		// Coverage notes are tracked here, not looked up in the document: the
		// first render still runs detached from the page.
		this.coverageNotes = new Map();

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '1';
		o.rmempty = false;
		o.onchange = () => { this.updateCalendarVisibility(); this.updateCoverageWarnings(); };
		this.ruleEnabledOption = o;

		o = s.option(form.Value, 'macaddr', _('MAC Address'));
		o.rmempty = false;
		o.datatype = 'macaddr';
		this.ruleMacaddrOption = o;

		Object.keys(hosts).forEach((mac) => {
			const hint = hosts[mac];
			const name = `${hint.name || ''} ${hint.ipaddrs.join('|') || ''}` || `${hint.ip6addrs.join('|') || ''} ${mac}`;
			o.value(mac.toLowerCase(), '%s (%s)'.format(mac.toLowerCase(), name));
		});

		o = s.option(TimeValue, 'start_time', _('Start Time'));
		o.rmempty = false;
		o.default = '00:00';
		o.datatype = 'string';
		this.ruleStartOption = o;
		o.validate = (section_id, value) => {
			if (!/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/.test(value))
				return _('Invalid time format. Use HH:MM (24-hour format)');
			return true;
		};

		o = s.option(TimeValue, 'end_time', _('End Time'));
		o.rmempty = false;
		o.default = '23:59';
		o.datatype = 'string';
		this.ruleEndOption = o;
		o.validate = (section_id, value) => {
			if (!/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/.test(value))
				return _('Invalid time format. Use HH:MM (24-hour format)');
			return true;
		};

		o = s.option(form.Flag, 'respect_holidays', _('Respect holidays'));
		o.default = '0';
		o.rmempty = false;
		o.onchange = () => { this.updateCalendarVisibility(); this.updateCoverageWarnings(); };
		this.ruleHolidayOption = o;
		s.description = E('div', {}, [
			E('div', {}, _('For this rule, holiday mode and weekday selection are mutually exclusive. Chinese working days replace the selected weekdays: ordinary weekends and holidays are unrestricted; make-up working days are restricted. This rule\'s times and MAC address still apply. Weekday edits are saved even when holiday mode hides them; turning holiday mode off restores these selections.')),
			E('div', {}, _('Holiday mode dates each part of a period by the day it belongs to: a part crossing midnight follows its end date, and a part from 18:00 on follows the next day, so the night before a holiday stays open and the last holiday night is restricted. A period that reaches 18:00 is split at that boundary. For example 20:10–08:00 and 21:30–22:00 are both unrestricted on an ordinary Friday night and restricted on the last holiday night, while 17:00–18:30 keeps 17:00–18:00 on the current day and follows the next day from 18:00.')),
			E('div', {}, _('Holiday mode follows the router\'s own timezone from System → Timezone for both the period times and the holiday dates, so a China holiday calendar needs the router set to a UTC+8 zone.')),
			E('div', {}, _('Holiday mode includes the entire end minute: an end time of 06:00 remains restricted through 06:00:59 and releases at 06:01. Equal start and end times restrict only that minute.')),
			E('div', {}, _('If calendar data is unavailable, this rule uses its selected weekdays. If calendar rules cannot be applied, the previous rules remain in place while the service retries.'))
		]);

		// Weekdays
		const weekdays = [
			['monday', _('Monday')],
			['tuesday', _('Tuesday')],
			['wednesday', _('Wednesday')],
			['thursday', _('Thursday')],
			['friday', _('Friday')],
			['saturday', _('Saturday')],
			['sunday', _('Sunday')]
		];

		this.ruleWeekdayOptions = {};
		weekdays.forEach((day) => {
			o = s.option(RetainedWeekdayFlag, day[0], day[1]);
			o.default = '1';
			o.rmempty = false;
			o.depends('respect_holidays', '0');
			o.retain = true;
			this.ruleWeekdayOptions[day[0]] = o;
		});

		return m.render().then((node) => {
			// Register polling only after the form root is available. The note
			// poll is independent so a status refresh failure cannot hide it.
			poll.add(L.bind(this.updateCoverageWarnings, this), 5);
			poll.add(L.bind(this.handleServiceReload, this), 5);
			return node;
		});
	}

	// Use default LuCI handleSave and handleSaveApply implementation
	// LuCI automatically handles form.Map() save and apply logic
});