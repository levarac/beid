#!/usr/bin/env node
// Test data only. Uses the public scalar-3 Parallax fixture key; reads no production key.
// B005 envelope bytes are copied verbatim from Barnard v0.8.0's independent vectors.
// Usage: node scripts/generate_venue_bundle_test_vector.mjs /path/to/parallax
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const parallax = process.argv[2];
assert(parallax, "pass the Parallax checkout path");
const referenceRef = "a5800d9061531dec7f2c990f8b386865233c2b8f";
// Spec-only commits may follow this ref; the signing implementation must be unchanged.
assert.equal(execFileSync("git", ["diff", referenceRef, "--", "protocol/reference/js"], {
  cwd: parallax, encoding: "utf8",
}), "");
const api = await import(pathToFileURL(path.resolve(parallax, "protocol/reference/js/index.ts")).href);
const { encodeCanonical } = await import(pathToFileURL(path.resolve(parallax, "protocol/reference/js/src/bytes.ts")).href);
const upstream = await readFile(path.join(root, "shared/src/commonTest/fixtures/vectors/upstream/barnard-b005-envelope-v2.txt"), "utf8");
const values = Object.fromEntries(upstream.split("\n").filter(line => line && !line.startsWith("#")).map(line => {
  const at = line.indexOf("=");
  return [line.slice(0, at), line.slice(at + 1)];
}));
const bytes = key => Buffer.from(values[key], "hex");
const hash = value => createHash("sha256").update(value).digest();
const hex = value => Buffer.from(value).toString("hex");
const eninSeconds = Number(values.v1_enin_seconds);
const validFrom = Number(values.v1_valid_from_enin) * eninSeconds;
const validUntil = (Number(values.v1_valid_through_enin) + 1) * eninSeconds - 1;
const authorityKey = Buffer.alloc(32);
authorityKey[31] = 3; // Public test scalar, already published in Parallax's canonical vector.
const receiptPublicKey = Buffer.from("02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5", "hex");
const keySet = bytes("event_key_set_bytes");
const signedDefinition = api.signEventDefinition({
  version: 1, eventId: bytes("event_id"), registrar: bytes("registrar"),
  anchorOperator: bytes("anchor_operator"), nonce: bytes("nonce"),
  keySetDigest: bytes("event_key_set_digest"), sequence: 1,
  previousDefinitionDigest: Buffer.alloc(32), receiptPublicKey,
  operatorId: api.operatorIdFromPublicKey(receiptPublicKey),
  submissionEndpoint: "https://operator.example/v1/observations", validFrom, validUntil,
  joinMode: 0, eventCodeHash: bytes("event_code_hash"),
}, keySet, authorityKey);
const definitionDigest = api.eventDefinitionDigest(signedDefinition);
const registration = {
  eventId: bytes("event_id"), registrar: bytes("registrar"), operator: bytes("anchor_operator"),
  keySetDigest: bytes("event_key_set_digest"), registeredAt: validFrom - 1000,
};
const record = {
  eventId: bytes("event_id"), sequence: 1, previousDefinitionDigest: Buffer.alloc(32),
  definitionDigest, validFrom, validUntil, anchoredAt: validFrom - 600,
};
const checked = api.verifyEventDefinition(signedDefinition, keySet, registration, record, { at: 1_800_000_000 });
assert.equal(hex(checked.definition.eventId), values.event_id);
assert.equal(hex(checked.definition.keySetDigest), values.event_key_set_digest);

const chainId = 11_155_111;
const eventRegistry = Buffer.from("1284a559ce2e4ba7551a87a4fb66f34dcf9b0170", "hex");
const definitionRegistry = Buffer.from("1f2eb14790f1108a3e54d8eb3f65b89ad08ec400", "hex");
const makeCase = (envelopeKey, containerKey) => {
  const envelope = bytes(envelopeKey);
  const bundle = encodeCanonical(new Map([
    [1, 1], [2, chainId], [3, eventRegistry], [4, definitionRegistry], [5, bytes("event_id")],
    [6, 1], [7, definitionDigest], [8, signedDefinition], [9, keySet], [10, [envelope]],
  ]));
  const digest = hash(Buffer.concat([Buffer.from("levarac:venue-bundle-digest:v1\0"), bundle]));
  const handoff = encodeCanonical(new Map([
    [1, 1], [2, bytes("event_id")], [3, chainId], [4, eventRegistry], [5, definitionRegistry], [6, digest],
  ]));
  return {
    signedEnvelopeHex: hex(envelope), sourceContainerHex: values[containerKey],
    bundleHex: hex(bundle), bundleDigestHex: hex(digest), handoffHex: hex(handoff),
    handoffLink: `https://handoff.example/#${handoff.toString("base64url")}`,
  };
};
const publicFields = object => Object.fromEntries(Object.entries(object).map(([key, value]) => [
  Buffer.isBuffer(value) ? `${key}Hex` : key, Buffer.isBuffer(value) ? hex(value) : value,
]));
const fixture = {
  vector: "beid-venue-current-lease-v1", testOnly: true,
  provenance: {
    barnardRef: "v0.8.0", barnardVectorSha256: hex(hash(Buffer.from(upstream))),
    parallaxReferenceRef: referenceRef,
    description: "B005 bytes copied verbatim; definition signed by Parallax reference with the public scalar-3 key. Chain records are test inputs, not live registration evidence.",
  },
  chainId, eventRegistryHex: hex(eventRegistry), eventDefinitionRegistryHex: hex(definitionRegistry),
  readerAddressHex: "d4852f8526a1555a1b2c34145f0ecda412a53c51",
  currentEnin: 6_000_000, currentEpochSeconds: 1_800_000_000,
  eninSeconds, signedValidFromEnin: Number(values.v1_valid_from_enin),
  signedValidThroughEnin: Number(values.v1_valid_through_enin),
  signedRelayExpiresAtEnin: Number(values.v1_relay_expires_at_enin),
  fullScheduleCoverage: "unproven: this single envelope does not cover the entire definition",
  signedEventDefinitionHex: hex(signedDefinition), eventKeySetHex: hex(keySet),
  registration: publicFields(registration), definitionRecord: publicFields(record),
  authorityDirect: makeCase("v1_envelope", "v1_container"),
  delegate: makeCase("v2_envelope", "v2_container"),
};
const output = path.join(root, "shared/src/commonTest/fixtures/vectors/positive/venue-current-lease-v1.json");
await writeFile(output, JSON.stringify(fixture, null, 2) + "\n");
console.log(JSON.stringify({ definitionVerifiedByParallax: true, copiedEnvelopeCases: 2, output }));
