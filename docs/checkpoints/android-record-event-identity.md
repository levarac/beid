# Record event identity

Initial inventory: `64debe97`.

| Family | Class | Current iOS | Current Android | Invariant | Owner | Shared authority | Licensing test | Native callers | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Joined event display metadata | C | `EventSession` carries a name, currently the code for real sessions | `ScanEventSession` carries only a code | A name belongs to the retained, native-verified B005 envelope. Unauthenticated hints and registry-disagreeing envelopes cannot replace it. Missing names and historical identifiers stay absent. | Android record event identity | `NearbyEventDiscoveryStore`, `RegistryVerifiedJoinContext` | `RecordEventIdentityTest.verifiedNameObtainedAtJoinIsShownAfterRecordStoreReload` | Android `ScanEventSession` / `ProofRecordingBridge`; iOS `SensingCoordinator` | Android persistence JVM verified; iOS runtime unverified |

Barnard owns signature verification. Shared code retains the name supplied
with that verification result alongside the exact envelope bytes, under the
existing container replacement and expiry rules. It does not parse Barnard
messages or introduce a second registry/admission decision.

The join context carries historical display metadata, never a persistable
capability. Android copies only the optional name and canonical Event ID into
the phase and local proof record. Existing schema-version-1 records omit both
fields and remain readable without deriving either from the event code.
Operator-lookup definitions have no display-name field, so that join path
continues to carry no name.

Android recording, record-list and record-detail views render this name when
present and retain the existing code presentation otherwise. iOS uses the
same shared name through its native session adapter; its UI and proof store
already carry a name and are otherwise unchanged. No signing or submission
payload is extended with display metadata.
