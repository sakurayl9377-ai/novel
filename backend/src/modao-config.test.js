import assert from 'node:assert/strict';
import test from 'node:test';

test('Modao SSO ticket TTL defaults to 600 seconds and stays bounded', async () => {
  const original = process.env.MODAO_SSO_TTL_SECONDS;
  try {
    delete process.env.MODAO_SSO_TTL_SECONDS;
    assert.equal((await loadConfig('default')).modaoSsoTtlSeconds, 600);

    process.env.MODAO_SSO_TTL_SECONDS = '900';
    assert.equal((await loadConfig('configured-max')).modaoSsoTtlSeconds, 900);

    process.env.MODAO_SSO_TTL_SECONDS = '901';
    assert.equal((await loadConfig('capped')).modaoSsoTtlSeconds, 900);

    process.env.MODAO_SSO_TTL_SECONDS = '1';
    assert.equal((await loadConfig('minimum')).modaoSsoTtlSeconds, 60);
  } finally {
    if (original === undefined) {
      delete process.env.MODAO_SSO_TTL_SECONDS;
    } else {
      process.env.MODAO_SSO_TTL_SECONDS = original;
    }
  }
});

async function loadConfig(caseName) {
  const module = await import(`./config.js?modao-sso-ttl=${caseName}`);
  return module.config;
}
