'use strict';

// The wheel is an illustration, not an upload or a file converter.
const wheelContent = {
  convert: {
    labels: ['JPG', 'WEBP', 'HEIC', 'TIFF', 'AVIF', 'BMP', 'PDF'],
    descriptions: [
      'JPG · A familiar format for photographs.',
      'WEBP · A compact image format for the web.',
      'HEIC · Efficient encoding for compatible devices.',
      'TIFF · A format for high-quality image workflows.',
      'AVIF · A modern format where an encoder is available.',
      'BMP · An uncompressed bitmap image.',
      'PDF · Put an image on a document page.'
    ],
    title: '3.2 MB',
    subtitle: 'weekend.png',
    hint: 'Choose a format. Keep your original.',
    ariaLabel: 'Illustrative conversion options'
  },
  tools: {
    labels: ['RESIZE', 'CROP', 'ROTATE', 'COMPRESS', 'OCR', 'QR CODE', 'METADATA'],
    descriptions: [
      'Resize · Choose dimensions and preview the encoded size.',
      'Crop · Set an aspect ratio and adjust the selection.',
      'Rotate · Turn an image and save a separate copy.',
      'Compress · Change encoding quality, keeping pixel dimensions.',
      'OCR · Recognize text locally on your Mac.',
      'QR Code · Read a code from an image.',
      'Metadata · Remove selected image metadata.'
    ],
    title: 'Your tools',
    subtitle: 'For this file',
    hint: 'The tools you need. The way you like them.',
    ariaLabel: 'Illustrative image tool options'
  },
  actions: {
    labels: ['AIRDROP', 'DETAILS', 'COPY', 'PATH', 'MOVE', 'TERMINAL', 'FLOAT'],
    descriptions: [
      'AirDrop · Choose someone to share your file with.',
      'Details · See file information and available metadata.',
      'Copy · Copy the selected file.',
      'Path · Copy the file location.',
      'Move · Choose a destination for the selected file.',
      'Terminal · Open the containing folder in Terminal.',
      'Float · Keep the file on a floating shelf.'
    ],
    title: 'One more thing',
    subtitle: 'Everyday actions',
    hint: 'Useful actions, all in one place.',
    ariaLabel: 'Illustrative file action options'
  }
};

const SVG_NS = 'http://www.w3.org/2000/svg';
const wheel = document.querySelector('#demo-wheel');
const status = document.querySelector('#demo-status');
const announcement = document.querySelector('#demo-announcement');
let activeWheel = 'convert';

function polar(radius, angle) {
  const radians = angle * Math.PI / 180;
  return [170 + radius * Math.cos(radians), 170 + radius * Math.sin(radians)];
}

function point(radius, angle) {
  return polar(radius, angle).map(value => value.toFixed(2)).join(' ');
}

function sectorPath(start, end) {
  const outer = 163;
  const inner = 60;
  const corner = 10;
  const outerAngle = 4;
  const innerAngle = 9;
  return [
    `M ${point(outer, start + outerAngle)}`,
    `A ${outer} ${outer} 0 0 1 ${point(outer, end - outerAngle)}`,
    `Q ${point(outer, end)} ${point(outer - corner, end)}`,
    `L ${point(inner + corner, end)}`,
    `Q ${point(inner, end)} ${point(inner, end - innerAngle)}`,
    `A ${inner} ${inner} 0 0 0 ${point(inner, start + innerAngle)}`,
    `Q ${point(inner, start)} ${point(inner + corner, start)}`,
    `L ${point(outer - corner, start)}`,
    `Q ${point(outer, start)} ${point(outer, start + outerAngle)}`,
    'Z'
  ].join(' ');
}

function svgElement(tag, attributes) {
  const element = document.createElementNS(SVG_NS, tag);
  Object.entries(attributes).forEach(([name, value]) => element.setAttribute(name, value));
  return element;
}

function selectSector(index, speak = false) {
  const content = wheelContent[activeWheel];
  wheel.querySelectorAll('.wheel-wedge').forEach((element, itemIndex) => {
    element.classList.toggle('is-active', itemIndex === index);
    element.setAttribute('aria-pressed', String(itemIndex === index));
  });
  status.textContent = content.descriptions[index];
  if (speak) announcement.textContent = `${content.descriptions[index]} This is an illustration. Download Orange to work with your files.`;
}

function renderWheel(name) {
  activeWheel = name;
  const content = wheelContent[name];
  const svg = svgElement('svg', { viewBox: '0 0 340 340', class: 'wheel-svg', 'aria-label': content.ariaLabel });
  const defs = svgElement('defs', {});
  const glass = svgElement('linearGradient', { id: 'glass', x1: '0', y1: '0', x2: '.2', y2: '1' });
  glass.append(svgElement('stop', { offset: '0', 'stop-color': '#fff', 'stop-opacity': '.77' }), svgElement('stop', { offset: '1', 'stop-color': '#fff4df', 'stop-opacity': '.55' }));
  const selected = svgElement('linearGradient', { id: 'selected', x1: '0', y1: '0', x2: '.5', y2: '1' });
  selected.append(svgElement('stop', { offset: '0', 'stop-color': '#bb4d0c' }), svgElement('stop', { offset: '1', 'stop-color': '#983b08' }));
  defs.append(glass, selected);
  svg.append(defs);
  content.labels.forEach((label, index) => {
    const angle = -90 + index * 360 / content.labels.length;
    const halfAngle = 180 / content.labels.length - 1.2;
    const group = svgElement('g', { class: 'wheel-wedge', role: 'button', tabindex: '0', 'aria-label': `${label}: ${content.descriptions[index].split(' · ')[1]}`, 'aria-pressed': 'false' });
    const shape = svgElement('path', { class: 'wedge-shape', d: sectorPath(angle - halfAngle, angle + halfAngle) });
    const [x, y] = polar(111, angle);
    const text = svgElement('text', { x: String(x), y: String(y), class: 'wedge-text', 'text-anchor': 'middle', 'dominant-baseline': 'central' });
    if (label.length > 7) text.setAttribute('style', 'font-size:8px');
    text.textContent = label;
    group.append(shape, text);
    group.addEventListener('pointerenter', () => selectSector(index));
    group.addEventListener('focus', () => selectSector(index));
    group.addEventListener('click', () => selectSector(index, true));
    group.addEventListener('keydown', event => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        selectSector(index, true);
      }
      if (['ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp'].includes(event.key)) {
        event.preventDefault();
        const delta = ['ArrowRight', 'ArrowDown'].includes(event.key) ? 1 : -1;
        const next = (index + delta + content.labels.length) % content.labels.length;
        svg.querySelectorAll('.wheel-wedge')[next].focus();
      }
    });
    svg.append(group);
  });
  wheel.replaceChildren(svg);
  wheel.setAttribute('aria-label', content.ariaLabel);
  document.querySelector('#wheel-center-title').textContent = content.title;
  document.querySelector('#wheel-center-subtitle').textContent = content.subtitle;
  status.textContent = content.hint;
  document.querySelectorAll('[data-wheel]').forEach(button => {
    button.setAttribute('aria-pressed', String(button.dataset.wheel === name));
  });
  // An initial highlight communicates that the segments are interactive.
  wheel.querySelectorAll('.wheel-wedge')[1].classList.add('is-active');
  wheel.querySelectorAll('.wheel-wedge')[1].setAttribute('aria-pressed', 'true');
}

if (wheel) {
  renderWheel('convert');
  document.querySelectorAll('[data-wheel]').forEach(button => {
    button.addEventListener('click', () => renderWheel(button.dataset.wheel));
  });
}
