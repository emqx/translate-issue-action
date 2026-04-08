# Github Action to translate issues in Chinese into English using GitHub Models API

No provider-specific API key setup is required. This action uses the built-in `GITHUB_TOKEN` (or `secrets.GITHUB_TOKEN`) to call GitHub Models.

## Usage example

```yaml
on:
  workflow_dispatch:
    inputs:
      issue_number:
        description: 'The issue number to translate'
        required: true
        type: string
  issues:
    types: [opened]

jobs:
  translate:
    runs-on: ubuntu-latest
    permissions:
      issues: write # Grant permission to edit issues
      models: read  # Grant permission to use GitHub Models
    steps:
    - uses: emqx/translate-issue-action@master
      with:
        issue_number: ${{ github.event_name == 'workflow_dispatch' && github.event.inputs.issue_number || github.event.issue.number }}
        github_token: ${{ secrets.GITHUB_TOKEN }} # optional; defaults to github.token
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `issue_number` | Yes | — | The issue number to translate |
| `github_token` | No | `${{ github.token }}` | Token used for GitHub API and GitHub Models |
| `github_repo` | No | `${{ github.repository }}` | Repository in `owner/repo` format |
| `model` | No | `openai/gpt-4o` | Model for text translation (via `gh models run`) |
| `vision_model` | No | `gpt-4o` | Vision-capable model for translating image attachments (via REST API) |
| `translate_attachments` | No | `false` | Translate image attachments in the issue body |
