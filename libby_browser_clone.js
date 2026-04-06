#!/usr/bin/env node
'use strict';

const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const DEFAULT_BROWSER_CANDIDATES = [
  process.env.LIBBY_BROWSER_BINARY,
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
].filter(Boolean);

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function parseArgs(argv) {
  const args = {
    sourceToken: process.env.LIBBY_SOURCE_TOKEN || '',
    browserBinary: process.env.LIBBY_BROWSER_BINARY || '',
    timeoutMs: Number(process.env.LIBBY_TIMEOUT_MS || 30000),
    keepBrowser: process.env.LIBBY_KEEP_BROWSER === '1',
    outputPath: process.env.LIBBY_OUTPUT_PATH || '',
    verbose: process.env.LIBBY_VERBOSE === '1',
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];
    if (arg === '--source-token' && next) {
      args.sourceToken = next;
      i += 1;
    } else if (arg === '--browser' && next) {
      args.browserBinary = next;
      i += 1;
    } else if (arg === '--timeout-ms' && next) {
      args.timeoutMs = Number(next);
      i += 1;
    } else if (arg === '--output' && next) {
      args.outputPath = next;
      i += 1;
    } else if (arg === '--keep-browser') {
      args.keepBrowser = true;
    } else if (arg === '--verbose') {
      args.verbose = true;
    }
  }
  return args;
}

function pickBrowserBinary(preferred) {
  const candidates = preferred ? [preferred].concat(DEFAULT_BROWSER_CANDIDATES) : DEFAULT_BROWSER_CANDIDATES;
  for (const candidate of candidates) {
    if (candidate && fs.existsSync(candidate)) {
      return candidate;
    }
  }
  throw new Error('Could not find a supported browser binary. Set LIBBY_BROWSER_BINARY or pass --browser.');
}

function getFreePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      const port = address && address.port;
      server.close(err => {
        if (err) {
          reject(err);
          return;
        }
        resolve(port);
      });
    });
  });
}

async function fetchJson(url, options) {
  const response = await fetch(url, options);
  if (!response.ok) {
    throw new Error(`${options && options.method ? options.method : 'GET'} ${url} failed with ${response.status}`);
  }
  return response.json();
}

async function waitForDevTools(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const version = await fetchJson(`http://127.0.0.1:${port}/json/version`);
      if (version.webSocketDebuggerUrl) {
        return version;
      }
    } catch (error) {
      lastError = error;
    }
    await sleep(250);
  }
  throw lastError || new Error('Timed out waiting for browser DevTools.');
}

async function createTarget(port, url) {
  return fetchJson(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`, {
    method: 'PUT',
  });
}

function decodeJwtPayload(token) {
  if (!token || typeof token !== 'string') {
    return null;
  }
  const payload = token.split('.')[1];
  if (!payload) {
    return null;
  }
  const normalized = payload.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  return JSON.parse(Buffer.from(padded, 'base64').toString('utf8'));
}

function pickFirstEpubLoan(syncState) {
  const loans = syncState && Array.isArray(syncState.loans) ? syncState.loans : [];
  for (const loan of loans) {
    const formats = Array.isArray(loan.formats) ? loan.formats : [];
    const otherFormats = Array.isArray(loan.otherFormats) ? loan.otherFormats : [];
    const hasEpub = formats.some(format => format && format.id === 'ebook-epub-adobe')
      || otherFormats.some(format => format && format.id === 'ebook-epub-adobe');
    if (hasEpub && loan.cardId && loan.id) {
      return {
        loanId: loan.id,
        cardId: loan.cardId,
        title: loan.title,
      };
    }
  }
  return null;
}

class CDPPage {
  constructor(webSocketDebuggerUrl, verbose) {
    this.webSocketDebuggerUrl = webSocketDebuggerUrl;
    this.verbose = verbose;
    this.messageId = 0;
    this.pending = new Map();
    this.requests = [];
  }

  async init() {
    this.socket = new WebSocket(this.webSocketDebuggerUrl);
    this.socket.onmessage = async event => {
      const message = JSON.parse(event.data);
      if (message.id) {
        const pending = this.pending.get(message.id);
        if (pending) {
          this.pending.delete(message.id);
          if (message.error) {
            pending.reject(new Error(message.error.message || JSON.stringify(message.error)));
          } else {
            pending.resolve(message.result);
          }
        }
        return;
      }
      this.handleEvent(message).catch(error => {
        if (this.verbose) {
          console.error('[CDP event error]', error);
        }
      });
    };
    await new Promise((resolve, reject) => {
      this.socket.onopen = resolve;
      this.socket.onerror = reject;
    });
    await this.send('Page.enable');
    await this.send('Runtime.enable');
    await this.send('Network.enable', { maxPostDataSize: 65536 });
  }

  async handleEvent(message) {
    const params = message.params || {};
    if (message.method === 'Network.requestWillBeSent' && params.request && params.request.url.includes('sentry.libbyapp.com')) {
      this.requests.push({
        event: 'request',
        requestId: params.requestId,
        method: params.request.method,
        url: params.request.url,
        headers: params.request.headers,
        postData: params.request.postData,
      });
      return;
    }
    if (message.method === 'Network.requestWillBeSentExtraInfo') {
      const entry = this.requests.find(item => item.event === 'request' && item.requestId === params.requestId);
      if (entry) {
        entry.extraHeaders = params.headers;
      }
      return;
    }
    if (message.method === 'Network.responseReceived' && params.response && params.response.url.includes('sentry.libbyapp.com')) {
      this.requests.push({
        event: 'response',
        requestId: params.requestId,
        url: params.response.url,
        status: params.response.status,
        protocol: params.response.protocol,
      });
      return;
    }
    if (message.method === 'Network.loadingFinished') {
      const entry = this.requests.find(item => item.event === 'request' && item.requestId === params.requestId);
      if (entry) {
        try {
          const body = await this.send('Network.getResponseBody', { requestId: params.requestId });
          entry.responseBody = body.body;
        } catch (_error) {
          // Ignore missing bodies for preflight or redirects.
        }
      }
    }
  }

  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++this.messageId;
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  async navigate(url) {
    await this.send('Page.navigate', { url });
  }

  async evaluate(expression, awaitPromise = true) {
    const result = await this.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise,
    });
    return result.result ? result.result.value : undefined;
  }

  async waitForLibbyApp(timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const state = await this.evaluate(`(() => ({
        href: location.href,
        ready: !!(window.APP && APP.sentry && APP.bank),
        title: document.title
      }))()`);
      if (state && state.ready) {
        return state;
      }
      await sleep(250);
    }
    throw new Error('Timed out waiting for Libby app bootstrap.');
  }

  async callSentry(method, path, payload, timeoutMs = 15000) {
    const expression = `(() => new Promise(resolve => {
      const timeout = setTimeout(() => resolve({
        ok: false,
        timeout: true,
        identity: APP && APP.sentry ? APP.sentry.identity : null,
        chip: APP && APP.sentry ? APP.sentry.chip : null
      }), ${timeoutMs});
      APP.sentry.${method}(${JSON.stringify(path)}, ${JSON.stringify(payload)},
        result => {
          clearTimeout(timeout);
          resolve({
            ok: true,
            result,
            identity: APP.sentry.identity,
            chip: APP.sentry.chip
          });
        },
        error => {
          clearTimeout(timeout);
          resolve({
            ok: false,
            error,
            identity: APP.sentry.identity,
            chip: APP.sentry.chip
          });
        }
      );
    }))()`;
    return this.evaluate(expression, true);
  }

  async getRuntimeState() {
    return this.evaluate(`(() => ({
      href: location.href,
      title: document.title,
      identity: APP && APP.sentry ? APP.sentry.identity : null,
      chip: APP && APP.sentry ? APP.sentry.chip : null
    }))()`);
  }
}

function buildSourceHeaders(sourceToken) {
  return {
    Accept: 'application/json',
    'Accept-Encoding': 'gzip',
    'Accept-Language': 'en-US',
    Authorization: `Bearer ${sourceToken}`,
    'Content-Type': 'application/json',
    Origin: 'https://libbyapp.com',
    Referer: '',
    'Sec-Fetch-Dest': 'empty',
    'Sec-Fetch-Mode': 'cors',
    'Sec-Fetch-Site': 'same-site',
    'Sec-GPC': '1',
    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36',
    'sec-ch-ua': '"Chromium";v="146", "Not-A.Brand";v="24", "Brave";v="146"',
    'sec-ch-ua-mobile': '?0',
    'sec-ch-ua-platform': '"macOS"',
  };
}

async function redeemCodeExternally(sourceToken, code) {
  const response = await fetch('https://sentry.libbyapp.com/chip/clone/code', {
    method: 'POST',
    headers: buildSourceHeaders(sourceToken),
    body: JSON.stringify({ code, role: 'primary' }),
  });
  const body = await response.json();
  return {
    status: response.status,
    body,
  };
}

async function pollForBlessing(page, code, expiryEpochSeconds) {
  const deadline = Math.max(Date.now() + 5000, Number(expiryEpochSeconds || 0) * 1000);
  let currentCode = code;
  while (Date.now() < deadline) {
    const response = await page.callSentry('get', 'chip/clone/code', {
      code: currentCode,
      role: 'pointer',
    });
    if (!response.ok) {
      throw new Error(`Blessing poll failed: ${JSON.stringify(response.error || response)}`);
    }
    if (response.result && response.result.result === 'fulfilled' && response.result.blessing) {
      return response;
    }
    if (response.result && response.result.code) {
      currentCode = response.result.code;
    }
    await sleep(1000);
  }
  throw new Error('Timed out waiting for recovery blessing.');
}

async function killBrowser(child) {
  if (!child || child.killed) {
    return;
  }
  child.kill('SIGTERM');
  await sleep(1000);
  if (!child.killed) {
    child.kill('SIGKILL');
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.sourceToken) {
    throw new Error('Missing source token. Set LIBBY_SOURCE_TOKEN or pass --source-token.');
  }

  const browserBinary = pickBrowserBinary(args.browserBinary);
  const port = await getFreePort();
  const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), 'libby-browser-clone-'));
  const browserArgs = [
    `--user-data-dir=${profileDir}`,
    `--remote-debugging-port=${port}`,
    '--no-first-run',
    '--no-default-browser-check',
    'about:blank',
  ];

  const browser = spawn(browserBinary, browserArgs, {
    stdio: 'ignore',
  });

  let cleanedUp = false;
  async function cleanup() {
    if (cleanedUp) {
      return;
    }
    cleanedUp = true;
    if (!args.keepBrowser) {
      await killBrowser(browser);
      fs.rmSync(profileDir, { recursive: true, force: true });
    }
  }

  process.on('SIGINT', () => {
    cleanup().finally(() => process.exit(130));
  });
  process.on('SIGTERM', () => {
    cleanup().finally(() => process.exit(143));
  });

  try {
    await waitForDevTools(port, args.timeoutMs);
    const target = await createTarget(port, 'https://libbyapp.com/');
    const page = new CDPPage(target.webSocketDebuggerUrl, args.verbose);
    await page.init();
    await page.navigate('https://libbyapp.com/');
    await page.waitForLibbyApp(args.timeoutMs);

    const codeResponse = await page.callSentry('get', 'chip/clone/code', { role: 'pointer' });
    if (!codeResponse.ok || !codeResponse.result || !codeResponse.result.code) {
      throw new Error(`Failed to generate pointer code: ${JSON.stringify(codeResponse)}`);
    }

    const redeemResponse = await redeemCodeExternally(args.sourceToken, codeResponse.result.code);
    if (redeemResponse.status !== 200 || !redeemResponse.body || redeemResponse.body.result !== 'blessed') {
      throw new Error(`Code redeem failed: ${JSON.stringify(redeemResponse)}`);
    }

    const blessingResponse = await pollForBlessing(page, codeResponse.result.code, codeResponse.result.expiry);
    const cloneResponse = await page.callSentry('post', 'chip/clone', {
      blessing: blessingResponse.result.blessing,
    });
    if (!cloneResponse.ok || !cloneResponse.result || cloneResponse.result.result !== 'cloned') {
      throw new Error(`Clone failed: ${JSON.stringify(cloneResponse)}`);
    }

    const syncResponse = await page.callSentry('get', 'chip/sync', {});
    if (!syncResponse.ok || !syncResponse.result || syncResponse.result.result !== 'synchronized') {
      throw new Error(`Post-clone sync failed: ${JSON.stringify(syncResponse)}`);
    }

    const epubLoan = pickFirstEpubLoan(syncResponse.result);
    let fulfillResponse = null;
    if (epubLoan) {
      fulfillResponse = await page.callSentry(
        'get',
        `card/${epubLoan.cardId}/loan/${epubLoan.loanId}/fulfill/ebook-epub-adobe`,
        {}
      );
      if (!fulfillResponse.ok || !fulfillResponse.result || !fulfillResponse.result.fulfill || !fulfillResponse.result.fulfill.href) {
        throw new Error(`Post-clone EPUB fulfill failed: ${JSON.stringify(fulfillResponse)}`);
      }
    }

    const runtimeState = await page.getRuntimeState();
    const result = {
      success: true,
      code: codeResponse.result.code,
      cloneResult: cloneResponse.result,
      targetIdentityToken: runtimeState.identity,
      targetChip: runtimeState.chip,
      targetIdentityPayload: decodeJwtPayload(runtimeState.identity),
      syncState: syncResponse.result,
      epubFulfill: fulfillResponse ? {
        loanId: epubLoan.loanId,
        cardId: epubLoan.cardId,
        title: epubLoan.title,
        result: fulfillResponse.result,
      } : null,
    };

    const output = JSON.stringify(result, null, 2);
    if (args.outputPath) {
      fs.writeFileSync(args.outputPath, output);
    }
    console.log(output);
    await cleanup();
  } catch (error) {
    await cleanup();
    throw error;
  }
}

main().catch(error => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
