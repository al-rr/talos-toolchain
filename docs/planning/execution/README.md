# Local execution records

Create one record per independently reviewable iteration and repository. Copy
`TEMPLATE.md`; do not reuse a record for unrelated work.

The implementer fills in scope, branch, baseline, and acceptance criteria before
editing implementation files. The reviewer must be a different agent, reviews
the exact local commit range, reruns proportionate checks, and records one of:

- `APPROVED`
- `CHANGES_REQUESTED`
- `FOLLOW_UP_ISSUE`

GitHub issue and pull-request fields are optional. Local review is authoritative
until the repository owner chooses to publish the work remotely.
