// Test-only: `node --import <this file> <hook>` makes hooks/lib-config.mjs's `resolveConfig` throw
// on entry, by rewriting that module's source as it loads. It gives a test a throw inside config
// resolution without any seam in product code, and without a malformed-config input that
// hardening would later remove.
//
// If the source no longer holds `export function resolveConfig(...) {`, the load fails with an
// error naming this file, so the hook exits non-zero and the check that uses it goes red; it can
// never pass without the throw it exists to inject.
import { register } from "node:module";

const hooks = `
export async function load(url, context, nextLoad) {
  const result = await nextLoad(url, context);
  if (!url.endsWith("/hooks/lib-config.mjs")) return result;
  const source = String(result.source);
  const target = /export function resolveConfig\\(([^)]*)\\)\\s*\\{/;
  if (!target.test(source)) {
    throw new Error("tests/fixtures/resolve-config-throws.mjs: \`export function resolveConfig(...) {\` not found in " + url + " — the injection cannot be applied");
  }
  return {
    ...result,
    source: source.replace(target, (m) => m + ' throw new Error("injected by tests/fixtures/resolve-config-throws.mjs: resolveConfig throws on entry");'),
  };
}
`;

register("data:text/javascript," + encodeURIComponent(hooks));
