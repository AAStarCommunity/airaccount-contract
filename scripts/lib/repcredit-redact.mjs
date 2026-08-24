/**
 * RPC-URL redaction shared by both RepCredit evidence deploy scripts.
 *
 * viem embeds the full request URL in transport errors — `getUrl` in
 * viem/_esm/errors/utils.js is the identity function, so nothing is masked. An unhandled
 * RPC fault therefore prints whatever credential the operator put in REPCREDIT_RPC_URL.
 * Every string the scripts emit (stderr, evidence file, failure record) is funnelled
 * through the redactor built here.
 *
 * CC-51 post-review LOW-1: the previous implementation keyed its regex off
 * `new URL(url).origin`, and `origin` drops the userinfo section — so
 * `https://user:KEY@host/path` was masked only by the exact-string pass. The moment viem
 * rewrote the URL at all (adding the default `:443`, for instance) the credential leaked.
 * The host rule below therefore carries an optional `userinfo@` prefix, a host-agnostic
 * pass masks userinfo on any URL that reached the text by another route (nested cause,
 * proxy, ...), and the userinfo components of the configured URL are scrubbed as literal
 * secrets wherever they appear.
 */

export const RPC_PLACEHOLDER = "<redacted-rpc-url>";
export const CREDENTIAL_PLACEHOLDER = "<redacted-credential>";

const REGEX_META = /[.*+?^${}()|[\]\\]/g;
const escapeRegex = (value) => value.replace(REGEX_META, "\\$&");
// Short values are not masked as literals: a 4-char username would shred unrelated output.
const MIN_LITERAL_SECRET_LENGTH = 8;

function parse(url) {
  try {
    return new URL(url);
  } catch {
    return null;
  }
}

/**
 * Build a redactor bound to one RPC URL.
 *
 * @param {string | undefined} rpcUrl the configured endpoint, credentials and all
 * @returns {(text: string) => string}
 */
export function createRedactor(rpcUrl) {
  const target = typeof rpcUrl === "string" ? rpcUrl : "";
  const parsed = parse(target);
  // Match scheme://[userinfo@]hostname[:port]<rest>, so a rewritten URL (default port added,
  // path normalised, credentials still attached) is masked as a whole.
  const hostRule = parsed?.hostname
    ? new RegExp(`https?://(?:[^\\s"'/@]*@)?${escapeRegex(parsed.hostname)}(?::\\d+)?[^\\s"']*`, "gi")
    : null;
  // Username and password of the configured URL, masked as literals wherever they surface —
  // a provider that echoes the key back in a JSON body never passes through the URL rules.
  const literalSecrets = [parsed?.username ?? "", parsed?.password ?? ""]
    .map((value) => {
      try {
        return decodeURIComponent(value);
      } catch {
        return value;
      }
    })
    .concat([parsed?.username ?? "", parsed?.password ?? ""])
    .filter((value) => value.length >= MIN_LITERAL_SECRET_LENGTH)
    .sort((a, b) => b.length - a.length);

  return function redact(text) {
    let out = String(text);
    // 1. exact configured URL.
    if (target) out = out.split(target).join(RPC_PLACEHOLDER);
    // 2. same host under any rewrite, with or without userinfo.
    if (hostRule) out = out.replace(hostRule, RPC_PLACEHOLDER);
    // 3. userinfo on any other URL.
    out = out.replace(/(https?:\/\/)[^\s"'/@]+@/g, `$1${CREDENTIAL_PLACEHOLDER}@`);
    // 4. provider keys carried in a path segment (Alchemy/Infura style) on any other URL.
    out = out.replace(/(https?:\/\/[^\s"']+?\/v[23])\/[A-Za-z0-9_-]{8,}/g, `$1/${CREDENTIAL_PLACEHOLDER}`);
    // 5. provider keys carried in a query string.
    out = out.replace(/([?&](?:api[_-]?key|apikey|key|token|auth|secret)=)[^&\s"']+/gi, `$1${CREDENTIAL_PLACEHOLDER}`);
    // 6. the configured credential as a bare literal.
    for (const secret of literalSecrets) out = out.split(secret).join(CREDENTIAL_PLACEHOLDER);
    return out;
  };
}
