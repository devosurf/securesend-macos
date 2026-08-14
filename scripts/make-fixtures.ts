/*
 * Regenerates Tests/SecureSendKitTests/Fixtures/envelopes.json.
 *
 * Every envelope in that file is sealed by packages/crypto itself, which is the
 * whole point: a Swift test that opens them is checking this app against the
 * implementation the browser runs, not against its own idea of the format. A
 * drift in either one shows up as a failed open rather than as two codebases
 * quietly agreeing on something wrong.
 *
 * It lives here and runs there, because the sealing side is in the other repo:
 *
 *     cp scripts/make-fixtures.ts ../securesend-app/.make-fixtures.ts
 *     (cd ../securesend-app && ./node_modules/.bin/tsx .make-fixtures.ts) \
 *       > Tests/SecureSendKitTests/Fixtures/envelopes.json
 *     rm ../securesend-app/.make-fixtures.ts
 *
 * The `expect` block is written by hand rather than derived from the parts, so a
 * bug that reshapes both sides at once still has something to fail against.
 */

import {
  type EnvelopeParts,
  sealEnvelope,
} from "./packages/crypto/src/envelope";

interface Case {
  expect: unknown;
  name: string;
  parts: EnvelopeParts;
  password?: string;
}

const bytesOf = (text: string) => new TextEncoder().encode(text);

const cases: Case[] = [
  {
    expect: { credentials: null, files: [], note: "hunter2" },
    name: "note-only",
    parts: { note: "hunter2" },
  },
  {
    expect: {
      credentials: null,
      files: [],
      note: 'smörgås 🔐 \n\ttabbed "quoted" \\ backslash',
    },
    name: "note-unicode",
    parts: { note: 'smörgås 🔐 \n\ttabbed "quoted" \\ backslash' },
  },
  {
    expect: {
      credentials: { password: "correct horse", username: "ada@example.com" },
      files: [],
      note: null,
    },
    name: "credentials-only",
    parts: {
      credentials: { password: "correct horse", username: "ada@example.com" },
    },
  },
  {
    expect: {
      credentials: { password: "s3cr3t", username: "root" },
      files: [],
      note: "the staging box",
    },
    name: "note-and-credentials",
    parts: {
      credentials: { password: "s3cr3t", username: "root" },
      note: "the staging box",
    },
  },
  {
    expect: {
      credentials: null,
      files: [
        {
          base64: btoa("first file body"),
          name: "first.txt",
          size: 15,
          type: "text/plain",
        },
        {
          base64: btoa("\x00\x01\x02\xfd\xfe\xff"),
          name: "second.bin",
          size: 6,
          type: "",
        },
      ],
      note: "two files",
    },
    name: "files",
    parts: {
      files: [
        {
          bytes: bytesOf("first file body"),
          name: "first.txt",
          type: "text/plain",
        },
        {
          bytes: new Uint8Array([0, 1, 2, 253, 254, 255]),
          name: "second.bin",
          type: "",
        },
      ],
      note: "two files",
    },
  },
  {
    expect: {
      credentials: null,
      files: [
        {
          base64: btoa("alone"),
          name: "solo.txt",
          size: 5,
          type: "text/plain",
        },
      ],
      note: null,
    },
    name: "files-only",
    parts: {
      files: [{ bytes: bytesOf("alone"), name: "solo.txt", type: "text/plain" }],
    },
  },
  {
    expect: { credentials: null, files: [], note: "behind a password" },
    name: "password-protected",
    parts: { note: "behind a password" },
    password: "открыть-sesame",
  },
];

const fixtures = await Promise.all(
  cases.map(async (item) => {
    const sealed = await sealEnvelope(item.parts, item.password);

    return {
      expect: item.expect,
      fragmentToken: sealed.fragmentToken,
      name: item.name,
      ...(item.password !== undefined && { password: item.password }),
      stored: sealed.stored,
    };
  })
);

process.stdout.write(`${JSON.stringify({ fixtures }, null, 2)}\n`);
