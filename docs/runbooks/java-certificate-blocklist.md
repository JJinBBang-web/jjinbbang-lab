# Java certificate blocklist deployment

CVE-2026-91403 affects Java certificate validation. Follow the
[OpenJDK advisory](https://openjdk.org/groups/vulnerability/advisories/2026-10-21)
and [Oracle operational notice](https://ops.java/emudhra). A JDK version number
alone does not prove that the required certificate distrust policy is present.

The application repositories retain the official Unix `blocked.certs` and its
source hash in `security/`. Their Dockerfiles merge it into both the build JDK
and runtime JRE, preserving pre-existing entries. Do not disable TLS validation
or remove unrelated root certificates to make a failing connection pass.

## Prepare and promote

1. Verify the official file source, hash, algorithm, and fingerprints.
2. Check the running Java containers' `$JAVA_HOME/lib/security/blocked.certs`.
   Record counts and missing fingerprints, not credentials or application data.
3. Build and test ARM64 images. Test compromised certificate chains and required
   legitimate TLS endpoints; timeouts and DNS errors are not successful rejection.
4. Promote the tested security change through develop. If development and
   production have diverged, review the production diff and exclude unrelated
   application changes and database migrations from a security-only deployment.
5. Build the production source from `release` for legacy API and `main` for the
   administrator server. Publish a full-SHA tag and verify the ARM64 manifest.
6. Deploy the registry digest through the owning GitOps overlay. The live legacy
   API uses `apps/jjinbbang-api/overlays/legacy`; updating the separate `prod`
   overlay does not update the legacy workload. Administrator environments use
   `apps/jjinbbang-admin/overlays/dev` and `prod`.

Source, GitOps, and production mutations require the workspace approval contract.
Keep the previous desired digest and observed Pod imageID as rollback evidence.

## Verify the running result

- Intended GitOps revision, Argo sync and health, Deployment availability, and
  actual Pod imageID all match the selected immutable image.
- Every target Java container includes all required fingerprints and preserves
  the previous deny entries. Verify the file inside the running image.
- Health, application startup, implicated dependencies, public TLS on every edge,
  representative read requests, and authentication entry routes remain healthy.
- Distinguish TLS handshakes and login redirects from completed account login,
  and health/read probes from a full authenticated CRUD scenario.
- Confirm that unrelated workloads, frontend images, DNS, Secrets, OAuth settings,
  and database migrations are outside the change.

Rollback by restoring the previous immutable digest in the same overlay and
verifying the resulting Pod imageID, health, and Argo state. This also removes
the certificate mitigation unless the previous image already contained it;
record that security consequence when deciding whether to roll back.
