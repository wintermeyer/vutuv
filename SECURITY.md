# Security Policy

vutuv is an open-source business network. We take the security of the project
and of the data on [vutuv.de](https://vutuv.de) seriously and appreciate the
responsible disclosure of vulnerabilities.

## Reporting a vulnerability

**Please do not report security issues through public GitHub issues, pull
requests, or discussions.** Use one of these private channels instead:

1. **GitHub private vulnerability reporting (preferred).** Open the
   [Security tab](https://github.com/wintermeyer/vutuv/security) of this
   repository and click **"Report a vulnerability"**. The report stays private
   until a fix is published.
2. **Email.** Write to sw@wintermeyer-consulting.de. Mention if you would like
   to encrypt the exchange and we will arrange a key.

Please include as much of the following as you can:

- The type of issue (for example XSS, CSRF, SQL injection, an authentication or
  authorization flaw, or information disclosure).
- The affected URL, endpoint, or source file and line.
- Step-by-step instructions to reproduce the issue.
- Any proof-of-concept code, requests, or screenshots.
- The potential impact and how an attacker might exploit it.

## What to expect

vutuv is maintained on a best-effort basis. We aim to:

- Acknowledge your report within five business days.
- Share an assessment and a rough timeline once we have triaged it.
- Keep you informed of the progress toward a fix.
- Credit you once the issue is resolved, unless you prefer to stay anonymous.

## Supported versions

vutuv is a continuously deployed application rather than a versioned library.
Only the current code on the `main` branch, which powers the live site at
vutuv.de, receives security fixes. The historical branches kept for reference
(`legacy-master` and `v1.1`) are not maintained and do not receive backports.

## Scope and safe harbor

The production deployment at **vutuv.de** and the code in this repository are in
scope. Please act in good faith: do not run automated scanners that degrade the
service, do not access, modify, or delete data that is not yours, and give us a
reasonable amount of time to address an issue before any public disclosure. We
will not pursue or support legal action against researchers who follow this
policy.
