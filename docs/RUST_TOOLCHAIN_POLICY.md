# Rust toolchain policy

Rust `1.97.1` is the currently observed recommended baseline from already
adopted repository-local pilots. This document records that policy evidence; it
does not repeat those pilots, add a global compiler pin, or make preflight a
central rejection gate.

Cargo ships with the Rust toolchain. Treat a repo-local compiler pin,
`rust-version`/MSRV, edition, resolver, `Cargo.lock`, dependency update, and
Cargo-subcommand availability as independent declarations. A preflight observes
only the repository-declared toolchain files and requested targets, includes
their evidence in its binding identity, and never injects, installs, or changes
them.

Review upstream/toolchain advisories monthly. Propose pinned-refresh changes
quarterly in each owner repository, starting with a clean repository-local
pilot and PR/main readback. Only then may a separate locked trust-root change
consider central enforcement through the external validation-authority process.
Android/Quest compiler refreshes wait for host preflight and artifact evidence;
AGP, Gradle, NDK, and Kotlin updates are outside this policy slice.
