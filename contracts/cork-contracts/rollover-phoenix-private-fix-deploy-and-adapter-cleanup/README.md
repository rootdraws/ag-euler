# rollover-phoenix-private

## Setup

Install [mise](https://mise.jdx.dev/) to manage tool versions, then run:

```sh
mise install
```

Install Foundry dependencies:

```sh
forge install
```

## Build

To build & compile all contracts for testing purposes run:

```sh
forge build
```

### Deployment Build

For production you need to use the optimized build with IR compilation turned on by setting the `FOUNDRY_PROFILE` environment variable to `optimized`:

```sh
FOUNDRY_PROFILE=optimized forge build
```

## Tests

```sh
forge test
```

## Formatting

```sh
forge fmt
```

Check only (used by CI and `mise run fmt-check`):

```sh
forge fmt --check
```
