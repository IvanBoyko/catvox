const test = require('node:test');
const assert = require('node:assert/strict');

const {
  APP_CHECK_UNAUTHORIZED_CODE,
  runWithAppCheck,
  verifyAppCheckRequest,
} = require('../lib/appCheck.js');

function makeRequest(token) {
  return {
    header(name) {
      assert.equal(name, 'X-Firebase-AppCheck');
      return token;
    },
  };
}

function makeResponse() {
  const calls = {
    statusCode: null,
    body: null,
  };

  return {
    calls,
    res: {
      status(code) {
        calls.statusCode = code;
        return {
          json(body) {
            calls.body = body;
          },
        };
      },
    },
  };
}

test('verifyAppCheckRequest rejects a missing App Check token', async () => {
  const { calls, res } = makeResponse();

  const allowed = await verifyAppCheckRequest(
    makeRequest(undefined),
    res,
    async () => {
      throw new Error('verifier should not run');
    }
  );

  assert.equal(allowed, false);
  assert.equal(calls.statusCode, 401);
  assert.deepEqual(calls.body, {
    code: APP_CHECK_UNAUTHORIZED_CODE,
    message: 'App Check token is missing or invalid.',
  });
});

test('verifyAppCheckRequest rejects an invalid App Check token', async () => {
  const { calls, res } = makeResponse();

  const allowed = await verifyAppCheckRequest(
    makeRequest('invalid-token'),
    res,
    async () => {
      throw new Error('invalid token');
    }
  );

  assert.equal(allowed, false);
  assert.equal(calls.statusCode, 401);
  assert.equal(calls.body.code, APP_CHECK_UNAUTHORIZED_CODE);
});

test('verifyAppCheckRequest accepts a valid App Check token', async () => {
  const { calls, res } = makeResponse();
  let verifiedToken = null;

  const allowed = await verifyAppCheckRequest(
    makeRequest('valid-token'),
    res,
    async (token) => {
      verifiedToken = token;
    }
  );

  assert.equal(allowed, true);
  assert.equal(verifiedToken, 'valid-token');
  assert.equal(calls.statusCode, null);
});

test('runWithAppCheck does not call handler when verification fails', async () => {
  const { res } = makeResponse();
  let handlerCalls = 0;

  await runWithAppCheck(
    makeRequest('invalid-token'),
    res,
    () => {
      handlerCalls += 1;
    },
    async () => {
      throw new Error('invalid token');
    }
  );

  assert.equal(handlerCalls, 0);
});

test('runWithAppCheck calls handler after valid verification', async () => {
  const { res } = makeResponse();
  let handlerCalls = 0;

  await runWithAppCheck(
    makeRequest('valid-token'),
    res,
    () => {
      handlerCalls += 1;
    },
    async () => undefined
  );

  assert.equal(handlerCalls, 1);
});
