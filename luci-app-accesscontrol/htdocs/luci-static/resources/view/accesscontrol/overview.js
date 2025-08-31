'use strict';
'require view';
'require form';
'require uci';
'require network';
'require poll';
'require dom';
'require rpc';


return view.extend({
	load: () => {
		return Promise.all([
			uci.load('accesscontrol'),
			network.getHostHints()
		]);
	},

	handleServiceReload: () => {
		// Check service status by looking for our nftables chain and rules
		return Promise.all([
			L.resolveDefault(L.fs.exec_direct('nft', ['list', 'table', 'inet', 'fw4']).then((res) => {
				return { stdout: (res.match(/AccessControl/g) || []).length.toString() };
			}), { stdout: '0' }),
			L.resolveDefault(L.fs.exec_direct('nft', ['list', 'chain', 'inet', 'fw4', 'accesscontrol']).then((res) => {
				return { stdout: res ? '1' : '0' };
			}), { stdout: '0' })
		]).then((results) => {
			const ruleCount = parseInt(results[0].stdout) || 0;
			const chainExists = parseInt(results[1].stdout) || 0;

			const view = document.getElementById('service_status');
			if (view) {
				let statusText = '';
				if (ruleCount > 0 && chainExists > 0) {
					statusText = '<span style="color:green;font-weight:bold">' + _('Running (nftables)') + '</span>';
				} else if (chainExists > 0) {
					statusText = '<span style="color:orange;font-weight:bold">' + _('Chain exists (no rules)') + '</span>';
				} else {
					statusText = '<span style="color:red;font-weight:bold">' + _('Not running') + '</span>';
				}
				view.innerHTML = statusText;
			}
		});
	},

	render: function (data) {
		let m, s, o;
		const hosts = data[1]?.['hosts'] || {};

		m = new form.Map('accesscontrol', _('Internet Access Schedule Control'),
			E('div', {}, [
				E('div', {}, _('Control internet access for specific devices based on time schedules and MAC addresses.')),
				E('div', { id: 'service_status', style: 'margin-top:6px;' }, _('Checking...'))
			])
		);

		// Global settings
		s = m.section(form.NamedSection, 'global', 'accesscontrol', _('Global Settings'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '0';
		o.rmempty = false;

		// Client rules section
		s = m.section(form.TableSection, 'rule', _('Access Control Rules'));
		s.addremove = true;
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'macaddr', _('MAC Address'));
		o.rmempty = false;
		o.datatype = 'macaddr';

		Object.keys(hosts).forEach((mac) => {
			const hint = hosts[mac];
			var name = `${hint.name || ''} ${hint.ipaddrs.join('|') || ''}` || `${hint.ip6addrs.join('|') || ''} ${mac}`;
			o.value(mac.toLowerCase(), '%s (%s)'.format(mac.toLowerCase(), name));
		});

		o = s.option(form.Value, 'start_time', _('Start Time'));
		o.rmempty = false;
		o.default = '00:00';
		o.datatype = 'string';
		o.validate = (section_id, value) => {
			if (!/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/.test(value))
				return _('Invalid time format. Use HH:MM (24-hour format)');
			return true;
		};

		o = s.option(form.Value, 'end_time', _('End Time'));
		o.rmempty = false;
		o.default = '23:59';
		o.datatype = 'string';
		o.validate = (section_id, value) => {
			if (!/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/.test(value))
				return _('Invalid time format. Use HH:MM (24-hour format)');
			return true;
		};

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

		weekdays.forEach((day) => {
			o = s.option(form.Flag, day[0], day[1]);
			o.default = '1';
			o.rmempty = false;
		});

		// Poll for service status
		poll.add(L.bind(this.handleServiceReload, this), 5);

		return m.render();
	}

	// Use default LuCI handleSave and handleSaveApply implementation
	// LuCI automatically handles form.Map() save and apply logic
});