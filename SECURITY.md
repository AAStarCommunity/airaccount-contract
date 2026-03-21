# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| M6 (v0.15.x) | ✅ Current |
| M5 (v0.14.x) | ⚠️ Critical fixes only |
| M1–M4 | ❌ Deprecated |

## Reporting a Vulnerability

**Do NOT open a public GitHub issue for security vulnerabilities.**

### Responsible Disclosure Process

1. **Email**: Send findings to `security@aastar.io` (or create a private GitHub Security Advisory)
2. **Include**:
   - Contract(s) affected
   - Description of the vulnerability
   - Proof of concept (test case or transaction trace)
   - Estimated severity (Critical/High/Medium/Low)
3. **Response time**: We aim to respond within 48 hours and provide a fix timeline within 7 days for Critical/High findings

### What to Report

- Smart contract vulnerabilities (fund loss, unauthorized access, bypass of security controls)
- Logic errors in tier enforcement, guardian recovery, or session key validation
- Cross-chain replay attacks or signature malleability issues

### Known Accepted Risks

The following are known design trade-offs and are NOT considered vulnerabilities:

- **EIP-7702 private key permanence**: If an EOA private key is compromised, the attacker can reset the delegation. Users are advised to migrate to native AirAccountV7 for high-value accounts.
- **Guardian self-dealing after trust is established**: Once a guardian is set, they can participate in recovery. Users should only set trusted parties as guardians.
- **Tier enforcement depends on tier1Limit/tier2Limit being set**: If not configured, all transactions default to Tier 0 (no tier restriction).

## Bug Bounty

A formal bug bounty program is planned via Immunefi after the M7 professional audit completes.

**Proposed rewards** (subject to change after audit):
| Severity | Reward |
|----------|--------|
| Critical (drain any account) | $50,000 |
| High (bypass guardian threshold) | $10,000 |
| Medium (DoS, griefing) | $2,000 |
| Low (info disclosure) | $500 |

## Audit Reports

- [docs/2026-03-20-audit-report.md](docs/2026-03-20-audit-report.md) — Internal security review, M6
- [docs/M6-security-review.md](docs/M6-security-review.md) — M6 internal security review

External professional audit in progress (M7.6 — CodeHawks).
