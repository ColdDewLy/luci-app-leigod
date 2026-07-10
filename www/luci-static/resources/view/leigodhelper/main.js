'use strict';
'require form';
'require poll';
'require request';
'require uci';
'require ui';
'require view';

function getData() {
    return request.get(L.url('admin/services/leigodhelper/get_data'), null, { timeout: 2000 }).then(function(res) {
        if (res.status === 200) {
            return res.json();
        }
        return { running: false, mode: 'OFF', switch_mode: '', interfaces: [], neighbors: [] };
    }).catch(function() {
        return { running: false, mode: 'OFF', switch_mode: '', interfaces: [], neighbors: [] };
    });
}

function renderStatus(data) {
    var isRunning = data.running;
    var mode = data.mode;
    var spanTemp = '<em><span style="color:%s"><strong>%s %s</strong></span></em>';
    var renderHTML;
    if (isRunning) {
        var color = (mode === 'OFF') ? 'orange' : 'green';
        var statusText = (mode === 'OFF') ? '运行中 (无加速任务)' : '运行中' + ' (' + mode + ')';
        renderHTML = spanTemp.format(color, '雷神加速器辅助插件', statusText);
    } else {
        renderHTML = spanTemp.format('red', '雷神加速器辅助插件', '未运行');
    }
    return renderHTML;
}

function handleInstall() {
    var logScrollInterval;
    var modalBody = E('div', { class: 'modal-body' }, [
        E('p', {}, '正在执行安装脚本，请耐心等待...'),
        E('div', { class: 'left' }, [
            E('button', {
                class: 'btn cbi-button-action',
                click: function(ev) {
                    var btn = ev.target;
                    btn.disabled = true;
                    btn.innerText = '正在启动...';

                    request.post(L.url('admin/services/leigodhelper/install')).then(function(res) {
                        if (res.status === 200) {
                            var logArea = E('pre', {
                                style: 'max-height: 400px; overflow-y: auto; background: #000; color: #0f0; padding: 10px; border: 1px solid #333; font-family: monospace; white-space: pre-wrap; font-size: 12px; margin-top: 10px;'
                            }, '正在初始化日志...');

                            modalBody.innerHTML = '';
                            modalBody.appendChild(E('h4', {}, '安装日志'));
                            modalBody.appendChild(logArea);

                            var closeBtn = E('button', {
                                class: 'btn cbi-button-neutral',
                                click: function() {
                                    if (logScrollInterval) clearInterval(logScrollInterval);
                                    ui.hideModal();
                                }
                            }, '关闭');
                            modalBody.appendChild(E('div', { class: 'right', style: 'margin-top: 10px;' }, [ closeBtn ]));

                            logScrollInterval = setInterval(function() {
                                request.get(L.url('admin/services/leigodhelper/get_install_log')).then(function(logRes) {
                                    if (logRes.status === 200) {
                                        var atBottom = (logArea.scrollHeight - logArea.scrollTop - logArea.clientHeight) < 20;
                                        var oldScrollTop = logArea.scrollTop;

                                        logArea.innerText = logRes.responseText;

                                        if (atBottom) {
                                            logArea.scrollTop = logArea.scrollHeight;
                                        } else {
                                            logArea.scrollTop = oldScrollTop;
                                        }
                                    }
                                });
                            }, 1000);
                        } else {
                            ui.addNotification(null, E('p', '安装接口调用失败。'), 'error');
                            ui.hideModal();
                        }
                    });
                }
            }, '确认安装'),
            E('button', {
                class: 'btn',
                click: function() { ui.hideModal(); }
            }, '取消')
        ])
    ]);

    ui.showModal('新版雷神加速器插件安装', [ modalBody ]);
}

function handleSwitchMode(currentMode) {
    var logScrollInterval;

    // 目标模式 = 与当前相反；无法识别当前模式时默认切到 tun
    var target = (currentMode === 'TUN') ? 'tproxy' : 'tun';
    var targetLabel = (target === 'tun') ? 'TUN' : 'TProxy';
    var curLabel = (currentMode && currentMode !== 'OFF') ? currentMode : '未知/未加速';

    var tip = (target === 'tun')
        ? '切换到 TUN 模式会停止雷神加速服务、修改启动脚本，并通过 opkg 安装 TUN 依赖包（需保证联网及软件源可用），最后重启服务。'
        : '切换到 TProxy 模式会停止雷神加速服务、修改启动脚本并重启服务（无需安装依赖）。';

    var modalBody = E('div', { class: 'modal-body' }, [
        E('p', {}, '当前加速模式：' + curLabel),
        E('p', {}, tip),
        E('div', { class: 'left' }, [
            E('button', {
                class: 'btn cbi-button-action',
                click: function(ev) {
                    var btn = ev.target;
                    btn.disabled = true;
                    btn.innerText = '正在启动...';

                    var postData = 'mode=' + encodeURIComponent(target);

                    request.post(L.url('admin/services/leigodhelper/switch_mode'), postData, {
                        headers: { 'Content-Type': 'application/x-www-form-urlencoded' }
                    }).then(function(res) {
                        if (res.status === 200) {
                            var logArea = E('pre', {
                                style: 'max-height: 400px; overflow-y: auto; background: #000; color: #0f0; padding: 10px; border: 1px solid #333; font-family: monospace; white-space: pre-wrap; font-size: 12px; margin-top: 10px;'
                            }, '正在初始化日志...');

                            modalBody.innerHTML = '';
                            modalBody.appendChild(E('h4', {}, '切换日志（切换到 ' + targetLabel + '）'));
                            modalBody.appendChild(logArea);

                            var closeBtn = E('button', {
                                class: 'btn cbi-button-neutral',
                                click: function() {
                                    if (logScrollInterval) clearInterval(logScrollInterval);
                                    ui.hideModal();
                                }
                            }, '关闭');
                            modalBody.appendChild(E('div', { class: 'right', style: 'margin-top: 10px;' }, [ closeBtn ]));

                            logScrollInterval = setInterval(function() {
                                request.get(L.url('admin/services/leigodhelper/get_switch_log')).then(function(logRes) {
                                    if (logRes.status === 200) {
                                        var atBottom = (logArea.scrollHeight - logArea.scrollTop - logArea.clientHeight) < 20;
                                        var oldScrollTop = logArea.scrollTop;

                                        logArea.innerText = logRes.responseText;

                                        if (atBottom) {
                                            logArea.scrollTop = logArea.scrollHeight;
                                        } else {
                                            logArea.scrollTop = oldScrollTop;
                                        }

                                        // 检测到结束标记后停止轮询
                                        if (/===切换(成功|失败)===/.test(logRes.responseText)) {
                                            if (logScrollInterval) clearInterval(logScrollInterval);
                                        }
                                    }
                                });
                            }, 1000);
                        } else {
                            ui.addNotification(null, E('p', '切换接口调用失败。'), 'error');
                            ui.hideModal();
                        }
                    });
                }
            }, '切换到 ' + targetLabel),
            E('button', {
                class: 'btn',
                click: function() { ui.hideModal(); }
            }, '取消')
        ])
    ]);

    ui.showModal('切换加速模式', [ modalBody ]);
}

return view.extend({
    load: function() {
        return getData();
    },

    render: function(data) {
        var m, s, o;

        m = new form.Map('leigodhelper', '雷神加速器辅助插件', '雷神加速器辅助插件是一款针对雷神官方openwrt加速插件的监控辅助插件。');

        // Status Section
        s = m.section(form.TypedSection);
        s.anonymous = true;
        s.render = function() {
            poll.add(function() {
                return getData().then(function(res) {
                    var view = document.getElementById('service_status');
                    if (view) {
                        view.innerHTML = renderStatus(res);
                    }
                });
            });

            return E('div', { class: 'cbi-section', id: 'status_bar' }, [
                E('p', { id: 'service_status' }, '正在收集数据...'),
                E('div', { class: 'left' }, [
                    E('button', {
                        class: 'btn cbi-button-apply',
                        click: handleInstall
                    }, '新版雷神加速器插件安装'),
                    E('button', {
                        class: 'btn cbi-button-action',
                        style: 'margin-left: 8px;',
                        click: function(ev) {
                            var btn = ev.target;
                            btn.disabled = true;
                            // 点击时重新拉取最新模式，避免使用 render 时的旧快照
                            getData().then(function(res) {
                                btn.disabled = false;
                                handleSwitchMode(res.switch_mode || res.mode);
                            });
                        }
                    }, '切换加速模式 (TProxy/TUN)')
                ])
            ]);
        };

        // Main configuration with tabs
        s = m.section(form.NamedSection, 'main', 'leigodhelper');
        s.addremove = false;

        s.tab('settings', '常规设置');
        s.tab('devices', '设备管理');
        s.tab('log', '运行日志');

        // Settings Tab
        o = s.taboption('settings', form.Flag, 'enabled', '启用');
        o.rmempty = false;

        o = s.taboption('settings', form.Value, 'check_interval', '检查间隔 (秒)');
        o.datatype = 'uinteger';
        o.default = '5';

        o = s.taboption('settings', form.Flag, 'notify_idle', '空闲通知', '当加速器开启但无流量时发送通知');
        o.rmempty = false;

        o = s.taboption('settings', form.Value, 'idle_threshold', '空闲阈值 (分钟)', '检测到无流量持续多久后发送通知');
        o.datatype = 'uinteger';
        o.default = '30';
        o.depends('notify_idle', '1');

        o = s.taboption('settings', form.ListValue, 'notification_type', '通知方式');
        o.value('telegram', 'Telegram');
        o.value('bark', 'Bark (iOS)');
        o.value('wecom', '企业微信');
        o.value('none', '关闭');
        o.default = 'none';
        o.depends('notify_idle', '1');

        o = s.taboption('settings', form.Value, 'tg_token', 'Telegram Bot Token');
        o.password = true;
        o.depends('notification_type', 'telegram');

        o = s.taboption('settings', form.Value, 'tg_chatid', 'Telegram Chat ID');
        o.depends('notification_type', 'telegram');

        o = s.taboption('settings', form.Value, 'bark_key', 'Bark Key');
        o.depends('notification_type', 'bark');

        o = s.taboption('settings', form.Value, 'wecom_key', '企业微信机器人 Key');
        o.depends('notification_type', 'wecom');

        o = s.taboption('settings', form.ListValue, 'conflict_svc', '关闭冲突插件', '当加速器启动时，自动关闭指定的插件以避免冲突，一般开启tun模式的才会有冲突');
        o.value('none', '不关闭');
        o.value('momo', 'Momo');
        o.value('openclash', 'OpenClash');
        o.value('nikki', 'Nikki');
        o.value('homeproxy', 'HomeProxy');
        o.value('passwall', 'PassWall');
        o.value('ssr-plus', 'SSRP (ShadowSocksR Plus+)');
        o.default = 'none';

        // Devices Tab
        o = s.taboption('devices', form.SectionValue, '_devices', form.TableSection, 'device', '设备管理');
        var ss = o.subsection;
        ss.anonymous = true;
        ss.addremove = true;
        ss.addbtntitle = '添加设备';

        var so = ss.option(form.Value, 'ip', 'IP 地址');
        so.datatype = 'ip4addr';
        so.rmempty = false;
        if (data && data.neighbors) {
            for (var i = 0; i < data.neighbors.length; i++) {
                var displayStr = (data.neighbors[i].hostname && data.neighbors[i].hostname !== '') ? 
                    '%s (%s) [%s]'.format(data.neighbors[i].ip, data.neighbors[i].mac, data.neighbors[i].hostname) :
                    '%s (%s)'.format(data.neighbors[i].ip, data.neighbors[i].mac);
                so.value(data.neighbors[i].ip, displayStr);
            }
        }

        so = ss.option(form.ListValue, 'type', '设备类型');
        so.value('auto', '自动识别');
        so.value('pc', 'PC');
        so.value('console', '主机');
        so.default = 'auto';

        // Log Tab
        o = s.taboption('log', form.DummyValue, '_log_view');
        o.rawhtml = true;
        o.render = function() {
            var logTextarea = E('textarea', {
                class: 'cbi-input-textarea',
                style: 'width: 100%; font-family: monospace; font-size: 12px; margin-top: 10px;',
                readonly: 'readonly',
                wrap: 'off',
                rows: 15
            }, '正在加载日志...');

            var updateLog = function() {
                return request.get(L.url('admin/services/leigodhelper/get_log')).then(function(res) {
                    if (res.status === 200 && logTextarea) {
                        // checking if user is at the bottom before update
                        var atBottom = (logTextarea.scrollHeight - logTextarea.scrollTop - logTextarea.clientHeight) < 20;
                        var oldScrollTop = logTextarea.scrollTop;

                        logTextarea.value = res.responseText;

                        // only auto-scroll if user was already at the bottom
                        if (atBottom) {
                            logTextarea.scrollTop = logTextarea.scrollHeight;
                        } else {
                            logTextarea.scrollTop = oldScrollTop;
                        }
                    }
                });
            };

            updateLog();
            poll.add(updateLog, 3);

            return E('div', { class: 'cbi-section' }, [
                E('div', { class: 'cbi-section-descr' }, '插件运行日志。'),
                logTextarea,
                E('div', { class: 'cbi-section-create' }, [
                    E('button', {
                        class: 'btn cbi-button-reset',
                        click: function(ev) {
                            var btn = ev.target;
                            btn.disabled = true;
                            btn.innerText = '清理中...';
                            request.post(L.url('admin/services/leigodhelper/clear_log')).then(function() {
                                btn.disabled = false;
                                btn.innerText = '清理日志';
                                logTextarea.value = '';
                            });
                        }
                    }, '清理日志')
                ])
            ]);
        };

        return m.render();
    }
});
