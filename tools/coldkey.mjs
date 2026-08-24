#!/usr/bin/env node
// Derive the substrate coldkey an H160 controls on Bittensor: blake2_256("evm:" ‖ address).
//
// This cannot be computed on chain 964, because that chain does not provide the
// blake2f precompile: address 0x09 answers the EIP-152 test vector with an
// elliptic-curve error, while sha256 at 0x02 works normally (probed on a Finney
// fork at block 8901111). The hash is NOT the obstacle — "evm:" + 20 bytes is a
// single 128-byte block, so a working blake2f would derive it in one staticcall
// (test/Blake2Coldkey.t.sol does exactly that in 5,594 gas on a standard EVM).
// So AlphaVault takes its coldkey as a
// constructor argument, and a wrong one is caught by NO Solidity assertion: the
// vault deploys cleanly, then every purchase reverts ColdkeyMismatch at FIRST USE,
// because a successful addStake did not raise the stake of the coldkey it was told
// it owns. Fail-closed, but far too late. Hence this check at deploy time.
//
//   node tools/coldkey.mjs 0xVaultAddress [0xExpectedColdkey]
//
// With two arguments it exits non-zero on a mismatch, so CI can gate on it.
//
// BLAKE2b-256 is implemented here rather than pulled from @polkadot/util-crypto so
// that a Solidity repo needs no node_modules to run its own deploy preflight. Note
// blake2b-256 is NOT a truncation of blake2b-512 (the digest length is mixed into
// the initial state), so node's built-in 'blake2b512' cannot substitute. Verified
// against a live pair read off a Finney fork — see the self-test below.

const MASK = (1n << 64n) - 1n
const IV = [
  0x6a09e667f3bcc908n, 0xbb67ae8584caa73bn, 0x3c6ef372fe94f82bn, 0xa54ff53a5f1d36f1n,
  0x510e527fade682d1n, 0x9b05688c2b3e6c1fn, 0x1f83d9abfb41bd6bn, 0x5be0cd19137e2179n,
]
const SIGMA = [
  [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],   [14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3],
  [11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4],   [7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8],
  [9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13],   [2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9],
  [12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11],   [13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10],
  [6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5],   [10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0],
  [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],   [14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3],
]
const rotr = (x, n) => ((x >> n) | (x << (64n - n))) & MASK

function compress(h, block, t, last) {
  const v = [...h, ...IV]
  v[12] ^= t & MASK
  v[13] ^= (t >> 64n) & MASK
  if (last) v[14] ^= MASK
  const m = []
  for (let i = 0; i < 16; i++) {
    let x = 0n
    for (let j = 7; j >= 0; j--) x = (x << 8n) | BigInt(block[i * 8 + j]) // little-endian
    m.push(x)
  }
  const G = (a, b, c, d, x, y) => {
    v[a] = (v[a] + v[b] + x) & MASK; v[d] = rotr(v[d] ^ v[a], 32n)
    v[c] = (v[c] + v[d]) & MASK;     v[b] = rotr(v[b] ^ v[c], 24n)
    v[a] = (v[a] + v[b] + y) & MASK; v[d] = rotr(v[d] ^ v[a], 16n)
    v[c] = (v[c] + v[d]) & MASK;     v[b] = rotr(v[b] ^ v[c], 63n)
  }
  for (let r = 0; r < 12; r++) {
    const s = SIGMA[r]
    G(0, 4, 8, 12, m[s[0]], m[s[1]]);  G(1, 5, 9, 13, m[s[2]], m[s[3]])
    G(2, 6, 10, 14, m[s[4]], m[s[5]]); G(3, 7, 11, 15, m[s[6]], m[s[7]])
    G(0, 5, 10, 15, m[s[8]], m[s[9]]); G(1, 6, 11, 12, m[s[10]], m[s[11]])
    G(2, 7, 8, 13, m[s[12]], m[s[13]]); G(3, 4, 9, 14, m[s[14]], m[s[15]])
  }
  for (let i = 0; i < 8; i++) h[i] ^= v[i] ^ v[i + 8]
}

function blake2b256(input) {
  const h = [...IV]
  h[0] ^= 0x01010020n // 0x01010000 ^ (keylen<<8) ^ outlen, keylen=0 outlen=32
  const blocks = Math.max(1, Math.ceil(input.length / 128))
  for (let i = 0; i < blocks; i++) {
    const chunk = new Uint8Array(128)
    chunk.set(input.subarray(i * 128, Math.min((i + 1) * 128, input.length)))
    const last = i === blocks - 1
    const counted = last ? input.length : (i + 1) * 128
    compress(h, chunk, BigInt(counted), last)
  }
  let out = ''
  for (const word of h) {
    for (let b = 0; b < 8; b++) out += Number((word >> BigInt(b * 8)) & 0xffn).toString(16).padStart(2, '0')
  }
  return '0x' + out.slice(0, 64)
}

export function coldkeyFor(address) {
  const addr = address.replace(/^0x/, '')
  const bytes = new Uint8Array(4 + 20)
  bytes.set([0x65, 0x76, 0x6d, 0x3a]) // "evm:"
  for (let i = 0; i < 20; i++) bytes[4 + i] = parseInt(addr.substr(i * 2, 2), 16)
  return blake2b256(bytes)
}

// Self-test against a pair read off a live Finney fork. If this fails the hash is
// wrong and every number it prints is worthless, so refuse to print anything.
const SELF_TEST = {
  address: '0x0000000000000000000000000000000000009980',
  coldkey: '0x759e4040f4191fd888ad3869de79d3467376d4c9d37405f7e05d961fe9bc1109',
}
if (coldkeyFor(SELF_TEST.address) !== SELF_TEST.coldkey) {
  console.error('FATAL: blake2b-256 self-test failed; refusing to derive anything')
  console.error('  expected', SELF_TEST.coldkey)
  console.error('  got     ', coldkeyFor(SELF_TEST.address))
  process.exit(3)
}

const [addr, expected] = process.argv.slice(2)
if (!addr) {
  console.log('self-test OK (blake2b-256 matches a live fork-derived pair)')
  console.log('usage: node tools/coldkey.mjs 0xVaultAddress [0xExpectedColdkey]')
  process.exit(0)
}
if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) {
  console.error('not an address:', addr); process.exit(2)
}
const coldkey = coldkeyFor(addr)
console.log(`address  ${addr}`)
console.log(`coldkey  ${coldkey}`)
if (expected) {
  const match = expected.toLowerCase() === coldkey.toLowerCase()
  console.log(`expected ${expected}`)
  console.log(match ? 'MATCH' : 'MISMATCH — the vault will revert ColdkeyMismatch on first use')
  process.exit(match ? 0 : 1)
}
