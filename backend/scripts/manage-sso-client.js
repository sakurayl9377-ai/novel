#!/usr/bin/env node

import { closeDb, migrate } from '../src/db.js';
import {
  createSsoClient,
  listSsoClients,
  rotateSsoClientSecret,
  setSsoClientStatus,
  updateSsoClient,
} from '../src/sso.js';

const [command = '', ...rawArguments] = process.argv.slice(2);
const options = parseOptions(rawArguments);

try {
  migrate();
  let result;
  if (command === 'list') {
    result = { clients: listSsoClients() };
  } else if (command === 'create') {
    result = createSsoClient(clientInput(options, { requireIdentity: true }));
  } else if (command === 'update') {
    result = {
      client: updateSsoClient(requiredOption(options, 'id'), clientInput(options)),
    };
  } else if (command === 'rotate') {
    result = rotateSsoClientSecret(requiredOption(options, 'id'));
  } else if (command === 'enable' || command === 'disable') {
    result = {
      client: setSsoClientStatus(
        requiredOption(options, 'id'),
        command === 'enable' ? 'active' : 'disabled',
      ),
    };
  } else {
    throw new Error(usage());
  }
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} catch (error) {
  process.stderr.write(`sso_client_error=${String(error?.message || error)}\n`);
  process.exitCode = 1;
} finally {
  closeDb();
}

function clientInput(values, { requireIdentity = false } = {}) {
  const input = {};
  assign(input, 'clientId', option(values, 'id'));
  assign(input, 'name', option(values, 'name'));
  assign(input, 'scopes', option(values, 'scopes'));
  const redirectUris = values.get('redirect-uri');
  if (redirectUris?.length) input.redirectUris = redirectUris;
  assignNumber(input, 'maxDebitPerTransaction', option(values, 'max-debit'));
  assignNumber(input, 'dailyDebitLimit', option(values, 'daily-debit'));
  assignNumber(input, 'maxCreditPerTransaction', option(values, 'max-credit'));
  assignNumber(input, 'dailyCreditLimit', option(values, 'daily-credit'));
  if (requireIdentity) {
    input.clientId = requiredOption(values, 'id');
    input.name = requiredOption(values, 'name');
    if (!redirectUris?.length) throw new Error('--redirect-uri is required');
  } else {
    delete input.clientId;
  }
  return input;
}

function parseOptions(argumentsList) {
  const parsed = new Map();
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (!argument.startsWith('--')) throw new Error(`invalid argument: ${argument}`);
    const key = argument.slice(2);
    const value = argumentsList[index + 1];
    if (!key || value == null || value.startsWith('--')) {
      throw new Error(`missing value for --${key}`);
    }
    const existing = parsed.get(key) || [];
    existing.push(value);
    parsed.set(key, existing);
    index += 1;
  }
  return parsed;
}

function requiredOption(values, key) {
  const value = option(values, key);
  if (!value) throw new Error(`--${key} is required`);
  return value;
}

function option(values, key) {
  return values.get(key)?.at(-1);
}

function assign(target, key, value) {
  if (value != null) target[key] = value;
}

function assignNumber(target, key, value) {
  if (value != null) target[key] = Number(value);
}

function usage() {
  return [
    'usage:',
    '  npm run sso:client -- list',
    '  npm run sso:client -- create --id <id> --name <name> --redirect-uri <uri> [options]',
    '  npm run sso:client -- update --id <id> [options]',
    '  npm run sso:client -- rotate --id <id>',
    '  npm run sso:client -- enable|disable --id <id>',
    'options:',
    '  --redirect-uri <uri> (repeatable)',
    '  --scopes "profile:read wallet:read [wallet:debit] [wallet:credit]"',
    '    default: "profile:read wallet:read"',
    '  --max-debit <coins> --daily-debit <coins> (per user, HK day)',
    '  --max-credit <coins> --daily-credit <coins> (all users, HK day)',
  ].join('\n');
}
