# build-number-action

A GitHub Action that returns a stable build number for a given key.

- If the key already exists, the existing number is returned.
- If the key does not exist, the action allocates the next build number, records it, and returns it.
- Numbers are stored in a JSON file on a branch in the same repository.
- Concurrent runs are handled with optimistic Git push retries.

## Usage

```yaml
permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - id: build-number
        uses: your-org/build-number-action@v1
        with:
          key: ${{ github.sha }}
          # Optional; defaults shown:
          branch: build-numbers
          file: build-numbers.json

      - run: echo "Build number is ${{ steps.build-number.outputs.build-number }}"
```

`actions/checkout` is not required when using a published action; the action clones only the storage branch into a temporary directory.

For a local action in the same repository, check out the repository first:

```yaml
- uses: actions/checkout@v4

- id: build-number
  uses: ./.github/actions/build-number
  with:
    key: ${{ github.ref_name }}
```

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `key` | Yes | | Stable lookup key, such as a commit SHA, tag, or release identifier. |
| `branch` | No | `build-numbers` | Branch used to store the JSON file. |
| `file` | No | `build-numbers.json` | JSON file path on the storage branch. |
| `github-token` | Yes | `${{ github.token }}` | Token with `contents: write` permission. |
| `committer-name` | No | `github-actions[bot]` | Commit author name for storage branch updates. |
| `committer-email` | No | `41898282+github-actions[bot]@users.noreply.github.com` | Commit author email. |
| `max-attempts` | No | `10` | Maximum retries if concurrent jobs update the branch. |

## Outputs

| Output | Description |
| --- | --- |
| `build-number` | Existing or newly allocated build number. |
| `number` | Alias for `build-number`. |
| `existed` | `true` if the key already existed; `false` if newly allocated. |

## Storage format

The storage branch contains JSON like this:

```json
{
  "next": 3,
  "keys": {
    "commit-or-tag-a": 1,
    "commit-or-tag-b": 2
  }
}
```

## Concurrency

The action fetches the storage branch, commits the new key only if needed, and pushes a fast-forward update. If another job updates the branch first, the push is rejected; the action refetches, rechecks the key, and retries. Concurrent requests for the same missing key converge on the same number after retry.
