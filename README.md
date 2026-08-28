# maritrace-dependencies

Shared **dependency-management BOM** for the MariTrace Java estate.

It pins the versions of the libraries that appear across many services (Jackson,
Log4j, the PostgreSQL driver, Kafka client, etc.) to versions that clear known
security advisories. A service that imports this BOM stops declaring those versions
itself — so we patch a vulnerability **once, here** and bump the BOM version. Note the import is
**pinned**: a service picks up a new BOM only when its own `<version>` is bumped, so
publishing a BOM release is step one of a rollout, not the whole of it.

Coordinates: `com.maritrace:maritrace-dependencies` · packaging `pom`.

---

## How it's published

Every change to `pom.xml` on `main` triggers `.github/workflows/publish.yml`, which
runs `mvn deploy` and pushes the BOM to **GitHub Packages** for this repository. The
workflow authenticates with the automatic per-run `GITHUB_TOKEN`, so no personal
tokens are involved in publishing. To cut a new version: bump `<version>` in `pom.xml`,
add a changelog note, and merge to `main`.

---

## How to use it in a service (one-time setup per developer / CI)

GitHub Packages requires authentication **even to read**, so each developer and each
build machine needs a GitHub token with the `read:packages` scope configured for Maven.

### Quick start — run the setup script

```bash
./setup-maven-github-packages.sh
```

It uses your `gh` CLI login if you have one (adding the `read:packages` scope if
needed), otherwise prompts for a token; writes the `<server>` entry to
`~/.m2/settings.xml` (backing up anything already there, never printing the token,
locking the file to `0600`); and verifies by resolving the BOM. Safe to re-run.

If you'd rather do it by hand, the manual steps are below.

### 1. Create a token
A classic Personal Access Token with **`read:packages`** (Settings → Developer settings
→ Personal access tokens). Read-only; it cannot push code.

### 2. Add it to `~/.m2/settings.xml`

```xml
<settings>
  <servers>
    <server>
      <id>github-maritrace</id>
      <username>YOUR_GITHUB_USERNAME</username>
      <password>YOUR_TOKEN_WITH_read:packages</password>
    </server>
  </servers>
</settings>
```

### 3. Reference the package repository in the service `pom.xml`

```xml
<repositories>
  <repository>
    <id>github-maritrace</id>
    <url>https://maven.pkg.github.com/MariTrace/maritrace_dependancies_maritrace-dependencies</url>
  </repository>
</repositories>
```

The `<repository>` `id` must match the `<server>` `id` in `settings.xml`.

### 4. Import the BOM and drop the managed versions

```xml
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>com.maritrace</groupId>
      <artifactId>maritrace-dependencies</artifactId>
      <version>0.0.4</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>
```

Then remove the `<version>` from any managed dependency (jackson, postgresql,
kafka-clients, log4j, …) — the BOM supplies it.

### CI (GitHub Actions)
In a service's own workflow, `setup-java` can wire this up automatically with the
built-in token — no PAT needed:

```yaml
- uses: actions/setup-java@v4
  with:
    java-version: '17'
    distribution: 'temurin'
    server-id: github-maritrace
    server-username: ${{ github.actor }}
    server-password: ${{ secrets.GITHUB_TOKEN }}
```

---

## Works with the `buildpush.sh` flow

No change to `buildpush.sh` or the Dockerfiles is needed. The standard flow runs
`mvn clean package` **locally** and the Dockerfile only `COPY`s the finished
`jar-with-dependencies` into a JRE base image — so the BOM is resolved during that
local Maven step (which reads `~/.m2/settings.xml`), and the correct versions are
baked into the fat jar before the image is built. The only prerequisite is the
one-time `settings.xml` token (step 2) on each machine that runs `buildpush.sh`.

Exception: any service that runs Maven **inside** its Dockerfile (currently only
`applications/ais-data-extractor`) must have the token passed into the Docker build as
a build secret, or be switched to the build-locally-then-COPY pattern the other
services use.

---

## What it manages

| Library | Version | Why |
|---|---|---|
| `com.fasterxml.jackson:*` (via `jackson-bom`) | 2.21.2 | matches what Spring Boot 4.0.5 ships, so the BOM never downgrades it |
| `org.apache.logging.log4j:*` (via `log4j-bom`) | 2.25.4 | current, advisory-clear |
| `org.postgresql:postgresql` | 42.7.12 | SCRAM PBKDF2 DoS (CVE-2026-42198) + later |
| `org.apache.kafka:kafka-clients` | 3.9.2 | advisory-clear |
| `commons-io:commons-io` | 2.20.0 | matches what Spring Boot 4.0.5 ships, so the BOM never downgrades it |
| `com.google.guava:guava` | 33.4.8-jre | advisory-clear |
| `org.json:json` | 20250517 | advisory-clear |
| `org.apache.commons:commons-lang3` | 3.20.0 | advisory-clear |
| `com.google.code.gson:gson` | 2.14.0 | advisory-clear |
| `org.apache.zookeeper:zookeeper` | 3.9.5 | critical advisory; **see changelog before bumping a live consumer** |
| `junit:junit` | 4.13.2 | advisory-clear; test scope only |
| `io.micrometer:*` (via `micrometer-bom`) | 1.15.12 | CVE-2026-40984; **needs a paired source rename — see changelog** |

Add a library here when it's shared by several services and needs central control.

**This BOM must only ever raise a version, never lower one.** Spring Boot manages many
of these libraries itself and moves faster than this file, so a pin that was ahead of
the platform last year can fall behind it. Before adopting the BOM in a service — and
before trusting that it took effect — compare against what that service already
resolves with `mvn dependency:list`. On Spring Boot services the outcome is not uniform:
a BOM pin can win for one library and lose to the Boot parent for another in the same
pom, so check rather than assume.
