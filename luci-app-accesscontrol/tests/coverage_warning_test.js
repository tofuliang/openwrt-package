#!/usr/bin/env node
// Coverage-note decisions and DOM anchoring of the rule page.
// Run with:  node tests/coverage_warning_test.js
//
// The browser page is not exercised here: the view is evaluated with the small
// subset of the LuCI runtime its coverage methods use against a minimal DOM
// model, and the resulting decisions and note rows are asserted directly.  The
// DOM model mirrors LuCI's rule table: one <tr> with a <td> widget per section,
// and getUIElement() returning a widget wrapper whose DOM node is `node`.
'use strict';

const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(path.join(__dirname, '..', 'htdocs', 'luci-static',
	'resources', 'view', 'accesscontrol', 'overview.js'), 'utf8');

// LuCI patches String.prototype.format for translated messages (%s and %d).
if (typeof String.prototype.format !== 'function')
	String.prototype.format = function (...args) { return this.replace(/%[sd]/g, () => args.shift()); };

const sections = [];
const values = {};
const option = (name) => ({ option: name, getUIElement: () => null, formvalue: () => undefined });
const stubs = {
	require: () => ({}),
	view: { extend: (view) => view },
	form: { Flag: { extend: (o) => o }, Value: { extend: (o) => o }, NamedSection: class {}, TableSection: class {}, Map: class {} },
	uci: { get: (pkg, section_id, name) => values[section_id]?.[name], sections: () => sections },
	E: () => ({}),
	_: (text) => text,
	L: { resolveDefault: (p) => p, bind: (f) => f, fs: {} },
	poll: { add: () => {} },
	dom: { content: () => {} }
};

const names = ['require', 'view', 'form', 'uci', 'E', '_', 'L', 'poll', 'dom'];
const app = new Function(...names, `${source}\nreturn view;`)(...names.map((name) => stubs[name]));
const weekdays = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];

['enabled', 'respect_holidays', 'macaddr', 'start_time', 'end_time'].forEach((field) => {
	const property = { enabled: 'ruleEnabledOption', respect_holidays: 'ruleHolidayOption', macaddr: 'ruleMacaddrOption',
		start_time: 'ruleStartOption', end_time: 'ruleEndOption' }[field];
	app[property] = option(field);
});
app.ruleSection = { cfgsections: () => sections.map((section) => section.id) };
app.ruleWeekdayOptions = Object.fromEntries(weekdays.map((day) => [day, option(day)]));

let checks = 0;
function expect(name, rules, covered) {
	sections.length = 0;
	Object.keys(values).forEach((key) => delete values[key]);
	rules.forEach((rule) => {
		sections.push({ id: rule.id });
		values[rule.id] = Object.assign({ enabled: '1', respect_holidays: '1' }, rule);
		weekdays.forEach((day) => { values[rule.id][day] = rule[day] ?? '1'; });
	});
	const read = app.readRules();
	const got = read.map((rule) => app.coveringRule(rule, read)?.section_id ?? null);
	const want = rules.map((rule) => rule.covered ?? null);
	const ok = JSON.stringify(got) === JSON.stringify(want);
	checks++;
	console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok ? '' : `\n     got  ${JSON.stringify(got)}\n     want ${JSON.stringify(want)}`}`);
	if (!ok)
		process.exitCode = 1;
}

const macA = '04:39:26:e5:9e:ed';
const macB = '48:a9:d2:98:4e:b8';

expect('the wider period covers the contained one',
	[{ id: 'a', macaddr: macA, start_time: '01:00', end_time: '20:00' },
	 { id: 'b', macaddr: macA, start_time: '02:00', end_time: '18:31', covered: 'a' }]);
expect('a period starting earlier is not covered',
	[{ id: 'a', macaddr: macA, start_time: '01:00', end_time: '20:00' },
	 { id: 'b', macaddr: macA, start_time: '00:30', end_time: '18:31' }]);
expect('a cross-midnight period covers one inside it',
	[{ id: 'a', macaddr: macA, start_time: '20:10', end_time: '08:00' },
	 { id: 'b', macaddr: macA, start_time: '21:00', end_time: '07:00', covered: 'a' }]);
expect('an early evening period is outside the night',
	[{ id: 'a', macaddr: macA, start_time: '20:00', end_time: '05:00' },
	 { id: 'b', macaddr: macA, start_time: '17:00', end_time: '17:30' }]);
expect('the closing minute counts as covered',
	[{ id: 'a', macaddr: macA, start_time: '17:00', end_time: '18:00' },
	 { id: 'b', macaddr: macA, start_time: '18:00', end_time: '18:00', covered: 'a' }]);
expect('a full day covers every other period of the same MAC',
	[{ id: 'a', macaddr: macA, start_time: '00:00', end_time: '23:59' },
	 { id: 'b', macaddr: macA, start_time: '02:00', end_time: '18:31', covered: 'a' }]);
expect('a full day is not covered by a shorter period',
	[{ id: 'a', macaddr: macA, start_time: '00:00', end_time: '23:59' },
	 { id: 'b', macaddr: macA, start_time: '00:00', end_time: '7:20', covered: 'a' }]);

{
	// Period lengths count the whole ending minute; a period that ends one
	// minute before it starts is the full day, not a single minute.
	const cases = [
		['00:00', '23:59', 1440],
		['23:59', '23:58', 1440],
		['18:00', '18:00', 1],
		['22:00', '06:00', 481],
		['00:00', '7:20', 441]
	];
	const bad = cases.filter(([start, end, want]) => (app.coveragePeriod({ start_time: start, end_time: end }) || {}).length !== want);
	checks++;
	console.log(`${bad.length ? 'FAIL' : 'ok  '} periods count inclusive minutes and a full day is 1440${bad.length ? `\n     ${JSON.stringify(bad)}` : ''}`);
	if (bad.length)
		process.exitCode = 1;
}
expect('an equal period duplicates the other rule',
	[{ id: 'a', macaddr: macA, start_time: '08:00', end_time: '09:00', covered: 'b' },
	 { id: 'b', macaddr: macA, start_time: '08:00', end_time: '09:00', covered: 'a' }]);
expect('a different MAC address never covers',
	[{ id: 'a', macaddr: macB, start_time: '01:00', end_time: '20:00' },
	 { id: 'b', macaddr: macA, start_time: '02:00', end_time: '18:31' }]);
expect('the other mode never covers',
	[{ id: 'a', macaddr: macA, start_time: '01:00', end_time: '20:00' },
	 { id: 'b', macaddr: macA, respect_holidays: '0', start_time: '02:00', end_time: '18:31' }]);
expect('a disabled rule neither covers nor is covered',
	[{ id: 'a', macaddr: macA, enabled: '0', start_time: '01:00', end_time: '20:00' },
	 { id: 'b', macaddr: macA, start_time: '02:00', end_time: '18:31' }]);
expect('a disabled covered rule is not reported',
	[{ id: 'a', macaddr: macA, start_time: '01:00', end_time: '20:00' },
	 { id: 'b', macaddr: macA, enabled: '0', start_time: '02:00', end_time: '18:31' }]);
expect('the weekday fallback needs covering too',
	[{ id: 'a', macaddr: macA, monday: '0', start_time: '01:00', end_time: '20:00' },
	 { id: 'b', macaddr: macA, start_time: '02:00', end_time: '18:31' }]);
expect('a contained weekday set is reported',
	[{ id: 'a', macaddr: macA, start_time: '01:00', end_time: '20:00' },
	 { id: 'b', macaddr: macA, monday: '0', saturday: '0', sunday: '0', start_time: '02:00', end_time: '18:31', covered: 'a' }]);
expect('a missing MAC address is ignored',
	[{ id: 'a', macaddr: '', start_time: '01:00', end_time: '20:00' },
	 { id: 'b', macaddr: '', start_time: '02:00', end_time: '18:31' }]);
expect('an invalid time is ignored',
	[{ id: 'a', macaddr: macA, start_time: '25:00', end_time: '20:00' },
	 { id: 'b', macaddr: macA, start_time: '02:00', end_time: '18:31' }]);

// --- DOM anchoring of the note ---------------------------------------------
//
// LuCI's getUIElement() returns a widget wrapper object whose DOM node hangs
// off its `node` property; older LuCI returned the node itself.  The note must
// be anchored through the widget's DOM node, never through the wrapper.

function domNode(tag) {
	const node = {
		// HTML documents upper-case tag names; the view relies on that.
		tagName: String(tag).toUpperCase(), attrs: {}, children: [], parentNode: null, _text: '', handlers: null,
		// CSSStyleDeclaration returns '' for unset properties.
		style: new Proxy({}, {
			get: (target, key) => (key in target ? target[key] : ''),
			set: (target, key, value) => { target[key] = value; return true; }
		}),
		setAttribute(name, value) { this.attrs[name] = String(value); },
		getAttribute(name) { return name in this.attrs ? this.attrs[name] : null; },
		hasAttribute(name) { return name in this.attrs; },
		appendChild(child) { child.parentNode = this; this.children.push(child); return child; },
		insertBefore(child, ref) {
			child.parentNode = this;
			const at = ref ? this.children.indexOf(ref) : -1;
			this.children.splice(at < 0 ? this.children.length : at, 0, child);
			return child;
		},
		removeChild(child) {
			const at = this.children.indexOf(child);
			if (at >= 0)
				this.children.splice(at, 1);
			child.parentNode = null;
			return child;
		},
		get nextSibling() {
			const list = this.parentNode ? this.parentNode.children : [];
			return list[list.indexOf(this) + 1] || null;
		},
		closest(selector) {
			const wanted = String(selector).toLowerCase();
			for (let node = this; node; node = node.parentNode)
				if (String(node.tagName).toLowerCase() === wanted)
					return node;
			return null;
		},
		get textContent() { return this._text + this.children.map((child) => child.textContent).join(''); },
		set textContent(value) { this._text = String(value); this.children = []; }
	};
	return node;
}

function domE(tag, attrs, ...children) {
	const node = domNode(tag);
	Object.entries(attrs || {}).forEach(([name, value]) => {
		if (typeof value === 'function') {
			node.handlers = node.handlers || {};
			node.handlers[name] = value;
		} else if (name === 'style' && typeof value === 'string') {
			value.split(';').forEach((pair) => {
				const at = pair.indexOf(':');
				if (at > 0)
					node.style[pair.slice(0, at).trim()] = pair.slice(at + 1).trim();
			});
		} else {
			node.setAttribute(name, value);
		}
	});
	children.flat(3).forEach((child) => {
		if (child == null)
			return;
		if (typeof child === 'string')
			node._text += child;
		else
			node.appendChild(child);
	});
	return node;
}

function domDocument() {
	const doc = {
		body: domNode('body'),
		createElement: domNode,
		querySelectorAll(selector) {
			const name = selector.replace(/[[\]]/g, '').split('=')[0];
			const found = [];
			(function walk(node) {
				node.children.forEach((child) => {
					if (child.hasAttribute(name))
						found.push(child);
					walk(child);
				});
			})(doc.body);
			return found;
		}
	};
	return doc;
}

// Rows model LuCI's rule table; `wrap` selects how getUIElement() presents the
// widget: 'wrapper' (current LuCI), 'node' (older LuCI) or 'missing'.
function domFixture(rows) {
	const doc = domDocument();
	const table = domNode('table');
	const tbody = domNode('tbody');
	table.appendChild(tbody);
	doc.body.appendChild(table);
	const widgets = {};
	rows.forEach((row) => {
		const tr = domNode('tr');
		const td = domNode('td');
		const input = domNode('input');
		td.appendChild(input);
		tr.appendChild(td);
		tbody.appendChild(tr);
		row.node = input;
		row.tr = tr;
		widgets[row.id] = row.wrap === 'missing' ? null
			: row.wrap === 'node' ? input
			: { node: input, isChecked: () => input.checked, getValue: () => input.value };
	});

	const stubs2 = Object.assign({}, stubs, { E: domE });
	const app2 = new Function(...names, 'document', `${source}\nreturn view;`)(
		...names.map((name) => stubs2[name]), doc);
	const fields = ['enabled', 'respect_holidays', 'macaddr', 'start_time', 'end_time'];
	fields.forEach((field) => {
		const property = { enabled: 'ruleEnabledOption', respect_holidays: 'ruleHolidayOption',
			macaddr: 'ruleMacaddrOption', start_time: 'ruleStartOption', end_time: 'ruleEndOption' }[field];
		app2[property] = {
			option: field,
			getUIElement: (id) => widgets[id],
			formvalue: (id) => values[id]?.[field]
		};
	});
	app2.ruleSection = { cfgsections: () => rows.map((row) => row.id) };
	app2.ruleWeekdayOptions = Object.fromEntries(weekdays.map((day) => [day, option(day)]));
	return { app2, tbody, doc, table };
}

function loadRules(rules) {
	sections.length = 0;
	Object.keys(values).forEach((key) => delete values[key]);
	rules.forEach((rule) => {
		sections.push({ id: rule.id });
		values[rule.id] = Object.assign({ enabled: '1', respect_holidays: '1' }, rule);
		weekdays.forEach((day) => { values[rule.id][day] = rule[day] ?? '1'; });
	});
}

function domCheck(name, rows, rules, wantNotes) {
	loadRules(rules);
	const { app2, tbody } = domFixture(rows);
	app2.updateCoverageWarnings();
	const notes = [];
	tbody.children.forEach((child, index) => {
		if (child.hasAttribute('data-accesscontrol-coverage'))
			notes.push({ index, sid: child.getAttribute('data-accesscontrol-coverage'), text: child.textContent.trim() });
	});
	const got = notes.map((note) => `${note.sid}@${note.index}:${note.text}`);
	const ok = JSON.stringify(got) === JSON.stringify(wantNotes);
	checks++;
	console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok ? '' : `\n     got  ${JSON.stringify(got)}\n     want ${JSON.stringify(wantNotes)}`}`);
	if (!ok)
		process.exitCode = 1;
	return { app2, tbody, notes };
}

const oneNoteBelowB = ['b@2:Rule 1 (01:00–20:00) already covers this whole period, so this rule never adds blocking. Click here to highlight it.'];

domCheck('the note is a row right below the covered rule',
	[{ id: 'a', wrap: 'wrapper' }, { id: 'b', wrap: 'wrapper' }],
	[{ id: 'a', macaddr: macA, start_time: '01:00', end_time: '20:00' },
	 { id: 'b', macaddr: macA, start_time: '02:00', end_time: '18:31' }],
	oneNoteBelowB);

domCheck('raw widget nodes from older LuCI anchor the same way',
	[{ id: 'a', wrap: 'node' }, { id: 'b', wrap: 'node' }],
	[{ id: 'a', macaddr: macA, start_time: '01:00', end_time: '20:00' },
	 { id: 'b', macaddr: macA, start_time: '02:00', end_time: '18:31' }],
	oneNoteBelowB);

domCheck('an uncovered table stays clean',
	[{ id: 'a', wrap: 'wrapper' }, { id: 'b', wrap: 'wrapper' }],
	[{ id: 'a', macaddr: macA, start_time: '01:00', end_time: '20:00' },
	 { id: 'b', macaddr: macA, start_time: '21:30', end_time: '22:00' }],
	[]);

domCheck('a rule without its widget is skipped',
	[{ id: 'a', wrap: 'wrapper' }, { id: 'b', wrap: 'missing' }],
	[{ id: 'a', macaddr: macA, start_time: '01:00', end_time: '20:00' },
	 { id: 'b', macaddr: macA, start_time: '02:00', end_time: '18:31' }],
	[]);

domCheck('a disabled rule gets no note',
	[{ id: 'a', wrap: 'wrapper' }, { id: 'b', wrap: 'wrapper' }],
	[{ id: 'a', macaddr: macA, start_time: '01:00', end_time: '20:00' },
	 { id: 'b', macaddr: macA, enabled: '0', start_time: '02:00', end_time: '18:31' }],
	[]);

{
	// Clicking the note must point at the covering rule: its cells take the
	// group colour, while the colour bars stay on the covered rule and its note.
	loadRules([{ id: 'a', macaddr: macA, start_time: '01:00', end_time: '20:00' },
		{ id: 'b', macaddr: macA, start_time: '02:00', end_time: '18:31' }]);
	const { app2, tbody } = domFixture([{ id: 'a', wrap: 'wrapper' }, { id: 'b', wrap: 'wrapper' }]);
	app2.updateCoverageWarnings();
	const note = tbody.children[2];
	const covering = tbody.children[0];
	const covered = tbody.children[1];
	const bar = 'inset 4px 0 0 0 #cc8800';
	const barPresent = covered.children[0].style.boxShadow === bar && note.children[0].style.boxShadow === bar &&
		note.children[0].style.color === '#cc8800';
	note.handlers.click({ currentTarget: note, preventDefault() {} });
	const ok = !!note.handlers && note.handlers.click != null && barPresent &&
		covering.children[0].style.outline === '2px solid #cc8800' &&
		covering.children[0].style.boxShadow === '';
	checks++;
	console.log(`${ok ? 'ok  ' : 'FAIL'} the note shares the covered row's colour bar and locates the covering row${ok ? '' : `\n     covered bar "${covered.children[0].style.boxShadow}", note bar "${note.children[0].style.boxShadow}", note color "${note.children[0].style.color}", note tag ${note.tagName}`}`);
	if (!ok)
		process.exitCode = 1;
}

{
	// Neighbouring groups must stay distinguishable.
	loadRules([{ id: 'a', macaddr: macA, start_time: '01:00', end_time: '20:00' },
		{ id: 'b', macaddr: macA, start_time: '02:00', end_time: '18:31' },
		{ id: 'c', macaddr: macA, start_time: '03:00', end_time: '17:00' }]);
	const { app2, tbody } = domFixture([{ id: 'a', wrap: 'wrapper' }, { id: 'b', wrap: 'wrapper' }, { id: 'c', wrap: 'wrapper' }]);
	app2.updateCoverageWarnings();
	const bars = [...tbody.children].map((child, index) => ({ index, shadow: child.children[0].style.boxShadow }))
		.filter((entry) => entry.shadow.startsWith('inset'));
	const colours = new Set(bars.map((entry) => entry.shadow));
	const ok = bars.length === 4 && colours.size === 2;
	checks++;
	console.log(`${ok ? 'ok  ' : 'FAIL'} neighbouring groups use different colours${ok ? '' : `\n     ${JSON.stringify(bars)}`}`);
	if (!ok)
		process.exitCode = 1;
}

{
	// Regression: the first render runs detached from the document, so two
	// passes there must not insert the note twice.
	loadRules([{ id: 'a', macaddr: macA, start_time: '01:00', end_time: '20:00' },
		{ id: 'b', macaddr: macA, start_time: '02:00', end_time: '18:31' }]);
	const { app2, tbody, doc, table } = domFixture([{ id: 'a', wrap: 'wrapper' }, { id: 'b', wrap: 'wrapper' }]);
	doc.body.removeChild(table);
	app2.updateCoverageWarnings();
	app2.updateCoverageWarnings();
	const notes = tbody.children.filter((child) => child.hasAttribute('data-accesscontrol-coverage'));
	const ok = tbody.children.length === 3 && notes.length === 1;
	checks++;
	console.log(`${ok ? 'ok  ' : 'FAIL'} repeated detached passes never duplicate the note${ok ? '' : `\n     rows ${tbody.children.length}, notes ${notes.length}`}`);
	if (!ok)
		process.exitCode = 1;
}

{
	const rows = [{ id: 'a', wrap: 'wrapper' }, { id: 'b', wrap: 'wrapper' }];
	const rules = [{ id: 'a', macaddr: macA, start_time: '01:00', end_time: '20:00' },
		{ id: 'b', macaddr: macA, start_time: '02:00', end_time: '18:31' }];
	loadRules(rules);
	const { app2, tbody } = domFixture(rows);
	app2.updateCoverageWarnings();
	const first = tbody.children.length;
	values.a.enabled = '0';
	app2.updateCoverageWarnings();
	const second = tbody.children.length;
	const barCleared = tbody.children[1].children[0].style.boxShadow === '';
	const ok = first === 3 && second === 2 && barCleared;
	checks++;
	console.log(`${ok ? 'ok  ' : 'FAIL'} the note and its colour bar disappear once the covering rule is off${ok ? '' : `\n     rows before ${first}, after ${second}, bar "${tbody.children[1].children[0].style.boxShadow}"`}`);
	if (!ok)
		process.exitCode = 1;
}

console.log(process.exitCode ? `${checks} checks, failures above` : `all ${checks} coverage checks passed`);
