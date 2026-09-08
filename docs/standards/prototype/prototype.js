/* 设计原型专用：全部状态来自本地构造数据，不请求网络或读取真实账号。
   每个异步演示均先写入可感知的进度，取消时清理定时器，避免旧结果覆盖新场景。 */
(function () {
  'use strict';
  const el = function (id) { return document.getElementById(id); };
  let timer = null;
  let toastTimer = null;
  function announce(message) {
    el('toast').textContent = message;
    el('toast').hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el('toast').hidden = true; }, 2800);
  }
  async function copy(text) {
    try {
      await navigator.clipboard.writeText(text);
      announce('已复制：' + text);
    } catch (_) {
      announce('浏览器未允许复制，请手动选择文本：' + text);
    }
  }
  el('theme').addEventListener('change', function () {
    document.documentElement.dataset.theme = this.value;
  });
  if (document.body.dataset.page === 'dashboard') {
    let state = 'running';
    let expanded = false;
    let selectedModel = null;
    const modelButtons = Array.from(document.querySelectorAll('[data-model]'));
    const inactive = ['stopped', 'uninstalled', 'starting', 'stopping', 'failure'];
    function renderModels() {
      const blocked = inactive.includes(state);
      const loading = state === 'loading';
      const noData = blocked || loading || state === 'empty' || state === 'error';
      const totalCount = modelButtons.length;
      modelButtons.forEach(function (button) {
        button.hidden = noData || (!expanded && button.dataset.overflow === 'true');
      });
      document.querySelectorAll('.group').forEach(function (group) {
        group.hidden = !Array.from(group.querySelectorAll('[data-model]')).some(function (button) { return !button.hidden; });
      });
      el('model-count').textContent = noData ? '—' : String(totalCount);
      if (state === 'empty') el('model-count').textContent = '0';
      el('model-time').textContent = state === 'stale' ? '上次成功更新：5 分钟前 · 旧数据' : (noData ? '尚无当前目录' : '刚刚更新');
      el('catalog-notice').hidden = state !== 'stale' && state !== 'error';
      el('catalog-notice').textContent = state === 'stale' ? '刷新失败，以下保留上次成功读取的目录。请稍后重试。' : '模型加载失败，未取得可用目录。请重试。';
      el('model-empty').hidden = !noData && totalCount > 0;
      el('model-empty').textContent = blocked ? '启动 CPA 后载入当前可用模型。' : loading ? '正在载入模型…' : state === 'empty' ? 'CPA 当前未返回可用模型。' : state === 'error' ? '暂无可展示的模型' : '';
      // 页脚始终使用全部目录计数，仅根据展开状态改变已展示数量。
      const visibleCount = modelButtons.filter(function (button) { return !button.hidden; }).length;
      const hasHiddenModels = visibleCount < totalCount;
      el('model-footer').hidden = noData;
      el('model-visible-count').textContent = '已展示 ' + visibleCount + ' / 共 ' + totalCount + ' 个模型';
      el('model-more').hidden = noData || (!hasHiddenModels && !expanded);
      el('model-more').textContent = expanded ? '收起模型' : '展开全部模型';
      el('model-more').setAttribute('aria-expanded', String(expanded));
      el('model-refresh').disabled = blocked || loading;
      el('model-refresh').textContent = loading ? '正在刷新…' : '↻ 刷新模型';
      if (noData) el('model-detail').hidden = true;
    }
    function render() {
      const labels = {stopped:'○ 已停止',uninstalled:'尚未安装',starting:'正在启动…',stopping:'正在停止…',failure:'启动失败'};
      const busy = state === 'starting' || state === 'stopping';
      el('runtime-badge').textContent = labels[state] || '● 运行正常';
      el('runtime-badge').classList.toggle('good', !inactive.includes(state));
      el('runtime-sub').textContent = state === 'network' ? '允许网络访问 · 本机连接地址 · PID 77531' : state === 'unknown' ? '仅限本机 · PID 未提供' : inactive.includes(state) ? '仅限本机 · 当前无已确认运行 PID' : '仅限本机 · PID 77531';
      el('runtime-toggle').textContent = state === 'uninstalled' ? '安装 CPA' : busy ? labels[state] : inactive.includes(state) ? '▶ 启动 CPA' : '■ 停止 CPA';
      el('runtime-toggle').disabled = busy;
      el('runtime-refresh').disabled = busy;
      el('runtime-refresh').textContent = '↻ 刷新';
      el('runtime-error').hidden = state !== 'failure';
      el('runtime-error').textContent = '启动失败：演示端口被占用。检查端口后可重试启动。';
      el('guide').hidden = state !== 'new';
      el('accounts-count').textContent = state === 'new' ? '0' : '5';
      el('ready-count').textContent = state === 'new' ? '0 个就绪' : '5 个就绪';
      renderModels();
    }
    function change(next) { clearTimeout(timer); state = next; el('scenario').value = next; render(); }
    el('scenario').addEventListener('change', function () { change(this.value); });
    el('runtime-toggle').addEventListener('click', function () {
      if (state === 'uninstalled') {
        this.textContent = '正在安装…'; this.disabled = true;
        timer = setTimeout(function () { change('stopped'); announce('演示安装完成，可启动 CPA'); }, 1000);
        return;
      }
      const willStop = !inactive.includes(state);
      change(willStop ? 'stopping' : 'starting');
      timer = setTimeout(function () { change(willStop ? 'stopped' : 'running'); }, 900);
    });
    el('runtime-refresh').addEventListener('click', function () {
      this.disabled = true; this.textContent = '正在刷新…';
      const oldState = state;
      timer = setTimeout(function () { change(oldState); el('runtime-refresh').textContent = '↻ 刷新'; announce('已更新演示运行状态'); }, 700);
    });
    el('copy-base').addEventListener('click', function () { copy('http://127.0.0.1:8317'); });
    el('copy-api').addEventListener('click', function () { copy('http://127.0.0.1:8317/v1'); });
    el('model-refresh').addEventListener('click', function () {
      change('loading');
      timer = setTimeout(function () { change('running'); announce('模型目录已刷新'); }, 900);
    });
    el('model-more').addEventListener('click', function () { expanded = !expanded; renderModels(); });
    modelButtons.forEach(function (button) {
      button.addEventListener('click', function () {
        selectedModel = button;
        el('detail-id').textContent = button.dataset.model;
        el('detail-owner').textContent = '接口归属：' + button.dataset.owner;
        el('model-detail').hidden = false;
        el('detail-close').focus();
      });
    });
    el('detail-close').addEventListener('click', function () { el('model-detail').hidden = true; if (selectedModel) selectedModel.focus(); });
    el('detail-copy').addEventListener('click', function () { copy(el('detail-id').textContent); });
    el('guide-dismiss').addEventListener('click', function () { el('guide').hidden = true; });
    el('guide-provider').addEventListener('click', function () { el('guide-picker').hidden = !el('guide-picker').hidden; });
    el('guide-agent').addEventListener('click', function () { announce('演示入口：沿用当前已安装 CLI 的配置流程。'); });
    el('guide-oauth').addEventListener('click', function () { announce('正在演示 OAuth 授权…'); timer = setTimeout(function () { announce('授权演示完成，未连接真实账号。'); }, 800); });
    el('guide-import').addEventListener('click', function () { announce('Vertex JSON 导入演示完成；未读取真实文件。'); });
    el('tunnel-manage').addEventListener('click', function () { el('tunnel-preview').hidden = !el('tunnel-preview').hidden; });
    render();
  } else {
    let enabled = true;
    let lastAction = 'Claude OAuth';
    function renderProviders() {
      clearTimeout(timer);
      const empty = el('provider-scenario').value === 'empty';
      // 模拟原 connectedProviders / disconnectedProviders 分支；不把添加区拆成第二排。
      document.querySelectorAll('[data-connected-provider]').forEach(function (chip) { chip.hidden = empty; });
      document.querySelectorAll('[data-add-provider]').forEach(function (button) {
        const alreadyConnected = ['claude', 'codex', 'antigravity'].includes(button.dataset.addProvider);
        button.hidden = !empty && alreadyConnected;
      });
      el('account-list').hidden = empty;
      el('account-empty').hidden = !empty;
      el('account-ready').textContent = empty ? '0 个就绪' : (enabled ? '5 个就绪' : '4 个就绪');
      el('provider-action').hidden = true;
    }
    function action(name, retry) {
      clearTimeout(timer);
      lastAction = name;
      el('action-cancel').textContent = '取消';
      el('provider-action').hidden = false;
      el('action-cancel').hidden = false;
      el('action-retry').hidden = true;
      if (el('provider-scenario').value === 'stopped') {
        el('action-message').textContent = '请先启动 CPA，再添加提供商。可前往仪表盘启动。';
        return;
      }
      el('action-message').textContent = '正在演示 ' + name + '…';
      timer = setTimeout(function () {
        if (el('provider-scenario').value === 'failure' && !retry) {
          el('action-message').textContent = '授权失败（演示）。可重试，或取消后稍后连接。';
          el('action-retry').hidden = false;
        } else {
          el('action-message').textContent = name + ' 演示完成。未读取文件、创建账号或改变实际配置。';
          el('action-cancel').textContent = '关闭';
        }
      }, 900);
    }
    el('provider-scenario').addEventListener('change', renderProviders);
    el('add-claude').addEventListener('click', function () { action('Claude Code OAuth', false); });
    el('add-codex').addEventListener('click', function () { action('Codex OAuth', false); });
    el('add-qwen').addEventListener('click', function () { action('Qwen Code OAuth', false); });
    el('add-iflow').addEventListener('click', function () { action('iFlow OAuth', false); });
    el('add-antigravity').addEventListener('click', function () { action('Antigravity OAuth', false); });
    el('add-vertex').addEventListener('click', function () { action('Vertex AI JSON 导入', false); });
    el('add-kiro').addEventListener('click', function () { action('Kiro OAuth', false); });
    el('add-copilot').addEventListener('click', function () { action('GitHub Copilot OAuth', false); });
    el('action-cancel').addEventListener('click', function () { clearTimeout(timer); el('provider-action').hidden = true; this.textContent = '取消'; announce('已关闭演示操作'); });
    el('action-retry').addEventListener('click', function () { action(lastAction, true); });
    el('account-toggle').addEventListener('click', function () {
      enabled = !enabled;
      this.textContent = enabled ? '禁用' : '启用';
      el('account-state').textContent = enabled ? '已启用' : '已禁用';
      el('account-state').classList.toggle('good', enabled);
      el('account-ready').textContent = enabled ? '5 个就绪' : '4 个就绪';
    });
    renderProviders();
  }
}());
