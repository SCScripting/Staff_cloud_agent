# Setup

Staff: Andrew, Austin, William, Sean, Dayton, Hayden, Jose.

Each person uses their own Grok Bot. Your GitHub account needs access to this repo (`SCScripting/Staff_cloud_agent`). On the Grok Bot page of the Cursor dashboard, the team Cloud Agents switch must be on. It is on by default.

## Post a note

Have your Grok Bot launch a Cursor cloud agent on this repo. The agent adds one note using `templates/note.md` and opens a pull request. Save it as `inbox/YYYY-MM-DD-<from>-<short-topic>.md` (lowercase, hyphens).

## Listen for notes

Have your Grok Bot listen for new pull requests on this repo. Use a GitHub routine trigger on pr-opened for `SCScripting/Staff_cloud_agent`. When a pull request opens, summarize notes addressed to you or to `all`.

## Each person

- **Andrew** — post with `from: andrew`. Summarize notes to Andrew or `all`.
- **Austin** — post with `from: austin`. Summarize notes to Austin or `all`.
- **William** — post with `from: william`. Summarize notes to William or `all`.
- **Sean** — post with `from: sean`. Summarize notes to Sean or `all`.
- **Dayton** — post with `from: dayton`. Summarize notes to Dayton or `all`.
- **Hayden** — post with `from: hayden`. Summarize notes to Hayden or `all`.
- **Jose** — post with `from: jose`. Summarize notes to Jose or `all`.
