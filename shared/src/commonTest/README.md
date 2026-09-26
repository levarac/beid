# Test resource provenance

Beid implements the protocol decisions in its own Kotlin code. The canonical
resources under `resources/canonical/`, protocol vectors under
`resources/vectors/`, and the portable copies under `fixtures/vectors/` are
copied from [levarac/parallax](https://github.com/levarac/parallax), principally
`protocol/vectors/` and the corresponding protocol schemas. Levarac Foundation
authorized publication of these copied resources with beid.

The comparison test pins the source commit in
`../androidHostTest/kotlin/org/levarac/parallax/registry/ParallaxEventDefinitionSourceChecksumTest.kt`
(`EXPECTED_PARALLAX_REF`); read that constant instead of treating the upstream
branch tip as provenance. The vectors are kept byte-identical to their pinned
upstream counterparts. Keep this attribution when redistributing them.

The upstream repository may require access. Local tests and fork PRs explicitly
skip the upstream checkout comparison when it is unavailable; a skipped
comparison is not passing comparison evidence. The copied vectors themselves
remain available to the ordinary test suites.

See the root [third-party notices](../../../THIRD_PARTY_NOTICES.md) for the
separate notices and restrictions of app dependencies and fonts. Publication
permission for these resources does not grant rights to unrelated upstream
repository contents.
