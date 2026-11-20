# Security policy

If you find a vulnerability in JoobQ, please report it to us privately rather than in a public issue or pull request.

## Reporting a vulnerability

Write to **support@joobq.io** with the subject `Security`. Please do not open a public issue, pull request or
discussion for a vulnerability, and do not post details anywhere until we have fixed it or the disclosure date below has
passed. Include, as far as you can:

- what is affected and its version or commit;
- the steps to reproduce it, or a proof of concept;
- what an attacker could do with it;
- how to reach you, and whether you want to be named when the fix is published.

Send no more personal data or secrets than are needed to show the problem. Never put a live credential in a report;
describe where it is and we will rotate it.

## What to expect

- We acknowledge your report within **3 business days**.
- We tell you whether we accept it, and our assessment of severity, within **10 business days**.
- We aim to fix confirmed issues within **90 days**, sooner for critical ones, and keep you updated about once a
  fortnight until then.
- We publish an advisory and release notes when a fix ships, and credit you if you want it. We do not currently run a
  bug bounty.
- Please give us the 90 days, or until the fix is released if that is earlier, before you disclose. If we need longer we
  will say why and agree a date with you; if a vulnerability is being exploited we may shorten it.

## Supported versions

Only the latest release receives security fixes; fixes ship in new releases only, and are announced with their release
in the [changelog](CHANGELOG.md). Please check a report against the latest release and the `master` branch before
sending it.

JoobQUI, the console built on JoobQ, and its hosted portal are covered by their own
[Acceptable Use Policy](https://www.joobq.io/acceptable-use).
