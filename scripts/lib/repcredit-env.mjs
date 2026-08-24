/**
 * Strict environment parsing for the RepCredit evidence deploy scripts.
 *
 * CC-51 focused review LOW: the previous scripts read their timeouts as
 * `Number(process.env.X ?? "") || undefined`, which turns every malformed value into
 * `undefined` — silently. `REPCREDIT_RECEIPT_TIMEOUT_MS=30s` then fell back to viem's 180 s
 * default while the operator believed they had set 30 s, and `=0` disabled the timeout
 * entirely. Both are fail-open. These parsers reject anything that is not a positive integer.
 */

/**
 * @param {string} name environment variable name
 * @returns {number | undefined} the parsed value, or undefined when unset/empty
 */
export function optionalPositiveInt(name, env = process.env) {
  const raw = env[name];
  if (raw === undefined || raw.trim() === "") return undefined;
  const text = raw.trim();
  // Deliberately not Number(): that accepts "1e3", " 12 ", "0x10" and NaN-producing junk alike.
  if (!/^[0-9]+$/.test(text)) {
    throw new Error(`${name} must be a positive integer number of milliseconds, got ${JSON.stringify(raw)}`);
  }
  const value = Number(text);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer number of milliseconds, got ${JSON.stringify(raw)}`);
  }
  return value;
}
