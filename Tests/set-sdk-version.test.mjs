import assert from 'node:assert/strict';
import test from 'node:test';

import { replaceSdkVersion } from '../set-sdk-version.mjs';

test('replaces a formatted SDK version declaration', () => {
  assert.equal(
    replaceSdkVersion('internal let SDK_VERSION = "0.1.10"\n', '0.1.11'),
    'internal let SDK_VERSION = "0.1.11"\n',
  );
});

test('replaces a compact SDK version declaration', () => {
  assert.equal(
    replaceSdkVersion('internal let SDK_VERSION="0.1.10"\n', '0.1.11'),
    'internal let SDK_VERSION = "0.1.11"\n',
  );
});
