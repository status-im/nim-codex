# Codex Decentralized Durability Engine

> The Codex project aims to create a decentralized durability engine that allows persisting data in p2p networks. In other words, it allows storing files and data with predictable durability guarantees for later retrieval.

> WARNING: This project is under active development and is considered pre-alpha.

[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)](#stability)
[![CI](https://github.com/codex-storage/nim-codex/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/codex-storage/nim-codex/actions/workflows/ci.yml?query=branch%3Amaster)
[![Docker](https://github.com/codex-storage/nim-codex/actions/workflows/docker.yml/badge.svg?branch=master)](https://github.com/codex-storage/nim-codex/actions/workflows/docker.yml?query=branch%3Amaster)
[![Codecov](https://codecov.io/gh/codex-storage/nim-codex/branch/master/graph/badge.svg?token=XFmCyPSNzW)](https://codecov.io/gh/codex-storage/nim-codex)
[![Discord](https://img.shields.io/discord/895609329053474826)](https://discord.gg/CaJTh24ddQ)
![Docker Pulls](https://img.shields.io/docker/pulls/codexstorage/nim-codex)


## Build and Run

For detailed instructions on preparing to build nim-codex see [*Build Codex*](https://docs.codex.storage/learn/build).

To build the project, clone it and run:

```bash
make update && make
```

The executable will be placed under the `build` directory under the project root.

Run the client with:

```bash
build/codex
```
## Configuration

It is possible to configure a Codex node in several ways:
 1. CLI options
 2. Environment variables
 3. Configuration file

The order of priority is the same as above: CLI options --> Environment variables --> Configuration file.

Please check [documentation](https://docs.codex.storage/learn/run#configuration) for more information.

## Guides

To get acquainted with Codex, consider:
* running the simple [Codex Two-Client Test](https://docs.codex.storage/learn/local-two-client-test) for a start, and;
* if you are feeling more adventurous, try [Running a Local Codex Network with Marketplace Support](https://docs.codex.storage/learn/local-marketplace) using a local blockchain as well.

## API

The client exposes a REST API that can be used to interact with the clients. Overview of the API can be found on [api.codex.storage](https://api.codex.storage).
