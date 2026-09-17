# Security

Report vulnerabilities through [GitHub security
advisories](https://github.com/Smart-Data-Ohio/smartfire/security/advisories/new).

## Trust model

Smartfire is self-hosted and single-tenant, so the administrator is the server operator,
with shell, network, and database access already. Anything requiring the administrator
role grants nothing they do not already have, and is not a vulnerability.

We do want reports of anything a **non-administrator** can reach, and of any credential or
network path held by the Smartfire process but not by the operator's own shell.

## Intentional behavior

Bot webhook URLs are unrestricted: an administrator can point one at any address,
including internal ones, because operators legitimately wire bots to their own services.
Link unfurling is different because any member can trigger it by pasting a URL, so it
validates destinations through `RestrictedHTTP::PrivateNetworkGuard`. The difference is who
picks the destination.
