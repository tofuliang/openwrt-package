'use strict';
'require view';
'require form';
'require uci';
'require network';
'require poll';
'require dom';
'require rpc';
'require fs';


return view.extend({
	load: () => {
		return Promise.all([
			uci.load('webrestriction'),
			network.getHostHints(),
		]);
	},

	handleSave: (ev) => {
		const tasks = [];

		document.getElementById('maincontent')
			.querySelectorAll('.cbi-map').forEach(map => {
				tasks.push(DOM.callClassMethod(map, 'save', () => {
					const bypassListValue = uci.get('webrestriction', 'global', 'bypass_list');
					if (undefined !== bypassListValue) {
						uci.unset('webrestriction', 'global', 'bypass_list');
						uci.set('webrestriction', 'global', 'bypass_list_updated_at', +Date.now());
						fs.write('/etc/config/webrestriction_bypass.list', bypassListValue);
					}
				}));
			});

		return Promise.all(tasks);
	},

	handleServiceReload: () => {
		// Check service status by looking for our nftables chain and rules
		return Promise.all([
			L.resolveDefault(L.fs.exec_direct('nft', ['list', 'table', 'inet', 'fw4']).then(function (res) {
				return { stdout: (res.match(/WebRestriction/g) || []).length.toString() };
			}), { stdout: '0' }),
			L.resolveDefault(L.fs.exec_direct('nft', ['list', 'chain', 'inet', 'fw4', 'webrestriction']).then(function (res) {
				return { stdout: res ? '1' : '0' };
			}), { stdout: '0' }),
		]).then(function (results) {
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

	render: function(data) {
		let m, s, o;
		const hosts = data[1]?.['hosts'] || {};

		m = new form.Map('webrestriction', _('Web Access Restriction'),
			E('div', {}, [
				E('div', {}, _('Control internet access using whitelist or blacklist mode for specific devices.')),
				E('div', { id: 'service_status', style: 'margin-top:6px;' }, _('Checking...'))
			])
		);

		s = m.section(form.NamedSection, 'global', 'webrestriction', _('Global Settings'));
		s.addremove = false;
		s.anonymous = true;

		s.tab('basic', _('Basic Settings'));

		o = s.taboption('basic', form.Flag, 'enabled', _('Enable'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('basic', form.ListValue, 'limit_type', _('Restriction Mode'));
		o.value('blacklist', _('Blacklist'));
		o.value('whitelist', _('Whitelist'));
		o.default = 'blacklist';
		o.rmempty = false;

		s.tab('whitelist', _('IP Whitelist'));

		o = s.taboption('whitelist', form.TextValue, 'bypass_list', _('IP Whitelist'),
			_('Enter IP addresses or networks that should always be allowed (one per line). Supports IPv4 and IPv6.'));
		o.rows = 8;
		o.wrap = 'off';
		o.cfgvalue = () => fs.read('/etc/config/webrestriction_bypass.list').catch(() => '# Commented by webrestriction');
		o.rmempty = true;

		s = m.section(form.NamedSection, '__devices__', 'devices');
		s.anonymous = true;
		s.cfgsections = () => ['__devices__'];
		s.title = _('Device List Settings');
		s.description = _('Configure device blacklist or whitelist based on the restriction mode above.');

		var rs = m.section(form.TableSection, 'rule', _('Device Rules'));
		rs.addremove = true;
		rs.anonymous = true;

		o = rs.option(form.Flag, 'enabled', _('Enable'));
		o.default = '1';
		o.rmempty = false;

		o = rs.option(form.Value, 'macaddr', _('MAC Address'));
		o.rmempty = false;
		o.datatype = 'macaddr';

		Object.keys(hosts).forEach((mac) => {
			var hint = hosts[mac];
			var name = `${hint.name || ''} ${hint.ipaddrs.join('|') || ''}` || `${hint.ip6addrs.join('|') || ''} ${mac}`;
			o.value(mac.toLowerCase(), '%s (%s)'.format(mac.toLowerCase(), name));
		});

		poll.add(L.bind(this.handleServiceReload, this), 5);

		return m.render();
	},

});