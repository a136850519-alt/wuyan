// Local demonstration state only. No network calls, database access or installed-app changes.
const outlineHistory = new Map();
const originalSelectEntry = selectEntry;
const originalShowPage = showPage;
const savedMoods = new Map([['2026-10-10', 4], ['2025-10-09', 2]]);
entries.forEach(entry => { entry.day = '2026-10-10'; });
entries.push({id: 4, board: 'growth', day: '2025-10-09', title: '七岁的秋天', preview: '你认真地把落叶夹进书里。', time: '18:20', body: ['你认真地把落叶夹进书里，说要留住这个秋天。'], weather: 'rain', temp: 16.5, place: '上海'});
boards.five.questions[1] = '今天有什么小事值得留给未来的自己？';
const safeText = text => String(text).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const renderBody = () => {
  $('#bodycopy').replaceChildren(...current.body.map(text => {
    const p = document.createElement('p'); p.textContent = text; return p;
  }));
  $('#wordcount').textContent = current.body.join('').length + ' 字';
  $('#undoOutline').hidden = !outlineHistory.get(current.id)?.length;
};

renderTimeline = function () {
  const list = entries.filter(e => (!filter || e.board === filter) && e.title.includes($('#search').value));
  $('#timelineEntries').innerHTML = [...new Set(list.map(e => e.day))].sort().reverse().map(day => {
    const daily = list.filter(e => e.day === day);
    return `<div class="daylabel"><span>${day.replaceAll('-', ' / ')}</span><span>${daily.length} 篇</span></div>` + daily.map(e => `<button class="entry ${e.id === current.id ? 'active' : ''}" data-entry="${e.id}" aria-pressed="${e.id === current.id}"><div class="entryboard"><i class="dot ${boards[e.board].kind}"></i>${boards[e.board].name}</div><div class="entrytitle">${safeText(e.title)}</div><p class="entrypreview">${safeText(e.preview)}</p><div class="entryfoot"><span>${e.time}</span><span>${e.id === current.id ? '正在阅读' : '点击阅读'}</span></div></button>`).join('');
  }).join('') || '<p class="hint">没有匹配的文章。</p>';
  $$('[data-entry]').forEach(button => button.onclick = () => selectEntry(+button.dataset.entry));
};
selectEntry = function (id) {
  dayMood = savedMoods.get(entries.find(e => e.id === id).day) ?? null;
  originalSelectEntry(id);
  $('#moodheading').textContent = current.day === '2026-10-10' ? '今日心绪' : '当日心绪';
  $('.daynum').textContent = current.day.slice(-2);
  $('.datemeta').innerHTML = `${current.day.slice(0, 4)} 年 ${+current.day.slice(5, 7)} 月<br><span id="editorBoard">${boards[current.board].name}</span>`;
  const archive = $$('.archive .archiverow')[1];
  archive.replaceChildren(...[current.day.replaceAll('-', ' / '), current.time].map(text => { const span = document.createElement('span'); span.textContent = text; return span; }));
  const age = +current.day.slice(0, 4) - 2018;
  $('#growthcard').innerHTML = `<strong>${age} <span>岁</span></strong><p>${current.day.slice(0, 4)} 年的你<br>按该年生日后的岁数</p>`;
  $('#editWeather').setAttribute('aria-expanded', 'false');
  renderBody();
};
showPage = function (next) {
  if (next === 'ritual') dayMood = savedMoods.get('2026-10-10') ?? null;
  originalShowPage(next);
  $('#page-main').inert = next === 'ritual';
  $('.titlebar').inert = next === 'ritual';
  if (next === 'ritual') {
    $('#page-main').classList.add('active');
    $('#dailySentence').focus();
  }
  if (next === 'main') { selectEntry(current.id); $('#newEntry').focus(); }
};
saveDailyMood = function () {
  savedMoods.set('2026-10-10', ritualMood);
  dayMood = ritualMood;
  $('#ritualQuote').textContent = $('#dailySentence').value.trim() || '今日留白，也算一笔。';
  renderMood();
};
$('#saveMood').onclick = () => {
  if (!moodDraft) return;
  savedMoods.set(current.day, moodDraft);
  dayMood = moodDraft; moodEditing = false;
  renderMood(); $('#editMood').focus();
  toast('已保存示例心情，同一天各板块共用。');
};


function closeWeather() {
  $('#weatheredit').classList.add('hidden');
  $('#editWeather').setAttribute('aria-expanded', 'false');
  renderWeather(); $('#editWeather').focus();
}
$('#editWeather').onclick = () => {
  if (!$('#weatheredit').classList.contains('hidden')) return closeWeather();
  renderWeather(); weatherDraft = current.weather;
  $$('[data-weather]').forEach(button => button.setAttribute('aria-pressed', button.dataset.weather === weatherDraft));
  $('#weatheredit').classList.remove('hidden');
  $('#editWeather').setAttribute('aria-expanded', 'true');
};
$$('[data-weather]').forEach(button => button.onclick = () => {
  weatherDraft = button.dataset.weather;
  $$('[data-weather]').forEach(other => other.setAttribute('aria-pressed', other === button));
});
$('#cancelWeather').onclick = closeWeather;
$('#saveWeather').onclick = () => {
  const raw = $('#tempinput').value.trim();
  if (weatherDraft !== 'unknown' && (!raw || !Number.isFinite(Number(raw)) || !$('#tempinput').checkValidity())) {
    toast('温度需在 −100 至 70℃ 之间，可输入负数和小数。'); return;
  }
  current.weather = weatherDraft; current.temp = raw ? Number(raw) : null;
  current.place = $('#placeinput').value.trim() || '未设置地点';
  closeWeather(); toast('天气与地点已保存到当前示例。');
};

renderAI = function () {
  const board = boards[current.board];
  $('#aikind').textContent = '为「' + board.name + '」准备';
  $('#aiintro').textContent = current.board === 'growth' ? '把孩子的小小变化，认真留下。' : board.intro;
  $('#prompts').innerHTML = (alternate ? board.more : board.questions).map((q, i) => `<button class="prompt" data-prompt="${i}">${icon('i-arrow')}<span>${safeText(q)}</span></button>`).join('');
  $$('[data-prompt]').forEach(button => button.onclick = () => {
    const question = button.textContent;
    $('#airesult').classList.remove('hidden');
    $('#airesult').innerHTML = '<strong>可以这样展开</strong><p>先记下当时的场景、一句原话，再写自己的感受。</p><button id="insertPrompt">插入问题作为提纲</button>';
    $('#insertPrompt').onclick = () => {
      const history = outlineHistory.get(current.id) || [];
      history.push([...current.body]); outlineHistory.set(current.id, history);
      current.body.push(question); renderBody();
      toast('已插入提纲，可点击正文下方“撤销插入”。');
    };
  });
};
$('#undoOutline').onclick = () => { const previous = outlineHistory.get(current.id)?.pop(); if (previous) { current.body = previous; renderBody(); } };
$$('[data-ai]').forEach(button => button.onclick = () => {
  $('#airesult').classList.remove('hidden');
  const type = button.dataset.ai;
  const text = type === '标题' ? '记住这个小小的瞬间' : type === '标签' ? boards[current.board].tags.join('、') : '回顾范围：仅「' + boards[current.board].name + '」。此处展示结果区域，不请求 AI。';
  $('#airesult').innerHTML = `<p>示例${type}：${safeText(text)}</p>`;
  if (type === '回顾') return;
  const apply = document.createElement('button');
  apply.textContent = type === '标题' ? '使用这个标题' : '使用这些标签';
  apply.onclick = () => {
    if (type === '标题') { current.title = text; $('#articleTitle').textContent = text; renderTimeline(); }
    else $('#tags').innerHTML = text.split('、').map(tag => `<span class="chip">${safeText(tag)}</span>`).join('');
    $('#airesult').classList.add('hidden'); toast('已应用到当前示例。');
  };
  $('#airesult').append(apply);
});

const confirmation = document.createElement('div');
confirmation.className = 'modalconfirm hidden';
$('.modalfoot').before(confirmation);
function finishConflict(choice) {
  confirmation.classList.add('hidden');
  $('#conflictBody').innerHTML = `<div style="padding:48px;grid-column:1/-1"><h2>没有待处理的冲突</h2><p class="hint">${choice === '两份' ? '两份内容均已保留。' : '已保留' + choice + '。'} 这是示例状态，未修改真实日记。</p></div>`;
  $$('[data-resolve]').forEach(button => button.disabled = true);
  $('#conflictSummary').textContent = '全部处理完成（示例）';
}
$$('[data-resolve]').forEach(button => button.onclick = () => {
  if (button.dataset.resolve === '两份') return finishConflict('两份');
  confirmation.replaceChildren(); confirmation.classList.remove('hidden');
  const message = document.createElement('p'); message.textContent = '保留' + button.dataset.resolve + '将丢弃另一个示例版本。';
  const cancel = document.createElement('button'); cancel.textContent = '取消'; cancel.onclick = () => { confirmation.classList.add('hidden'); button.focus(); };
  const confirm = document.createElement('button'); confirm.textContent = '确认保留'; confirm.onclick = () => finishConflict(button.dataset.resolve);
  confirmation.append(message, cancel, confirm); cancel.focus();
});
const originalCloseModal = closeModal;
closeModal = function () { confirmation.classList.add('hidden'); originalCloseModal(); };
$('#closeConflict').onclick = closeModal; $('#returnSettings').onclick = closeModal;
$('#navigationToggle').onclick = () => $('.appgrid>.nav').classList.toggle('open');
document.addEventListener('keydown', event => {
  if (event.key !== 'Escape') return;
  if (!$('#weatheredit').classList.contains('hidden')) closeWeather();
  if (page === 'ritual') showPage('main');
  $('.appgrid>.nav').classList.remove('open');
  $('#inspector').classList.remove('open');
});
selectEntry(1);

$('#newEntry').onclick = () => showPage('ritual');
document.body.classList.toggle('light', !matchMedia('(prefers-color-scheme: dark)').matches);

// Feature preview: the browser build keeps password and export state in memory only.
let previewPasswordEnabled = false;
let previewLocked = false;
const lockOverlay = $('#diaryLockOverlay');
const lockPassword = $('#lockPassword');
const lockError = $('#lockError');
const lockStatus = $('#lockStatus');

function setPreviewLockStatus() {
  lockStatus.textContent = previewPasswordEnabled
    ? '日记密码已启用。网页预览使用内存状态，不会写入钥匙串。'
    : '预览中尚未启用。正式应用会使用系统钥匙串保存密码。';
  $('#setupPassword').textContent = previewPasswordEnabled ? '已设置示例密码' : '设置示例密码';
}
$('.lockhint').textContent = '网页预览示例密码：wuyan1234';

function lockPreviewDiary() {
  previewLocked = true;
  lockOverlay.classList.remove('hidden');
  document.querySelector('.shell').inert = true;
  lockPassword.value = '';
  lockError.textContent = '';
  requestAnimationFrame(() => lockPassword.focus());
}

function unlockPreviewDiary() {
  if (lockPassword.value !== 'wuyan1234') {
    lockError.textContent = '密码不正确，请重新输入。';
    lockPassword.select();
    return;
  }
  previewLocked = false;
  lockOverlay.classList.add('hidden');
  document.querySelector('.shell').inert = false;
  lockError.textContent = '';
  toast('已解锁示例日记。');
  $('#lockDiary').focus();
}

$('#lockDiary').onclick = lockPreviewDiary;
$('#settingsLock').onclick = lockPreviewDiary;
$('#setupPassword').onclick = () => {
  previewPasswordEnabled = true;
  setPreviewLockStatus();
  toast('示例密码已设置：wuyan1234');
};
$('#unlockDiary').onclick = unlockPreviewDiary;
lockPassword.onkeydown = event => {
  if (event.key === 'Enter') unlockPreviewDiary();
};
setPreviewLockStatus();

const wordExportModal = $('#wordExportModal');
const wordFileName = $('#wordFileName');
const exportDone = $('#exportDone');
function openWordExport() {
  const base = `${current.day || '2026-10-10'}_${current.title || '未命名日记'}`
    .replace(/[\\/:*?"<>|]/g, '_');
  wordFileName.value = `${base}.docx`;
  exportDone.classList.add('hidden');
  wordExportModal.classList.remove('hidden');
  wordFileName.focus();
  wordFileName.select();
}
function closeWordExport() {
  wordExportModal.classList.add('hidden');
  $('#exportWord').focus();
}
$('#exportWord').onclick = openWordExport;
$('#cancelWordExport').onclick = closeWordExport;
$('#confirmWordExport').onclick = () => {
  let fileName = wordFileName.value.trim() || '未命名日记.docx';
  if (!fileName.toLowerCase().endsWith('.docx')) fileName += '.docx';
  fileName = fileName.replace(/[\\/:*?"<>|]/g, '_');
  exportDone.textContent = `示例导出完成：下载/${fileName}（预览不会创建真实文件）`;
  exportDone.classList.remove('hidden');
  toast('已生成 Word 导出示例。');
};
wordExportModal.addEventListener('click', event => {
  if (event.target === wordExportModal) closeWordExport();
});
document.addEventListener('keydown', event => {
  if (event.key !== 'Escape') return;
  if (previewLocked) return;
  if (!wordExportModal.classList.contains('hidden')) closeWordExport();
});
