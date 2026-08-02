import path from 'node:path';

/*
 * Keep file classification and explicit-override parsing in one installed module.
 * The gate and prompt hook make opposite sides of the same authorization decision,
 * so separate copies of either policy would eventually drift and reopen a bypass.
 */
export const NONCODE_EXTENSIONS = new Set([
  'md', 'mdx', 'markdown', 'txt', 'rst', 'adoc', 'org',
  'json', 'jsonc', 'json5', 'toml', 'yaml', 'yml', 'ini', 'cfg', 'conf',
  'properties', 'plist', 'lock', 'csv', 'tsv', 'log', 'svg', 'xml',
]);

export const NONCODE_BASENAMES = new Set([
  'license', 'notice', 'readme', 'changelog', 'authors', 'contributors',
  'codeowners', 'copying', 'version', 'todo', '.gitignore', '.gitattributes',
  '.gitmodules', '.editorconfig', '.prettierrc', '.npmrc', '.nvmrc',
  '.python-version', '.tool-versions',
]);

export function isValidSessionId(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(value);
}

export function isNonCode(absPath) {
  const basename = path.basename(absPath).toLowerCase();
  if (basename.startsWith('.env')) return true;
  if (NONCODE_BASENAMES.has(basename)) return true;

  const extension = path.extname(basename).slice(1);
  return NONCODE_EXTENSIONS.has(extension);
}

/*
 * A direct-edit override is an authorization grant, not a keyword signal. Reject
 * quoted/mentioned phrases and immediately negated imperatives so discussion of
 * the grant cannot create it. Negative-form directives are matched as complete
 * phrases, which keeps "don't delegate" valid while "don't skip codex" is guarded.
 */
const DIRECTIVE =
  /\b(edit it yourself|do it yourself|write it yourself|yourself this time|kendin yap(?!ma)\b|sen yap(?!ma)\b|sen d[üu]zenle|don'?t delegate|no codex|skip codex)\b/gi;
const GUARDED_PREFIX =
  /(?:\b(?:do not|don'?t|never|won'?t|shouldn'?t|not|saying|says|say|said|typing|typed|phrase|words|means|mean)(?:\s+(?:ever|even|just|really|actually|simply))?\s*|["'`“‘]\s*)$/i;
const CLAUSE_GUARD =
  /\b(?:do not|don'?t|never|won'?t|shouldn'?t|not|saying|says|say|said|typing|typed|phrase|words|means|mean)\b/i;

function isGuarded(prefix) {
  if (GUARDED_PREFIX.test(prefix)) return true;
  const clause = prefix.slice(Math.max(
    prefix.lastIndexOf('.'), prefix.lastIndexOf('!'), prefix.lastIndexOf('?'),
    prefix.lastIndexOf(';'), prefix.lastIndexOf('\n')
  ) + 1);
  if (CLAUSE_GUARD.test(clause)) return true;
  const openDoubleQuotes = (clause.match(/["“]/g) || []).length;
  const closeDoubleQuotes = (clause.match(/["”]/g) || []).length;
  const backticks = (clause.match(/`/g) || []).length;
  return openDoubleQuotes % 2 === 1 || closeDoubleQuotes % 2 === 1 || backticks % 2 === 1;
}

export function directiveOpensGate(prompt) {
  const text = String(prompt);
  DIRECTIVE.lastIndex = 0;

  for (const match of text.matchAll(DIRECTIVE)) {
    const prefix = text.slice(0, match.index);
    if (!isGuarded(prefix)) return true;
  }
  return false;
}
