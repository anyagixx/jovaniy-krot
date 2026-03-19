const API = window.location.origin + '/api';
let token = localStorage.getItem('token');
let currentClientId = null;

const loginScreen = document.getElementById('login-screen');
const dashboard = document.getElementById('dashboard');
const loginForm = document.getElementById('login-form');
const loginError = document.getElementById('login-error');
const logoutBtn = document.getElementById('logout-btn');
const addClientBtn = document.getElementById('add-client-btn');
const addModal = document.getElementById('add-modal');
const clientModal = document.getElementById('client-modal');
const addClientForm = document.getElementById('add-client-form');
const clientsList = document.getElementById('clients-list');
const updateIpsBtn = document.getElementById('update-ips-btn');

document.addEventListener('DOMContentLoaded', () => {
    if (token) showDashboard();
    
    loginForm.addEventListener('submit', handleLogin);
    logoutBtn.addEventListener('click', handleLogout);
    addClientBtn.addEventListener('click', () => showModal(addModal));
    addClientForm.addEventListener('submit', handleAddClient);
    updateIpsBtn.addEventListener('click', handleUpdateIps);
    
    document.querySelectorAll('.modal-close').forEach(btn => {
        btn.addEventListener('click', () => {
            hideModal(addModal);
            hideModal(clientModal);
        });
    });
    
    document.querySelectorAll('.modal').forEach(modal => {
        modal.addEventListener('click', (e) => {
            if (e.target === modal) hideModal(modal);
        });
    });
    
    document.getElementById('download-config-btn').addEventListener('click', handleDownloadConfig);
    document.getElementById('copy-config-btn').addEventListener('click', handleCopyConfig);
    document.getElementById('toggle-client-btn').addEventListener('click', handleToggleClient);
    document.getElementById('delete-client-btn').addEventListener('click', handleDeleteClient);
});

async function handleLogin(e) {
    e.preventDefault();
    const username = document.getElementById('username').value;
    const password = document.getElementById('password').value;
    
    try {
        const res = await fetch(`${API}/auth/login`, {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({username, password})
        });
        
        if (!res.ok) throw new Error('Invalid credentials');
        
        const data = await res.json();
        token = data.access_token;
        localStorage.setItem('token', token);
        showDashboard();
    } catch (err) {
        loginError.textContent = 'Неверный логин или пароль';
    }
}

function handleLogout() {
    token = null;
    localStorage.removeItem('token');
    loginScreen.classList.remove('hidden');
    dashboard.classList.add('hidden');
}

function showDashboard() {
    loginScreen.classList.add('hidden');
    dashboard.classList.remove('hidden');
    loadStats();
    loadClients();
    loadRoutingStatus();
    setInterval(() => {
        loadStats();
        loadClients();
        loadRoutingStatus();
    }, 30000);
}

async function api(endpoint, options = {}) {
    const res = await fetch(`${API}${endpoint}`, {
        ...options,
        headers: {
            ...options.headers,
            'Authorization': `Bearer ${token}`
        }
    });
    
    if (res.status === 401) {
        handleLogout();
        return null;
    }
    
    if (!res.ok) {
        const error = await res.json().catch(() => ({}));
        throw new Error(error.detail || 'Request failed');
    }
    
    return res;
}

async function loadStats() {
    try {
        const res = await api('/stats');
        if (!res) return;
        const data = await res.json();
        
        document.getElementById('total-clients').textContent = data.total_clients;
        document.getElementById('active-clients').textContent = data.active_clients;
        document.getElementById('total-upload').textContent = formatBytes(data.total_upload);
        document.getElementById('total-download').textContent = formatBytes(data.total_download);
        document.getElementById('server-uptime').textContent = data.server_uptime;
    } catch (err) {
        console.error('Failed to load stats:', err);
    }
}

async function loadRoutingStatus() {
    try {
        const res = await api('/routing/status');
        if (!res) return;
        const data = await res.json();
        
        const tunnelEl = document.getElementById('tunnel-status');
        tunnelEl.textContent = data.tunnel.status === 'up' ? '🟢 Работает' : 
                              data.tunnel.status === 'no_connectivity' ? '🟡 Нет связи' : '🔴 Отключен';
        tunnelEl.className = 'routing-value ' + (data.tunnel.status === 'up' ? 'online' : 'offline');
        
        const ipsetEl = document.getElementById('ipset-status');
        ipsetEl.textContent = data.ipset.status === 'active' ? 
                             `✅ ${data.ipset.entries} подсетей` : '❌ Неактивен';
        ipsetEl.className = 'routing-value ' + (data.ipset.status === 'active' ? 'online' : 'offline');
    } catch (err) {
        console.error('Failed to load routing status:', err);
    }
}

async function handleUpdateIps() {
    updateIpsBtn.disabled = true;
    updateIpsBtn.textContent = 'Обновление...';
    
    try {
        await api('/routing/update-ips', {method: 'POST'});
        loadRoutingStatus();
    } catch (err) {
        alert('Ошибка обновления: ' + err.message);
    }
    
    updateIpsBtn.disabled = false;
    updateIpsBtn.textContent = 'Обновить IP РФ';
}

async function loadClients() {
    try {
        const res = await api('/clients');
        if (!res) return;
        const clients = await res.json();
        
        if (clients.length === 0) {
            clientsList.innerHTML = `
                <div class="empty-state">
                    <div class="empty-state-icon">📱</div>
                    <p>Нет клиентов. Добавьте первого!</p>
                </div>
            `;
            return;
        }
        
        clientsList.innerHTML = clients.map(client => `
            <div class="client-item" data-id="${client.id}">
                <div class="client-info">
                    <div class="client-status ${client.is_active ? 'active' : ''}"></div>
                    <div>
                        <span class="client-name">${escapeHtml(client.name)}</span>
                        <span class="client-ip">${client.address}</span>
                    </div>
                </div>
                <div class="client-stats">
                    <span>⬆️ ${formatBytes(client.upload_bytes)}</span>
                    <span>⬇️ ${formatBytes(client.download_bytes)}</span>
                    <span>${client.last_handshake ? formatTime(client.last_handshake) : '—'}</span>
                </div>
            </div>
        `).join('');
        
        document.querySelectorAll('.client-item').forEach(item => {
            item.addEventListener('click', () => showClientDetails(item.dataset.id));
        });
    } catch (err) {
        console.error('Failed to load clients:', err);
    }
}

async function handleAddClient(e) {
    e.preventDefault();
    const name = document.getElementById('client-name').value;
    
    try {
        const res = await api('/clients', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({name})
        });
        
        if (!res) return;
        
        hideModal(addModal);
        document.getElementById('client-name').value = '';
        loadClients();
        loadStats();
        
        const client = await res.json();
        showClientDetails(client.id);
    } catch (err) {
        alert('Ошибка создания клиента: ' + err.message);
    }
}

async function showClientDetails(clientId) {
    currentClientId = clientId;
    
    try {
        const qrRes = await api(`/clients/${clientId}/qr`);
        if (!qrRes) return;
        const qrBlob = await qrRes.blob();
        const qrUrl = URL.createObjectURL(qrBlob);
        document.getElementById('client-qr-img').src = qrUrl;
        
        const clients = await (await api('/clients')).json();
        const client = clients.find(c => c.id == clientId);
        
        if (client) {
            document.getElementById('client-modal-title').textContent = client.name;
            document.getElementById('client-config-text').textContent = client.config;
        }
        
        showModal(clientModal);
    } catch (err) {
        console.error('Failed to load client details:', err);
    }
}

async function handleDownloadConfig() {
    if (!currentClientId) return;
    
    try {
        const res = await api(`/clients/${currentClientId}/config`);
        if (!res) return;
        
        const blob = await res.blob();
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = 'vpn-client.conf';
        a.click();
        URL.revokeObjectURL(url);
    } catch (err) {
        alert('Ошибка скачивания: ' + err.message);
    }
}

function handleCopyConfig() {
    const configEl = document.getElementById('client-config-text');
    if (!configEl) {
        alert('Конфиг не найден');
        return;
    }
    
    const config = configEl.textContent || configEl.innerText;
    
    // Создаем временный textarea для копирования
    const textarea = document.createElement('textarea');
    textarea.value = config;
    textarea.style.position = 'fixed';
    textarea.style.left = '-9999px';
    document.body.appendChild(textarea);
    textarea.select();
    textarea.setSelectionRange(0, 99999);
    
    try {
        const successful = document.execCommand('copy');
        const btn = document.getElementById('copy-config-btn');
        const originalText = btn.textContent;
        btn.textContent = successful ? '✅ Скопировано!' : '❌ Ошибка';
        setTimeout(() => btn.textContent = originalText, 2000);
    } catch (err) {
        alert('Ошибка копирования: ' + err);
    }
    
    document.body.removeChild(textarea);
}

async function handleToggleClient() {
    if (!currentClientId) return;
    
    try {
        const res = await api(`/clients/${currentClientId}/toggle`, {method: 'POST'});
        if (!res) return;
        const data = await res.json();
        
        loadClients();
        loadStats();
        
        const btn = document.getElementById('toggle-client-btn');
        btn.textContent = data.is_active ? '🔴 Выключить' : '🟢 Включить';
    } catch (err) {
        alert('Ошибка: ' + err.message);
    }
}

async function handleDeleteClient() {
    if (!currentClientId) return;
    if (!confirm('Удалить этого клиента?')) return;
    
    try {
        await api(`/clients/${currentClientId}`, {method: 'DELETE'});
        hideModal(clientModal);
        loadClients();
        loadStats();
    } catch (err) {
        alert('Ошибка удаления: ' + err.message);
    }
}

function showModal(modal) {
    modal.classList.remove('hidden');
}

function hideModal(modal) {
    modal.classList.add('hidden');
}

function formatBytes(bytes) {
    if (!bytes || bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
}

function formatTime(dateStr) {
    const date = new Date(dateStr);
    const now = new Date();
    const diff = now - date;
    
    if (diff < 60000) return 'только что';
    if (diff < 3600000) return Math.floor(diff / 60000) + ' мин назад';
    if (diff < 86400000) return Math.floor(diff / 3600000) + ' ч назад';
    return date.toLocaleDateString('ru-RU');
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}
