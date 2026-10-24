import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

// Dependencies live outside the app; no packages or networking are used by TruDepth.
const fixtures = path.resolve(process.argv[2] ?? '/private/tmp/TruDepth-fixtures');
const modules = path.resolve(process.argv[3] ?? '/private/tmp/TruDepth-validation/node_modules');
const require = createRequire(import.meta.url);
const validator = require(path.join(modules, 'gltf-validator'));
const { PLYLoader } = await import(pathToFileURL(path.join(modules, 'three/examples/jsm/loaders/PLYLoader.js')));
const { OBJLoader } = await import(pathToFileURL(path.join(modules, 'three/examples/jsm/loaders/OBJLoader.js')));
const { Box3, Vector3 } = await import(pathToFileURL(path.join(modules, 'three/build/three.module.js')));

for (const name of ['textured', 'roundtrip']) {
  const result = await validator.validateBytes(new Uint8Array(fs.readFileSync(path.join(fixtures, `${name}.glb`))), { uri: `${name}.glb` });
  assert.equal(result.issues.numErrors, 0, JSON.stringify(result.issues));
  assert.equal(result.issues.numWarnings, 0, JSON.stringify(result.issues));
  console.log(`${name}.glb: Khronos validator passed (0 errors, 0 warnings)`);
}

const bytes = fs.readFileSync(path.join(fixtures, 'depth.ply'));
const cloud = new PLYLoader().parse(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
assert.equal(cloud.getAttribute('position').count, 3);
assert.deepEqual(Array.from(cloud.getAttribute('position').array), [0, 0, -1, 0, -1, -1, 1, -1, -1]);
const color = cloud.getAttribute('color');
assert.deepEqual(Array.from({ length: color.count }, (_, i) => [color.getX(i), color.getY(i), color.getZ(i)]).flat(), [1, 0, 0, 0, 0, 1, 1, 1, 1]);
console.log('depth.ply: Three.js verified calibrated positions, confidence filtering, colors and meter scale');

const object = new OBJLoader().parse(fs.readFileSync(path.join(fixtures, 'model.obj'), 'utf8'));
const size = new Box3().setFromObject(object).getSize(new Vector3());
assert.deepEqual(size.toArray(), [1, 1, 0]);
assert.equal(object.children.length, 2);
for (const child of object.children) {
  assert.equal(child.geometry.getAttribute('normal').count, 3);
  assert.equal(child.geometry.getAttribute('uv').count, 3);
}
const mtl = fs.readFileSync(path.join(fixtures, 'model.mtl'), 'utf8');
assert.equal((mtl.match(/^newmtl /gm) ?? []).length, 2);
for (const line of mtl.split('\n')) {
  if (/^\s*map_/.test(line)) assert.ok(fs.existsSync(path.join(fixtures, line.trim().split(/\s+/).at(-1))));
}
console.log('model.obj: Three.js verified scale, two meshes, normals, UVs; MTL textures resolve');
