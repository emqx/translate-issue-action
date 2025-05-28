# Github Action to translate issues in Chinese into English using Gemini API

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
    steps:
    - uses: emqx/translate-issue-action@v1
      with:
        issue_number: ${{ github.event_name == 'workflow_dispatch' && github.event.inputs.issue_number || github.event.issue.number }}
        gemini_api_key: ${{ secrets.GEMINI_API_KEY }}
```
