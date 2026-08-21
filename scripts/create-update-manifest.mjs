import { createHash, createPrivateKey, createPublicKey, sign } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'

const [version, archivePath, privateKeyPath, outputPath, rolloutRaw = '10', mandatoryRaw = 'false'] = process.argv.slice(2)
if (!version || !archivePath || !privateKeyPath || !outputPath) {
  throw new Error('usage: create-update-manifest.mjs VERSION ARCHIVE PRIVATE_KEY OUTPUT [ROLLOUT] [MANDATORY]')
}

const archive = readFileSync(archivePath)
const sha256 = createHash('sha256').update(archive).digest('hex')
const privateKey = createPrivateKey(readFileSync(privateKeyPath))
const publicDER = createPublicKey(privateKey).export({ type: 'spki', format: 'der' })
const publicKeyBase64 = publicDER.subarray(-32).toString('base64')
const expectedPublicKey = 'kx2EJhi8RR4A+CTuoSs4Fx5f59+oicxN5z9wMPra3nc='
if (publicKeyBase64 !== expectedPublicKey) throw new Error('the private signing key does not match the public key embedded in the Mac client')

const message = `wanhe-macos-update-v1\n${version}\n${sha256}\n`
const signature = sign(null, Buffer.from(message), privateKey).toString('base64')
const rolloutPercentage = Math.max(0, Math.min(100, Math.round(Number(rolloutRaw) || 0)))
const mandatory = mandatoryRaw === 'true'
const filename = `wanhe-status-${version}.tar.gz`
const now = new Date().toISOString()
const manifest = {
  enabled: true,
  version,
  minimumVersion: mandatory ? version : '',
  mandatory,
  rolloutPercentage: mandatory ? 100 : rolloutPercentage,
  downloadPath: `/client/macos/releases/${filename}`,
  sha256,
  signature,
  releaseNotes: `Mac 状态栏客户端 ${version}`,
  publishedAt: now,
  updatedAt: now,
}
writeFileSync(outputPath, `${JSON.stringify(manifest, null, 2)}\n`)
process.stdout.write(`${JSON.stringify({ archivePath, outputPath, sha256, signature, publicKeyBase64 })}\n`)
