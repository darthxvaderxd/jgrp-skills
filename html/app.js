(function () {
    const app = document.getElementById('app');
    const list = document.getElementById('skillList');
    const emptyState = document.getElementById('emptyState');
    const closeBtn = document.getElementById('closeBtn');

    function resourceName() {
        return (typeof GetParentResourceName === 'function')
            ? GetParentResourceName()
            : 'jgrp-skills';
    }

    function post(name, body) {
        return fetch(`https://${resourceName()}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(body || {}),
        }).catch(() => {
        });
    }

    function fmt(n) {
        return Math.max(0, Math.floor(Number(n) || 0)).toLocaleString();
    }

    function escapeHtml(str) {
        const div = document.createElement('div');
        div.textContent = str == null ? '' : String(str);
        return div.innerHTML;
    }

    function rowHTML(row) {
        const atMax = !!row.atMaxLevel || !row.xpForNextLevel;
        const pct = atMax
            ? 100
            : Math.max(0, Math.min(100, (row.xp / row.xpForNextLevel) * 100));

        const xpText = atMax
            ? 'MAX LEVEL'
            : `${fmt(row.xp)} / ${fmt(row.xpForNextLevel)} XP`;

        return `
            <div class="skill-row${row.synced === false ? ' not-synced' : ''}" data-skill="${escapeHtml(row.skill)}">
                <div class="skill-row-top">
                    <span class="skill-xp">${xpText}</span>
                    <span class="skill-name">${escapeHtml(row.label)}</span>
                    <span class="skill-level${atMax ? ' max' : ''}">Level ${escapeHtml(row.level)}${atMax ? ' (MAX)' : ''}</span>
                </div>
                <div class="skill-bar-track">
                    <div class="skill-bar-fill${atMax ? ' max' : ''}" style="width:${pct}%"></div>
                </div>
            </div>
        `;
    }

    function render(skills) {
        skills = Array.isArray(skills) ? skills : [];

        if (skills.length === 0) {
            list.innerHTML = '';
            emptyState.classList.remove('hidden');
            return;
        }

        emptyState.classList.add('hidden');
        list.innerHTML = skills.map(rowHTML).join('');
    }

    function open(skills) {
        render(skills);
        app.classList.remove('hidden');
    }

    function close() {
        app.classList.add('hidden');
        post('jgrp-skills:close');
    }

    window.addEventListener('message', (event) => {
        const data = event.data || {};

        switch (data.action) {
            case 'open':
                open(data.skills);
                break;
            case 'update':
                render(data.skills);
                break;
            case 'close':
                app.classList.add('hidden');
                break;
        }
    });

    closeBtn.addEventListener('click', close);

    document.addEventListener('keydown', (event) => {
        if (event.key === 'Escape' && !app.classList.contains('hidden')) {
            close();
        }
    });
})();
