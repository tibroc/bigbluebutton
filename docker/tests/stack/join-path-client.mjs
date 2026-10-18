// Client part of join-path.sh: does what the html5 client does when a user joins, up to the
// GraphQL subscription, and prints `STEP <name>: OK|FAIL ...` per step. Runs with Node 24
// (global fetch and WebSocket), started by join-path.sh in a container on the host network.
//
// Arguments: BASE_URL (https://<domain>) TIMEOUT_SECONDS. The shared secret is the first line
// of stdin; it is used only to compute checksums and is never printed.
//
// Exit status: 0 every step OK, 1 a step failed.

import { createHash, randomUUID } from 'node:crypto';

// node -e: argv[1] is the first argument.
const [baseUrl, timeoutArg] = process.argv.slice(1);
const timeoutMs = Number(timeoutArg || 30) * 1000;
const base = new URL(baseUrl);

let input = '';
for await (const chunk of process.stdin) input += chunk;
const secret = input.split('\n')[0].trim();
if (!secret) {
  console.log('STEP secret: FAIL no shared secret on stdin');
  process.exit(1);
}

// Header names as the client sends them (settings-loader, connection-manager; see below).
const SESSION_HEADER = 'x-session-token';
const WS_SESSION_HEADER = 'X-Session-Token';

class StepError extends Error {}
const ok = (name, detail = '') => console.log(`STEP ${name}: OK${detail ? ` ${detail}` : ''}`);
const fail = (detail) => { throw new StepError(detail); };

// Cookies as a browser keeps them for this host (JSESSIONID from bbb-web on join).
const cookies = new Map();
const keepCookies = (res) => {
  for (const c of res.headers.getSetCookie()) {
    const [pair] = c.split(';');
    const i = pair.indexOf('=');
    if (i > 0) cookies.set(pair.slice(0, i).trim(), pair.slice(i + 1).trim());
  }
};
const cookieHeader = () => [...cookies].map(([k, v]) => `${k}=${v}`).join('; ');

async function get(url, headers = {}, redirect = 'follow') {
  const res = await fetch(url, {
    headers: { ...headers, ...(cookies.size ? { cookie: cookieHeader() } : {}) },
    redirect,
    signal: AbortSignal.timeout(timeoutMs),
  });
  keepCookies(res);
  return res;
}

// API call with checksum = sha1(call + query + secret) (bbb-web ApiParams / docs "API Security
// Model"). The URL carries only the checksum.
function apiUrl(call, params) {
  const query = new URLSearchParams(params).toString();
  const checksum = createHash('sha1').update(call + query + secret).digest('hex');
  return new URL(`/bigbluebutton/api/${call}?${query}&checksum=${checksum}`, base);
}
const xmlTag = (xml, tag) => (xml.match(new RegExp(`<${tag}>(?:<!\\[CDATA\\[)?([\\s\\S]*?)(?:\\]\\]>)?</${tag}>`)) || [])[1];
// A session token or checksum never reaches the output.
const redact = (s) => String(s).replace(/(sessionToken|checksum|access_token)=[^&\s"]*/g, '$1=__REDACTED__');

const meetingID = `join-path-${Date.now()}`;
let created = false;

async function run() {
  let step = 'api-index';
  try {
    // 1. BBBWeb.index (bigbluebutton-html5/imports/api/bbb-web-api/index.ts:32-38): JSON.
    let res = await get(new URL('/bigbluebutton/api', base), { 'Content-Type': 'application/json' });
    if (res.status !== 200) fail(`HTTP ${res.status}`);
    const index = (await res.json()).response;
    if (index?.returncode !== 'SUCCESS' || !index.graphqlApiUrl || !index.graphqlWebsocketUrl) {
      fail(`unexpected index ${JSON.stringify(index).slice(0, 300)}`);
    }
    ok(step, `graphqlApiUrl=${index.graphqlApiUrl} graphqlWebsocketUrl=${index.graphqlWebsocketUrl}`);

    step = 'create';
    res = await get(apiUrl('create', { name: 'join-path test', meetingID }));
    let xml = await res.text();
    if (res.status !== 200 || xmlTag(xml, 'returncode') !== 'SUCCESS') fail(`HTTP ${res.status} ${xml.slice(0, 300)}`);
    created = true;
    ok(step, `meetingID=${meetingID}`);

    // 2. join; the browser follows the redirect to /html5client/?sessionToken=...
    step = 'join';
    res = await get(apiUrl('join', { fullName: 'Join Path', meetingID, role: 'MODERATOR' }), {}, 'manual');
    const location = res.headers.get('location');
    if (res.status !== 302 || !location) fail(`HTTP ${res.status}, expected a redirect`);
    const clientUrl = new URL(location, base);
    const sessionToken = clientUrl.searchParams.get('sessionToken');
    if (!sessionToken) fail(`redirect without sessionToken: ${redact(clientUrl)}`);
    ok(step, `redirect to ${redact(clientUrl)}`);

    step = 'html5client';
    res = await get(clientUrl);
    await res.arrayBuffer();
    if (res.status !== 200) fail(`HTTP ${res.status}`);
    ok(step, `HTTP ${res.status}`);

    // 3. settings-loader (bigbluebutton-html5/imports/ui/components/settings-loader/component.tsx:78-85):
    // GET <graphqlApiUrl>/meetingStaticData with the x-session-token header; Hasura
    // authenticates it through its auth hook (akka-apps /userInfo).
    // bbb-web answers create and join before akka-apps has created the meeting and registered
    // the user (both arrive through redis); until then akka-apps' /userInfo does not know the
    // token and Hasura answers 400 (no x-hasura-role). A browser is slower than this script
    // (it loads the client first), so the request is repeated for a few seconds in that case.
    step = 'meetingStaticData';
    let body;
    let attempts = 0;
    const until = Date.now() + 10_000;
    for (;;) {
      attempts += 1;
      res = await get(new URL(`${index.graphqlApiUrl}/meetingStaticData`, base), { [SESSION_HEADER]: sessionToken });
      body = await res.text();
      if (res.status !== 400 || !body.includes('x-hasura-role') || Date.now() > until) break;
      await new Promise((r) => { setTimeout(r, 500); });
    }
    if (res.status !== 200) fail(`HTTP ${res.status} after ${attempts} attempt(s) ${body.slice(0, 300)}`);
    let meeting;
    try { meeting = JSON.parse(body)?.meeting?.[0]; } catch { /* checked below */ }
    if (!meeting?.clientSettings?.clientSettingsJson) fail(`no meeting or clientSettings in ${body.slice(0, 300)}`);
    ok(step, `HTTP 200 (attempt ${attempts}) meetingId=${meeting.meetingId ?? '?'} name=${JSON.stringify(meeting.name ?? '?')}`);
    const settings = meeting.clientSettings.clientSettingsJson;

    // 4. connection-manager (bigbluebutton-html5/imports/ui/components/connection-manager/component.tsx:228-289):
    // graphql-ws client on graphqlWebsocketUrl, connection_init with these headers.
    step = 'graphql-ws';
    const userId = await graphqlWs(index.graphqlWebsocketUrl, sessionToken);
    ok(step, `connection_ack, user_current userId=${userId}`);

    // 5. LiveKit signaling URL handed to the client
    // (bigbluebutton-html5/imports/ui/components/livekit/primary-room/component.tsx:197).
    step = 'livekit';
    const lkUrl = new URL(settings?.public?.media?.livekit?.url ?? `wss://${base.hostname}/livekit`);
    const lkHttp = new URL(lkUrl.href.replace(/^ws/, 'http').replace(/\/?$/, '/'));
    res = await get(lkHttp);
    const lkBody = (await res.text()).trim();
    if (res.status !== 200) fail(`GET ${lkHttp} HTTP ${res.status}`);
    // livekit-client first calls <url>/rtc/validate; without a token LiveKit answers 401.
    res = await get(new URL('rtc/validate', lkHttp));
    const vBody = (await res.text()).trim();
    if (res.status !== 401) fail(`GET ${lkHttp}rtc/validate HTTP ${res.status}, expected 401 from LiveKit: ${vBody.slice(0, 200)}`);
    ok(step, `url=${lkUrl} GET / -> 200 ${JSON.stringify(lkBody.slice(0, 20))}, rtc/validate without token -> 401`);
  } catch (e) {
    console.log(`STEP ${step}: FAIL ${redact(e instanceof StepError ? e.message : e?.cause?.message ?? e)}`);
    return 1;
  } finally {
    if (created) {
      try { await (await get(apiUrl('end', { meetingID }))).text(); } catch { /* best effort */ }
    }
  }
  return 0;
}

function graphqlWs(url, sessionToken) {
  return new Promise((resolve, reject) => {
    // The browser sends its cookies for the host with the upgrade request, among them bbb-web's
    // JSESSIONID from the join (Path=/): graphql-middleware forwards them to bbb-web's
    // checkGraphqlAuthorization, which accepts the session token only with that HTTP session
    // (bigbluebutton-web/.../ConnectionController.groovy, isSessionTokenValid).
    // `headers` is undici's extension of the WebSocket constructor (Node 24).
    const ws = new WebSocket(url, { protocols: ['graphql-transport-ws'], headers: cookies.size ? { cookie: cookieHeader() } : {} });
    const timer = setTimeout(() => { ws.close(); reject(new StepError(`no answer within ${timeoutMs / 1000}s`)); }, timeoutMs);
    const done = (fn, v) => { clearTimeout(timer); try { ws.close(); } catch { /* closed */ } fn(v); };
    ws.onopen = () => ws.send(JSON.stringify({
      type: 'connection_init',
      payload: {
        headers: {
          [WS_SESSION_HEADER]: sessionToken,
          'X-ClientSessionUUID': randomUUID(),
          'X-ClientType': 'HTML5',
          'X-ClientIsMobile': 'false',
        },
      },
    }));
    ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (process.env.JOIN_PATH_DEBUG) console.error('ws <', String(ev.data).slice(0, 300));
      if (msg.type === 'connection_ack') {
        // The client's first subscription, by name: before the user has joined, graphql-middleware
        // forwards only the operations in AllowedSubscriptionsForNotInMeetingUsers
        // (bbb-graphql-middleware/config/Config.go) and drops the others silently.
        ws.send(JSON.stringify({
          id: '1',
          type: 'subscribe',
          payload: { operationName: 'userCurrentSubscription', query: 'subscription userCurrentSubscription { user_current { userId name } }' },
        }));
      } else if (msg.type === 'next' && msg.id === '1') {
        const user = msg.payload?.data?.user_current?.[0];
        if (user?.userId) done(resolve, user.userId);
        else done(reject, new StepError(`unexpected data ${JSON.stringify(msg.payload).slice(0, 300)}`));
      } else if (msg.type === 'error') {
        done(reject, new StepError(`error ${JSON.stringify(msg.payload).slice(0, 300)}`));
      }
    };
    ws.onerror = (ev) => done(reject, new StepError(`websocket error ${ev?.message ?? ''}`));
    ws.onclose = (ev) => done(reject, new StepError(`closed code=${ev.code} reason=${ev.reason}`));
  });
}

process.exit(await run());
