# NOTICE — Pollen

## Authorship

Copyright 2026 Bastien Mouget. Part of the
[Amalgame](https://github.com/amalgame-lang/Amalgame) ecosystem.
External contributions are paused at the ecosystem level; see the
main repo's `CONTRIBUTING.md` for the policy.

AI tools (Anthropic Claude) were used during development. Per the
project's authorship policy, AI is treated as a tool, not a
co-author at law.

## Wire-protocol reference

Pollen's UDP wire format (MESSAGE / ACK / SYNCHRONIZATION datagrams,
ACK retry, UUID dedup, optional AES-256-CBC encryption) is a direct
port of the Node.js reference implementation **TARMeule** by the
same author
([github.com/BastienMOUGET/TARMeule](https://github.com/BastienMOUGET/TARMeule)).

TARMeule remains the canonical wire reference for cross-language
interoperability: a Pollen v0.1 node and a TARMeule v1 Node.js
node on the same LAN must exchange MESSAGE+ACK successfully.

## Licence

Apache License 2.0. See `LICENSE` for the full text.
