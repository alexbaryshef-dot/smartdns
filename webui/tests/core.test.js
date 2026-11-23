'use strict';
const test = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const FSD = require(path.join(__dirname, '..', 'src', 'www', 'core.js'));

test('parseSchema reads tab separated rows and skips comments', () => {
  const schema = FSD.parseSchema('# c\ncache-size\tint\t-1\t10\t-\tcache\tРазмер\t4096\tподсказка\nresponse-mode\tresponse\t-\t-\tfirst-ping|fastest-ip\tgeneral\tРежим\tfirst-ping\t');
  assert.equal(schema.length, 2);
  assert.equal(schema[0].key, 'cache-size');
  assert.equal(schema[0].type, 'int');
  assert.equal(schema[1].enumValues.length, 2);
});

test('globals preserve unknown directives', () => {
  const schema = FSD.parseSchema('cache-size\tint\t-1\t10\t-\tcache\tКэш\t4096\t');
  const original = 'cache-size 100\ncustom-thing 42\n';
  const values = { 'cache-size': '200' };
  const out = FSD.renderGlobals(original, schema, values);
  assert.match(out, /cache-size 200/);
  assert.match(out, /custom-thing 42/);
  assert.doesNotMatch(out, /cache-size 100/);
});

test('items round trip', () => {
  const block = '# comment\nserver 1.1.1.1 -group g\naddress /example.com/1.2.3.4\n';
  const items = FSD.parseLines(block);
  assert.equal(items.length, 2);
  assert.equal(items[0].directive, 'server');
  assert.deepEqual(items[0].args, ['1.1.1.1', '-group', 'g']);
  assert.equal(FSD.renderItems(items), 'server 1.1.1.1 -group g\naddress /example.com/1.2.3.4\n');
});

test('groups parse and render', () => {
  const block = 'group-begin office -inherit default\ngroup-match -domain example.com\ngroup-match -client-ip 192.168.1.0/24\ngroup-end\n';
  const parsed = FSD.parseGroups(block);
  assert.equal(parsed.groups.length, 1);
  assert.equal(parsed.groups[0].name, 'office');
  assert.equal(parsed.groups[0].lines.length, 2);
  const rendered = FSD.renderGroups(parsed.groups);
  assert.match(rendered, /group-begin office -inherit default/);
  assert.match(rendered, /group-match -domain example.com/);
  assert.match(rendered, /group-end/);
});

test('validators', () => {
  assert.equal(FSD.isIP('192.168.1.1'), true);
  assert.equal(FSD.isIP('999.1.1.1'), false);
  assert.equal(FSD.isCIDR('10.0.0.0/8'), true);
  assert.equal(FSD.isCIDR('10.0.0.0/33'), false);
  assert.equal(FSD.isDomain('example.com'), true);
  assert.equal(FSD.isDomain('*.example.com'), true);
  assert.equal(FSD.isMac('aa:bb:cc:dd:ee:ff'), true);
  assert.equal(FSD.validateValue({ type: 'int', min: '0', max: '10' }, '11'), 'максимум 10');
  assert.equal(FSD.validateValue({ type: 'yesno' }, 'yes'), '');
  assert.equal(FSD.validateValue({ type: 'speed' }, 'ping,tcp:443'), '');
});

test('formatting and escaping', () => {
  assert.equal(FSD.formatUptime(65), '1 мин 5 с');
  assert.equal(FSD.formatBytes(2048), '2.0 КиБ');
  assert.equal(FSD.escapeHtml('<a "x">'), '&lt;a &quot;x&quot;&gt;');
  assert.equal(FSD.parseQType(28), 'AAAA');
  assert.equal(FSD.parseRCode(3), 'NXDOMAIN');
});
