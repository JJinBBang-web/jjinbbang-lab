const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const {execFileSync} = require('node:child_process');
const path = require('node:path');

const manifest = path.resolve(__dirname, '../platform/workloads/n8n/forward-auth-hook-configmap.yaml');
const sources = JSON.parse(execFileSync('ruby', ['-ryaml', '-rjson', '-e',
  'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])).fetch("data"))', manifest], {encoding: 'utf8'}));

async function setup(user = {id: 'known', role: {slug: 'global:member'}}) {
  const pageContext = {module: {exports: {}}};
  vm.runInNewContext(sources['sso-page.js'], pageContext);
  let issued = 0;
  const context = {module: {exports: {}}, process: {env: {}}, console,
    require(name) {
      if (name === './sso-page') return pageContext.module.exports;
      if (name === '/usr/local/lib/node_modules/n8n/dist/auth/jwt') return {issueCookie() {issued++;}};
      throw Error('Unexpected module');
    },
  };
  vm.runInNewContext(sources['forward-auth-sso.js'], context);
  const app = {router: {stack: []}, use(handle) {this.router.stack.push({handle});}};
  const logger = {info() {}, warn() {}, error() {}};
  await context.module.exports.n8n.ready[0].call({dbCollections: {User: {findOne: async () => user}}}, {app, logger});
  return {handler: app.router.stack[0].handle, issued: () => issued};
}

async function request({url = '/', method = 'GET', headers = {}, user} = {}) {
  const runtime = await setup(user);
  let next = false;
  const req = {path: url, method, headers, get: name => headers[name.toLowerCase()],
    accepts: () => (headers.accept || '').includes('text/html')};
  const res = {statusCode: 200, headers: {}, cleared: [],
    status(n) {this.statusCode = n; return this;},
    set(key, value) {if (typeof key === 'object') Object.assign(this.headers, key); else this.headers[key] = value; return this;},
    type(value) {this.contentType = value; return this;},
    clearCookie(name) {this.cleared.push(name); return this;},
    send(body) {this.body = body; return this;},
    json(body) {this.body = body; return this;},
    redirect(code, url) {this.statusCode = code; this.location = url; return this;},
  };
  await runtime.handler(req, res, () => {next = true;});
  return {req, res, next, issued: runtime.issued()};
}

const identity = {'x-authentik-email': 'user@example.test', 'x-authentik-username': 'member'};
test('missing email shows account guidance and SSO logout, escapes identity', async () => {
  const r = await request({headers: {accept: 'text/html', 'x-authentik-username': '<script>alert(1)</script>'}});
  assert.equal(r.res.statusCode, 403);
  assert.match(r.res.body, /이메일이 없어/);
  assert.match(r.res.body, /action="\/sso\/logout"/);
  assert.match(r.res.body, /&lt;script&gt;/);
  assert.doesNotMatch(r.res.body, /<script>/);
  assert.equal(r.res.headers['Cache-Control'], 'no-store');
  // no-referrer turns a real browser form POST Origin into null.
  assert.equal(r.res.headers['Referrer-Policy'], 'same-origin');
  assert.equal(r.issued, 0);
  assert.equal(r.next, false);
});
test('missing email rejects API requests even when an old cookie is present', async () => {
  const r = await request({url: '/rest/login', headers: {'x-authentik-username': 'unlinked', cookie: 'n8n-auth=old'}});
  assert.equal(r.res.statusCode, 401);
  assert.deepEqual(r.res.cleared, ['n8n-auth']);
  assert.equal(r.next, false);
});
test('unknown and disabled accounts fail closed with browser guidance', async () => {
  for (const user of [null, {disabled: true, role: {}}, {id: 'no-role'}]) {
    const r = await request({user, headers: {...identity, accept: 'text/html'}});
    assert.equal(r.res.statusCode, 403);
    assert.match(r.res.body, /사용 가능 n8n 계정이 없습니다/);
    assert.equal(r.issued, 0);
  }
});
test('linked user still gets normal automatic login', async () => {
  const r = await request({url: '/rest/login', headers: identity});
  assert.equal(r.next, true);
  assert.equal(r.req.user.id, 'known');
  assert.equal(r.issued, 1);
});
test('signin offers continue and global logout without silently logging back in', async () => {
  const r = await request({url: '/signin', headers: {...identity, accept: 'text/html'}});
  assert.equal(r.res.statusCode, 200);
  assert.match(r.res.body, /SSO로 계속/);
  assert.match(r.res.body, /SSO 로그아웃/);
  assert.equal(r.issued, 0);
});
test('logout requires same-origin POST and redirects only to fixed Authentik flow', async () => {
  for (const origin of [undefined, 'null', 'https://attacker.example']) {
    const r = await request({url: '/sso/logout', method: 'POST', headers: {origin}});
    assert.equal(r.res.statusCode, 403);
    assert.equal(r.res.cleared.length, 0);
  }
  const get = await request({url: '/sso/logout'});
  assert.equal(get.res.statusCode, 405);
  const valid = await request({url: '/sso/logout', method: 'POST', headers: {origin: 'https://n8n.jjinbbang.kr'}});
  assert.equal(valid.res.statusCode, 303);
  assert.equal(valid.res.location, 'https://auth.jjinbbang.kr/flows/-/default/invalidation/');
  assert.deepEqual(valid.res.cleared, ['n8n-auth']);
  assert.match(valid.res.headers['Cache-Control'], /no-store/);
});
test('health and non-browser unauthenticated requests still reach existing n8n handlers', async () => {
  for (const url of ['/healthz', '/healthz/readiness', '/rest/login']) {
    const r = await request({url});
    assert.equal(r.next, true);
    assert.equal(r.issued, 0);
  }
});
