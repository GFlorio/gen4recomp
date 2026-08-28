# Code health reports

The code-health site records static-analysis observations for the current
commit. It is an observability report, not a quality score or a pass/fail gate:
existing complexity, duplication, and architecture findings do not fail a pull
request or a `master` build.

## Tools and scope

The report runs four pinned tools:

- LuaLS 3.19.0 checks the whole workspace using the repository's `.luarc.json`,
  including tests and the vendored LÖVE definitions.
- Lizard 1.23.0 measures production Lua from the generated source manifest.
- jscpd 5.0.16 measures duplication in the same production-Lua corpus.
- Graphify 0.9.50 builds an AST-derived architecture graph from that corpus.

The structural scope excludes tests, vendored/type definitions, tooling,
generated data, script overrides, and other scratch paths. LuaLS intentionally
keeps its broader workspace diagnostic scope. Graphify's extracted imports are
stronger evidence; inferred cross-file calls are exploratory and should not be
treated as authoritative.

## Run locally

Install Python 3, LuaLS 3.19.0, Node/npm, and the pinned Python and Node tools.
The Python report requirements are listed in
[`scripts/codehealth-requirements.txt`](../scripts/codehealth-requirements.txt);
the HTML reporter also requires `jinja2==3.1.6`, and jscpd must be version
5.0.16. Then run:

```sh
python3 scripts/codehealth_report_test.py
scripts/codehealth.sh
```

The complete disposable Pages tree is written to `tmp/codehealth-site/`:

```text
tmp/codehealth-site/
├── index.html
├── styles.css
└── codehealth/
    ├── index.html
    ├── quality-report.json
    └── reports/
```

The generated tree and intermediate files under `tmp/codehealth-work/` are
disposable and are not source artifacts. The top-level JSON report includes the
current commit, tool versions, and normalized metrics. The generated report
index links to the raw human and machine reports.

## GitHub Pages publication

The dedicated workflow runs automatically only for a push to `master` that
changes at least one `**/*.lua` file. It has no pull-request or schedule
trigger. Changes only to the site, documentation, workflow, or analyzer
tooling do not automatically rebuild the site; use the workflow's manual
dispatch when an immediate refresh is needed.

Before the first deployment, open the repository's Settings → Pages → Build and
deployment and set Source to **GitHub Actions**. Then open Actions, select the
code-health workflow, and choose **Run workflow**. The workflow builds the
report, uploads the complete `tmp/codehealth-site/` tree as the Pages artifact,
and deploys it in one bounded job. Superseded runs are cancelled, and Python
package downloads use the setup action's pip cache. Standard runners for this
public repository are currently free; the path filter, cache, single job, and
10-minute bound keep that cost model efficient by design.

The account user site owns the custom domain `www.gabrielflorio.com`, so the
intended current project URL is
<https://www.gabrielflorio.com/gen4recomp/>. This repository intentionally has
no `CNAME` file and must not modify the personal-site or DNS configuration. The
project site uses GitHub Pages' inherited domain path; the deployment URL
reported by the `github-pages` environment is authoritative.

All links inside the generated site are relative. If the repository later moves
to an organization without that account-level Pages domain, the same site
artifact can use the organization's `github.io/<repo>/` base URL without edits
to the site source.
