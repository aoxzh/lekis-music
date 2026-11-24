const language = document.querySelector('#language');
const copy = document.querySelector('#copy');
const status = document.querySelector('#status');
const heading = document.querySelector('h1');
const headingMarkup = heading.innerHTML;
const strings = Array.from(document.querySelectorAll('[data-en]'), element => ({
  element, chinese: element.textContent, english: element.dataset.en
}));
const images = Array.from(document.querySelectorAll('[data-alt]'), element => ({
  element, chinese: element.alt, english: element.dataset.alt
}));

function setEnglish(english) {
  document.documentElement.lang = english ? 'en' : 'zh-CN';
  document.title = english ? 'Lekis Music' : '月兔音乐 · Lekis Music';
  document.querySelector('nav').setAttribute('aria-label', english ? 'Main navigation' : '主导航');
  language.lang = english ? 'zh-CN' : 'en';
  language.textContent = english ? '中文' : 'English';
  for (const item of strings) item.element.textContent = english ? item.english : item.chinese;
  for (const item of images) item.element.alt = english ? item.english : item.chinese;
  if (!english) heading.innerHTML = headingMarkup;
  status.textContent = '';
}

language.hidden = false;
setEnglish(!navigator.language.toLowerCase().startsWith('zh'));
language.addEventListener('click', () => setEnglish(document.documentElement.lang !== 'en'));
if (location.protocol === 'https:') {
  copy.hidden = false;
  copy.addEventListener('click', async () => {
    const url = new URL('plugins/bilibili.zip', location.href).href;
    try {
      await navigator.clipboard.writeText(url);
      status.textContent = document.documentElement.lang === 'en'
        ? 'Copied. Choose Install from link in Lekis and paste the address.'
        : '已复制。在月兔音乐里选「从链接安装」，粘贴地址即可。';
    } catch {
      status.textContent = url;
    }
  });
}
